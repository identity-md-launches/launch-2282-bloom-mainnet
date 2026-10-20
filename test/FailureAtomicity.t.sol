// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FarmFixture} from "./helpers/FarmFixture.sol";
import {MockToken, RejectETH} from "./helpers/Mocks.sol";
import {BloomFarm} from "src/BloomFarm.sol";
import {Treasury} from "src/Treasury.sol";

/// @dev Test-only wrapper with switches for exact-balance validation at each integration step.
contract FaultyWrapper is MockToken {
    bool public shortMint;
    bool public shortUnwrap;

    constructor() MockToken("test wrapper", 18) {}

    function setFaults(bool mintFault, bool unwrapFault) external {
        shortMint = mintFault;
        shortUnwrap = unwrapFault;
    }

    function deposit() external payable {
        mint(msg.sender, msg.value - (shortMint ? 1 : 0));
    }

    function withdraw(uint256 amount) external {
        burn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount - (shortUnwrap ? 1 : 0)}("");
        require(ok, "test unwrap failed");
    }
}

contract GuardProbe {
    address public target;
    bytes public payload;
    bytes public failure;
    bool public succeeded;
    uint256 public attempts;

    function configure(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function attack() external {
        ++attempts;
        (succeeded, failure) = target.call(payload);
    }
}

/// @dev Owns the Treasury, so a recursive payment cannot merely fail the authorization check.
contract TreasuryCallbackOwner {
    Treasury public immutable treasury;
    address payable public immutable recipient;
    bytes public failure;
    bool public succeeded;
    uint256 public attempts;

    constructor(address payable recipient_) {
        recipient = recipient_;
        treasury = new Treasury(address(this));
    }

    function payNative(uint256 amount) external {
        treasury.payNative(payable(address(this)), amount);
    }

    function payToken(IERC20 token, uint256 amount) external {
        treasury.payToken(token, address(this), amount);
    }

    function attack() public {
        ++attempts;
        (succeeded, failure) = address(treasury).call(abi.encodeCall(treasury.payNative, (recipient, 1)));
    }

    receive() external payable {
        attack();
    }
}

contract FailureAtomicityTest is FarmFixture {
    function _pendingRewards() internal {
        _deposit(alice, 1000);
        _deposit(bob, 1000);
        _fund(86400);
        _epoch(86400, 1);
        vm.warp(vm.getBlockTimestamp() + 1000);
    }

    function _state() internal view returns (bytes32) {
        bytes32 accounting = keccak256(
            abi.encode(
                farm.totalShares(),
                farm.accountedAssets(),
                farm.rewardReserve(),
                farm.rewardLiability(),
                farm.totalAccrued(),
                farm.totalFunded(),
                farm.totalClaimed(),
                farm.rewardIndex(),
                farm.indexRemainder(),
                farm.epochReleased()
            )
        );
        bytes32 accounts = keccak256(
            abi.encode(
                farm.sharesOf(alice),
                farm.sharesOf(bob),
                farm.accruedRewards(alice),
                farm.accruedRewards(bob),
                farm.paidIndex(alice),
                farm.paidIndex(bob),
                farm.rewardFraction(alice),
                farm.rewardFraction(bob)
            )
        );
        bytes32 balances = keccak256(
            abi.encode(
                farm.asset().balanceOf(address(farm)),
                farm.asset().balanceOf(address(treasury)),
                farm.asset().balanceOf(alice),
                bloom.balanceOf(address(farm)),
                bloom.balanceOf(owner),
                bloom.balanceOf(alice),
                address(farm).balance,
                address(treasury).balance
            )
        );
        return keccak256(
            abi.encode(
                accounting,
                accounts,
                balances,
                farm.epochId(),
                farm.epochStart(),
                farm.epochEnd(),
                farm.epochBudget(),
                farm.epochStartedAt()
            )
        );
    }

    function test_failedUserPaymentRollsBackAnAlreadySuccessfulTreasuryTransferAndRewardCheckpoint() public {
        _pendingRewards();
        // Treasury's 10-unit transfer pays no tax, then the 850-unit user transfer pays 8.
        // This reaches the failure AFTER the Treasury payment, rather than failing on the first transfer.
        simd.setFee(100);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(BloomFarm.InexactTransfer.selector);
        farm.withdraw(1000, 850, payable(alice), false);
        assertEq(_state(), beforeState, "failed final interaction must roll back all preceding effects");
        assertEq(farm.earned(alice), 500);
        simd.setFee(0);
        assertEq(_withdraw(alice, 1000), 850);
        assertEq(simd.balanceOf(address(treasury)), 10);
        vm.prank(alice);
        assertEq(farm.claim(alice), 500);
        _assertAccounting();
    }

    function test_failedDepositCannotAdvanceRewardIndexOrConsumeAllowance() public {
        _pendingRewards();
        simd.mint(alice, 1000);
        vm.prank(alice);
        simd.approve(address(farm), 1000);
        simd.setFee(100);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(BloomFarm.InexactTransfer.selector);
        farm.deposit(1000, 1);
        assertEq(_state(), beforeState);
        assertEq(simd.allowance(alice, address(farm)), 1000);
        simd.setFee(0);
        vm.prank(alice);
        assertEq(farm.deposit(1000, 1), 1000);
        assertEq(farm.earned(alice), 500, "new shares cannot capture old emissions");
    }

    function test_failedFundingRollsBackSettlementAsWellAsReserve() public {
        _pendingRewards();
        bloom.mint(owner, 1000);
        vm.prank(owner);
        bloom.approve(address(farm), 1000);
        bloom.setFee(100);
        bytes32 beforeState = _state();
        vm.prank(owner);
        vm.expectRevert(BloomFarm.InexactTransfer.selector);
        farm.fundRewards(1000);
        assertEq(_state(), beforeState);
        assertEq(bloom.allowance(owner, address(farm)), 1000);
        bloom.setFee(0);
        vm.prank(owner);
        farm.fundRewards(1000);
        assertEq(farm.earned(alice), 500);
        assertEq(farm.rewardReserve(), 1000);
    }

    function test_falseReturnClaimPreservesEntitlementAndCanBeRetried() public {
        _pendingRewards();
        bloom.setReturnsFalse(true);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bloom)));
        farm.claim(alice);
        assertEq(_state(), beforeState);
        bloom.setReturnsFalse(false);
        vm.prank(alice);
        assertEq(farm.claim(alice), 500);
        vm.prank(alice);
        assertEq(farm.claim(alice), 0);
    }

    function test_taxedRewardClaimCannotConsumeAccruedLiability() public {
        _pendingRewards();
        bloom.setFee(100);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(BloomFarm.InexactTransfer.selector);
        farm.claim(alice);
        assertEq(_state(), beforeState);
        bloom.setFee(0);
        vm.prank(alice);
        assertEq(farm.claim(alice), 500);
    }

    function test_failedEpochAndSlippageLeaveEveryAccountingBucketUnchanged() public {
        _pendingRewards();
        bytes32 beforeState = _state();
        vm.prank(owner);
        vm.expectRevert(BloomFarm.InsufficientReserve.selector);
        farm.boost(1);
        assertEq(_state(), beforeState);
        vm.prank(owner);
        vm.expectRevert(BloomFarm.InvalidDuration.selector);
        farm.setEpoch(0, 3651, BloomFarm.EpochMode.Restart);
        assertEq(_state(), beforeState);
        vm.prank(alice);
        vm.expectRevert(BloomFarm.Slippage.selector);
        farm.withdraw(1000, 851, payable(alice), false);
        assertEq(_state(), beforeState);
    }

    function test_rewardDeficitBlocksPrincipalSpendUntilBackingIsActuallyRestored() public {
        _pendingRewards();
        bloom.burn(address(farm), 1);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(BloomFarm.Insolvent.selector);
        farm.withdraw(1000, 0, payable(alice), false);
        vm.prank(alice);
        vm.expectRevert(BloomFarm.Insolvent.selector);
        farm.claim(alice);
        vm.expectRevert(BloomFarm.Insolvent.selector);
        farm.sweepSurplus(simd);
        assertEq(_state(), beforeState);
        // A direct restoration repairs the missing backing; it creates no new reward allocation.
        bloom.mint(address(farm), 1);
        assertEq(_withdraw(alice, 1000), 850);
        vm.prank(alice);
        assertEq(farm.claim(alice), 500);
        assertEq(farm.totalFunded(), 86400);
        _assertAccounting();
    }

    function test_tokenCallbacksFailSpecificallyAtTheReentrancyGuard() public {
        GuardProbe probe = new GuardProbe();
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(farm.deposit, (1, 1));
        calls[1] = abi.encodeCall(farm.withdraw, (1, 0, payable(alice), false));
        calls[2] = abi.encodeCall(farm.claim, (alice));
        calls[3] = abi.encodeCall(farm.checkpoint, ());
        calls[4] = abi.encodeCall(farm.sweepSurplus, (IERC20(address(simd))));
        calls[5] = abi.encodeCall(farm.sweepNativeDonations, ());
        for (uint256 i; i < calls.length; ++i) {
            probe.configure(address(farm), calls[i]);
            simd.setCallback(address(probe), abi.encodeCall(probe.attack, ()));
            _deposit(alice, 1000);
            assertFalse(probe.succeeded());
            assertEq(
                probe.failure(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            );
        }
        assertEq(probe.attempts(), calls.length);
    }

    function test_treasuryOwnerCannotReenterNativeOrTokenPayment() public {
        TreasuryCallbackOwner receiver = new TreasuryCallbackOwner(payable(bob));
        Treasury guarded = receiver.treasury();
        vm.deal(address(guarded), 2 ether);
        receiver.payNative(1 ether);
        assertFalse(receiver.succeeded());
        assertEq(
            receiver.failure(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(address(guarded).balance, 1 ether);
        assertEq(address(receiver).balance, 1 ether);
        assertEq(bob.balance, 0);
        simd.mint(address(guarded), 1000);
        simd.setCallback(address(receiver), abi.encodeCall(receiver.attack, ()));
        receiver.payToken(simd, 1000);
        assertFalse(receiver.succeeded());
        assertEq(
            receiver.failure(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(receiver.attempts(), 2);
        assertEq(simd.balanceOf(address(receiver)), 1000);
        assertEq(address(guarded).balance, 1 ether);
    }

    function _faultyNativeFarm() internal returns (FaultyWrapper wrapper) {
        wrapper = new FaultyWrapper();
        farm =
            new BloomFarm(owner, address(treasury), address(wrapper), address(bloom), 18, BloomFarm.Kind.ETH);
        vm.prank(owner);
        farm.setDepositsPaused(false);
        vm.deal(alice, 10 ether);
    }

    function test_shortWETHMintRejectsDepositWithoutLosingNativeETH() public {
        FaultyWrapper wrapper = _faultyNativeFarm();
        wrapper.setFaults(true, false);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(BloomFarm.InexactTransfer.selector);
        farm.depositETH{value: 10 ether}(1);
        assertEq(_state(), beforeState);
        assertEq(alice.balance, 10 ether);
        assertEq(address(wrapper).balance, 0);
    }

    function test_shortWETHUnwrapRollsBackBurnAndFees() public {
        FaultyWrapper wrapper = _faultyNativeFarm();
        vm.prank(alice);
        farm.depositETH{value: 10 ether}(1);
        wrapper.setFaults(false, true);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(BloomFarm.InexactTransfer.selector);
        farm.withdraw(10 ether, 0, payable(alice), false);
        assertEq(_state(), beforeState);
        assertEq(address(wrapper).balance, 10 ether);
        assertEq(alice.balance, 0);
        wrapper.setFaults(false, false);
        assertEq(_withdraw(alice, 10 ether), 8.5 ether);
    }

    function test_failedFallbackRewrapRollsBackTheSuccessfulTreasuryPayment() public {
        FaultyWrapper wrapper = _faultyNativeFarm();
        RejectETH receiver = new RejectETH();
        vm.prank(alice);
        farm.depositETH{value: 10 ether}(1);
        wrapper.setFaults(true, false);
        bytes32 beforeState = _state();
        vm.prank(alice);
        vm.expectRevert(BloomFarm.InexactTransfer.selector);
        farm.withdraw(10 ether, 0, payable(address(receiver)), false);
        assertEq(_state(), beforeState);
        assertEq(address(wrapper).balance, 10 ether);
        assertEq(wrapper.balanceOf(address(receiver)), 0);
        wrapper.setFaults(false, false);
        vm.prank(alice);
        farm.withdraw(10 ether, 8.5 ether, payable(address(receiver)), false);
        assertEq(wrapper.balanceOf(address(receiver)), 8.5 ether);
        assertEq(address(treasury).balance, 1.5 ether);
    }

    function test_failedNativeDonationSweepDoesNotBlockUserWETHExit() public {
        RejectETH rejectingTreasury = new RejectETH();
        farm = new BloomFarm(
            owner, address(rejectingTreasury), address(weth), address(bloom), 18, BloomFarm.Kind.ETH
        );
        vm.prank(owner);
        farm.setDepositsPaused(false);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        farm.depositETH{value: 1 ether}(1);
        vm.deal(address(farm), 2 ether);
        vm.expectRevert(BloomFarm.UnexpectedETH.selector);
        farm.sweepNativeDonations();
        assertEq(address(farm).balance, 2 ether);
        vm.prank(alice);
        farm.withdraw(1 ether, 0.85 ether, payable(alice), true);
        assertEq(weth.balanceOf(alice), 0.85 ether);
        assertEq(weth.balanceOf(address(rejectingTreasury)), 0.15 ether);
        assertEq(address(farm).balance, 2 ether);
    }
}
