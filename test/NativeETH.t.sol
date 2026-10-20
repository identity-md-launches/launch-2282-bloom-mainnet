// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture} from "./helpers/FarmFixture.sol";
import {BloomFarm} from "../src/BloomFarm.sol";
import {RejectETH, GasHungryReceiver, ReturnBombReceiver, ReentrantReceiver} from "./helpers/Mocks.sol";

contract NativeETHTest is FarmFixture {
    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        farm = factory.createFarm(BloomFarm.Kind.ETH);
        farm.setDepositsPaused(false);
        vm.stopPrank();
    }

    function _ethDeposit(address who, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        farm.depositETH{value: amount}(1);
    }

    function testNativeDepositWrapsAndWithdrawalPaysETHAndTreasury() public {
        _ethDeposit(alice, 100 ether);
        assertEq(weth.balanceOf(address(farm)), 100 ether);
        assertEq(address(farm).balance, 0);
        assertEq(farm.shareSymbol(), "stakedETH");
        _withdraw(alice, 100 ether);
        assertEq(alice.balance, 85 ether);
        assertEq(address(treasury).balance, 15 ether);
        assertEq(weth.balanceOf(address(farm)), 0);
        _assertAccounting();
    }

    function testNativeRedistributionRemainsWrappedInSameFarm() public {
        _ethDeposit(alice, 100 ether);
        _ethDeposit(bob, 100 ether);
        _withdraw(alice, 100 ether);
        assertEq(farm.accountedAssets(), 114 ether);
        assertEq(weth.balanceOf(address(farm)), 114 ether);
        assertEq(address(treasury).balance, 1 ether);
        _assertAccounting();
    }

    function testExplicitWETHWithdrawalHasIdenticalFees() public {
        _ethDeposit(alice, 100 ether);
        vm.prank(alice);
        farm.withdraw(100 ether, 85 ether, payable(alice), true);
        assertEq(weth.balanceOf(alice), 85 ether);
        assertEq(alice.balance, 0);
        assertEq(address(treasury).balance, 15 ether);
        _assertAccounting();
    }

    function testRejectingRecipientAutomaticallyGetsWETH() public {
        RejectETH recipient = new RejectETH();
        _ethDeposit(alice, 100 ether);
        vm.prank(alice);
        farm.withdraw(100 ether, 85 ether, payable(address(recipient)), false);
        assertEq(weth.balanceOf(address(recipient)), 85 ether);
        assertEq(address(recipient).balance, 0);
        _assertAccounting();
    }

    function testGasExhaustionDoesNotBlockWETHFallback() public {
        GasHungryReceiver recipient = new GasHungryReceiver();
        _ethDeposit(alice, 100 ether);
        vm.prank(alice);
        farm.withdraw(100 ether, 85 ether, payable(address(recipient)), false);
        assertEq(weth.balanceOf(address(recipient)), 85 ether);
        _assertAccounting();
    }

    function testReturnDataBombDoesNotBlockWETHFallback() public {
        ReturnBombReceiver recipient = new ReturnBombReceiver();
        _ethDeposit(alice, 100 ether);
        vm.prank(alice);
        farm.withdraw(100 ether, 85 ether, payable(address(recipient)), false);
        assertEq(weth.balanceOf(address(recipient)), 85 ether);
        _assertAccounting();
    }

    function testReentrantETHRecipientCannotClaimOrWithdrawDuringPayout() public {
        ReentrantReceiver recipient = new ReentrantReceiver(farm);
        _ethDeposit(address(recipient), 100 ether);
        vm.prank(address(recipient));
        farm.withdraw(100 ether, 85 ether, payable(address(recipient)), false);
        assertTrue(recipient.attempted());
        assertTrue(recipient.blocked());
        assertEq(address(recipient).balance, 85 ether);
        _assertAccounting();
    }

    function testRejectingTreasuryGetsWETHWithoutBlockingUser() public {
        RejectETH rejecting = new RejectETH();
        // Direct instance exercises fallback independently of the production Treasury, which accepts ETH.
        farm = new BloomFarm(owner, address(rejecting), address(weth), address(bloom), 18, BloomFarm.Kind.ETH);
        vm.prank(owner);
        farm.setDepositsPaused(false);
        _ethDeposit(alice, 100 ether);
        _withdraw(alice, 100 ether);
        assertEq(alice.balance, 85 ether);
        assertEq(weth.balanceOf(address(rejecting)), 15 ether);
        _assertAccounting();
    }

    function testWrongEntryPointsAndUnsolicitedETHRejected() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(BloomFarm.UnsupportedAsset.selector);
        farm.deposit(1, 1);
        (bool ok,) = address(farm).call{value: 1}("");
        assertFalse(ok);
        vm.stopPrank();
    }

    function testForcedETHDonationsAreNeverShareBacking() public {
        _ethDeposit(alice, 100 ether);
        vm.deal(address(farm), 7 ether);
        assertEq(farm.accountedAssets(), 100 ether);
        farm.sweepNativeDonations();
        assertEq(address(treasury).balance, 7 ether);
        _withdraw(alice, 100 ether);
        assertEq(address(treasury).balance, 22 ether);
        _assertAccounting();
    }
}
