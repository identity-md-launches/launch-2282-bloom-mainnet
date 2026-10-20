// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture} from "./helpers/FarmFixture.sol";
import {MockToken, NoReturnToken, RejectETH} from "./helpers/Mocks.sol";
import {BloomFarm} from "../src/BloomFarm.sol";
import {Treasury} from "../src/Treasury.sol";
import {SelectiveRoles} from "../src/SelectiveRoles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract AdversarialTest is FarmFixture {
    function testTaxedDepositRevertsWithoutIssuingShares() public {
        simd.setFee(100);
        simd.mint(alice, 100 ether);
        vm.startPrank(alice);
        simd.approve(address(farm), 100 ether);
        vm.expectRevert(BloomFarm.InexactTransfer.selector);
        farm.deposit(100 ether, 1);
        vm.stopPrank();
        assertEq(farm.totalShares(), 0);
        assertEq(farm.accountedAssets(), 0);
        assertEq(simd.balanceOf(alice), 100 ether);
    }

    function testTaxedRewardFundingRevertsWithoutCreatingUnbackedReserve() public {
        bloom.setFee(100);
        bloom.mint(owner, 100 ether);
        vm.startPrank(owner);
        bloom.approve(address(farm), 100 ether);
        vm.expectRevert(BloomFarm.InexactTransfer.selector);
        farm.fundRewards(100 ether);
        vm.stopPrank();
        assertEq(farm.totalFunded(), 0);
        assertEq(farm.rewardReserve(), 0);
    }

    function testTaxedWithdrawalRollsBackBurnAndTreasuryPayment() public {
        _deposit(alice, 100 ether);
        simd.setFee(100);
        vm.prank(alice);
        vm.expectRevert(BloomFarm.InexactTransfer.selector);
        farm.withdraw(100 ether, 0, payable(alice), false);
        assertEq(farm.totalShares(), 100 ether);
        assertEq(farm.accountedAssets(), 100 ether);
        assertEq(simd.balanceOf(address(treasury)), 0);
    }

    function testFalseReturnTokenRevertsSafely() public {
        _deposit(alice, 100 ether);
        simd.setReturnsFalse(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(simd)));
        farm.withdraw(100 ether, 0, payable(alice), false);
        assertEq(farm.sharesOf(alice), 100 ether);
    }

    function testTokenWithNoReturnValueSupported() public {
        NoReturnToken token = new NoReturnToken();
        farm =
            new BloomFarm(owner, address(treasury), address(token), address(bloom), 18, BloomFarm.Kind.SIMD);
        vm.prank(owner);
        farm.setDepositsPaused(false);
        token.mint(alice, 100 ether);
        vm.startPrank(alice);
        token.approve(address(farm), 100 ether);
        farm.deposit(100 ether, 100 ether);
        farm.withdraw(100 ether, 85 ether, payable(alice), false);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 85 ether);
        _assertAccounting();
    }

    function testReentrantTokenCannotDepositWithdrawClaimOrSweep() public {
        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeCall(farm.deposit, (1, 1));
        calls[1] = abi.encodeCall(farm.withdraw, (1, 0, payable(alice), false));
        calls[2] = abi.encodeCall(farm.claim, (alice));
        calls[3] = abi.encodeCall(farm.sweepSurplus, (IERC20(address(simd))));
        calls[4] = abi.encodeCall(farm.checkpoint, ());
        for (uint256 i; i < calls.length; ++i) {
            simd.setCallback(address(farm), calls[i]);
            _deposit(alice, 100 ether);
            assertTrue(simd.callbackBlocked());
        }
        _withdraw(alice, farm.sharesOf(alice));
        assertTrue(simd.callbackBlocked());
        _assertAccounting();
    }

    function testRewardTokenCallbackCannotClaimTwice() public {
        _deposit(alice, 100 ether);
        _fund(100 ether);
        _epoch(100 ether, 1);
        vm.warp(farm.epochEnd());
        bloom.setCallback(address(farm), abi.encodeCall(farm.claim, (alice)));
        vm.prank(alice);
        assertEq(farm.claim(alice), 100 ether);
        assertTrue(bloom.callbackBlocked());
        vm.prank(alice);
        assertEq(farm.claim(alice), 0);
        _assertAccounting();
    }

    function testNegativeRebaseCannotSpendRewardBackingAsPrincipal() public {
        vm.startPrank(owner);
        farm = factory.createFarm(BloomFarm.Kind.BLOOM);
        farm.setDepositsPaused(false);
        vm.stopPrank();
        _deposit(alice, 100 ether);
        _fund(100 ether);
        bloom.burn(address(farm), 1);
        vm.prank(alice);
        vm.expectRevert(BloomFarm.Insolvent.selector);
        farm.withdraw(100 ether, 0, payable(alice), false);
        vm.expectRevert(BloomFarm.Insolvent.selector);
        farm.sweepSurplus(bloom);
        assertEq(farm.sharesOf(alice), 100 ether);
    }

    function testMaximumAccountingBoundsAndFullPrecision() public {
        uint256 cap = farm.MAX_BALANCE();
        _deposit(alice, cap);
        _fund(cap);
        _epoch(cap, 1);
        vm.warp(farm.epochEnd());
        vm.prank(alice);
        assertEq(farm.claim(alice), cap);
        _withdraw(alice, cap);
        _assertAccounting();
    }

    function testDepositAndFundingCapsRejectWithoutOverflow() public {
        uint256 cap = farm.MAX_BALANCE();
        _deposit(alice, cap);
        simd.mint(bob, 1);
        vm.startPrank(bob);
        simd.approve(address(farm), 1);
        vm.expectRevert(BloomFarm.BalanceLimit.selector);
        farm.deposit(1, 1);
        vm.stopPrank();
        _fund(cap);
        vm.prank(owner);
        vm.expectRevert(BloomFarm.BalanceLimit.selector);
        farm.fundRewards(1);
    }

    function testTreasuryNativeFailureAndRecipientValidation() public {
        RejectETH rejecting = new RejectETH();
        vm.deal(address(treasury), 1 ether);
        vm.startPrank(owner);
        vm.expectRevert(Treasury.NativeTransferFailed.selector);
        treasury.payNative(payable(address(rejecting)), 1 ether);
        vm.expectRevert(Treasury.InvalidAddress.selector);
        treasury.payNative(payable(address(0)), 1);
        vm.expectRevert(Treasury.InvalidAmount.selector);
        treasury.payNative(payable(owner), 0);
        treasury.payNative(payable(owner), 1 ether);
        vm.stopPrank();
        assertEq(owner.balance, 1 ether);
    }

    function testFarmRejectsInvalidRecipientsAndConstructorValues() public {
        _deposit(alice, 100);
        vm.startPrank(alice);
        vm.expectRevert(SelectiveRoles.InvalidAddress.selector);
        farm.withdraw(1, 0, payable(address(farm)), false);
        vm.expectRevert(SelectiveRoles.InvalidAddress.selector);
        farm.claim(address(0));
        vm.stopPrank();
        vm.expectRevert(SelectiveRoles.InvalidAddress.selector);
        new BloomFarm(address(0), address(treasury), address(simd), address(bloom), 18, BloomFarm.Kind.SIMD);
        vm.expectRevert(BloomFarm.UnsupportedAsset.selector);
        new BloomFarm(owner, address(treasury), address(simd), address(bloom), 18, BloomFarm.Kind.BLOOM);
        vm.expectRevert(BloomFarm.UnsupportedAsset.selector);
        new BloomFarm(owner, address(treasury), address(bloom), address(bloom), 18, BloomFarm.Kind.SIMD);
    }
}
