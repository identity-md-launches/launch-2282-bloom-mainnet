// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture} from "./helpers/FarmFixture.sol";
import {BloomFarm} from "../src/BloomFarm.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract AccountingTest is FarmFixture {
    function testImmediateSingleDepositorFullWithdrawal() public {
        uint256 shares = _deposit(alice, 100 ether);
        assertEq(shares, 100 ether);
        assertEq(farm.shareSymbol(), "stakedSIMD");
        assertEq(farm.decimals(), 18);
        assertEq(_withdraw(alice, shares), 85 ether);
        assertEq(simd.balanceOf(address(treasury)), 15 ether);
        assertEq(farm.totalShares(), 0);
        _assertAccounting();
    }

    /// @dev The virtual offset (1e6 shares against 1e20) moves whole-pool exits by well under 1e6 wei;
    /// conservation stays exact and the dust the virtual shares absorbed goes to the Treasury.
    uint256 internal constant VIRTUAL_DUST = 1e6;

    function testRedistributionAndFullCompoundedPositionFee() public {
        _deposit(alice, 100 ether);
        _deposit(bob, 100 ether);
        assertEq(_withdraw(alice, 100 ether), 85 ether);
        assertEq(farm.accountedAssets(), 114 ether);
        assertApproxEqAbs(farm.previewDeposit(114 ether), 100 ether, VIRTUAL_DUST);
        assertEq(simd.balanceOf(address(treasury)), 1 ether);
        uint256 bobNet = _withdraw(bob, 100 ether);
        assertApproxEqAbs(bobNet, 96.9 ether, VIRTUAL_DUST);
        assertLe(bobNet, 96.9 ether);
        assertEq(simd.balanceOf(address(treasury)), 200 ether - 85 ether - bobNet);
        assertEq(farm.accountedAssets(), 0);
        _assertAccounting();
    }

    function testPartialWithdrawerIntentionallyBenefits() public {
        _deposit(alice, 100 ether);
        assertEq(_withdraw(alice, 50 ether), 42.5 ether);
        assertEq(farm.accountedAssets(), 57 ether);
        assertEq(farm.sharesOf(alice), 50 ether);
        uint256 second = _withdraw(alice, 50 ether);
        assertApproxEqAbs(second, 48.45 ether, VIRTUAL_DUST);
        assertLe(second, 48.45 ether);
        assertApproxEqAbs(simd.balanceOf(alice), 90.95 ether, VIRTUAL_DUST);
        assertEq(simd.balanceOf(alice) + simd.balanceOf(address(treasury)), 100 ether);
        _assertAccounting();
    }

    function testDonationsDoNotInflateSharesOrBecomeRewards() public {
        _deposit(alice, 1);
        simd.mint(address(farm), 1_000_000 ether);
        assertEq(farm.previewDeposit(1 ether), 1 ether);
        assertEq(_deposit(bob, 1 ether), 1 ether);
        assertEq(farm.rewardBacking(), 0);
        vm.prank(carol);
        assertEq(farm.sweepSurplus(simd), 1_000_000 ether);
        assertEq(simd.balanceOf(address(treasury)), 1_000_000 ether);
        _assertAccounting();
    }

    function testDonationsBeforeFirstDepositAndAfterEmptyRemainIsolated() public {
        simd.mint(address(farm), 123);
        _deposit(alice, 100);
        _withdraw(alice, 100);
        assertEq(farm.accountedAssets(), 0);
        assertEq(simd.balanceOf(address(farm)), 123);
        assertEq(_deposit(bob, 100), 100);
        _withdraw(bob, 100);
        farm.sweepSurplus(simd);
        assertEq(simd.balanceOf(address(treasury)), 153);
        _assertAccounting();
    }

    function testDepositSlippageZeroSharesAndRoundingDust() public {
        _deposit(alice, 1);
        _deposit(bob, 1000);
        _withdraw(bob, 1000);
        assertEq(farm.accountedAssets(), 141);
        assertEq(farm.totalShares(), 1);
        // One surviving share carries only 1 / (VIRTUAL_OFFSET + 1) of the 140 retained units.
        assertEq(farm.previewDeposit(140), 140 * (farm.VIRTUAL_OFFSET() + 1) / (141 + farm.VIRTUAL_OFFSET()));
        simd.mint(carol, 282);
        vm.startPrank(carol);
        simd.approve(address(farm), 282);
        vm.expectRevert(BloomFarm.Slippage.selector);
        farm.deposit(282, 282);
        uint256 shares = farm.deposit(282, 281);
        vm.stopPrank();
        assertEq(shares, 281);
        assertEq(farm.accountedAssets(), 423);
        assertEq(farm.totalShares(), 282);
        (uint256 gross,,,) = farm.previewWithdraw(281);
        assertEq(gross, 281);
        _assertAccounting();
    }

    function testZeroSharesOnlyBelowTheVirtuallyBoundedSharePrice() public {
        // Inflating one share to a price of P costs about VIRTUAL_OFFSET * P / 0.14 routed through
        // the farm with 15% lost on every round trip. Here the price is driven to 1e24 wei per share.
        _deposit(alice, 1);
        uint256 routed = uint256(1e30) * 100 / 14;
        uint256 shares = _deposit(bob, routed);
        _withdraw(bob, shares);
        assertEq(farm.totalShares(), 1);
        uint256 price = Math.ceilDiv(farm.accountedAssets() + farm.virtualAssets(), 1 + farm.virtualShares());
        assertApproxEqRel(price, 1e24, 1e12);
        simd.mint(carol, price);
        vm.startPrank(carol);
        simd.approve(address(farm), price);
        vm.expectRevert(BloomFarm.ZeroShares.selector);
        farm.deposit(price - 1, 1);
        assertEq(farm.deposit(price, 1), 1);
        vm.stopPrank();
        // Alice's single share, the attacker's only surviving claim, is worth one share price, not 14% of the flow.
        (uint256 aliceGross,,,) = farm.previewWithdraw(1);
        assertLe(aliceGross, price + 1);
        assertLt(aliceGross, routed * 15 / 100 / farm.VIRTUAL_OFFSET());
        _assertAccounting();
    }

    function testRetentionCannotInflateSharePriceAgainstLaterDepositors() public {
        // The reviewer's attack: 1 wei first deposit, then a 1,000-token round trip from another wallet.
        _deposit(alice, 1);
        uint256 sharesB = _deposit(bob, 1000 ether);
        _withdraw(bob, sharesB);
        assertEq(farm.totalShares(), 1);
        assertEq(farm.accountedAssets(), 140 ether + 1);
        assertGt(farm.previewDeposit(100 ether), 0);
        uint256 victimDeposit = 280 ether + 1;
        uint256 victimShares = _deposit(carol, victimDeposit);
        (uint256 victimGross,,,) = farm.previewWithdraw(victimShares);
        // Entry rounding loses less than one share price, about 1.4e14 wei here.
        assertGe(victimGross, victimDeposit - 2e14);
        uint256 aliceNet = _withdraw(alice, 1);
        assertLt(aliceNet, 2e14);
        assertLt(simd.balanceOf(alice) + simd.balanceOf(bob), 1000 ether + 1);
        assertGt(simd.balanceOf(address(treasury)), 10 ether);
        _assertAccounting();
    }

    function testSquatterShareCannotCaptureTheFinalFifteenPercent() public {
        _deposit(alice, 1);
        uint256 shares = _deposit(bob, 1000 ether);
        _withdraw(bob, shares);
        uint256 squatterNet = _withdraw(alice, 1);
        // The Treasury receives the full 15% of the sole real depositor minus one virtually bounded share.
        assertLt(squatterNet, 2e14);
        assertGt(simd.balanceOf(address(treasury)), 150 ether - 2e14);
        assertEq(simd.balanceOf(address(treasury)) + squatterNet + simd.balanceOf(bob), 1000 ether + 1);
        assertEq(farm.accountedAssets(), 0);
        assertEq(farm.totalShares(), 0);
        _assertAccounting();
    }

    function testEmptyPoolResidualGoesToTreasuryAndNeverToFutureDepositors() public {
        _deposit(alice, 100 ether);
        _deposit(bob, 100 ether);
        _withdraw(alice, 100 ether);
        vm.expectEmit(false, false, false, false);
        emit BloomFarm.EmptyPoolResidualToTreasury(0);
        _withdraw(bob, 100 ether);
        assertEq(farm.accountedAssets(), 0);
        assertEq(simd.balanceOf(address(farm)), 0);
        assertEq(_deposit(carol, 100 ether), 100 ether);
        assertEq(_withdraw(carol, 100 ether), 85 ether);
        _assertAccounting();
    }

    function testMinimumsAndWithdrawBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(BloomFarm.InvalidAmount.selector);
        farm.deposit(0, 1);
        vm.expectRevert(BloomFarm.InvalidAmount.selector);
        farm.deposit(1, 0);
        vm.expectRevert(BloomFarm.InsufficientShares.selector);
        farm.withdraw(0, 0, payable(alice), false);
        vm.stopPrank();
        _deposit(alice, 100);
        vm.startPrank(alice);
        vm.expectRevert(BloomFarm.InsufficientShares.selector);
        farm.withdraw(101, 0, payable(alice), false);
        vm.expectRevert(BloomFarm.Slippage.selector);
        farm.withdraw(100, 86, payable(alice), false);
        vm.stopPrank();
        assertEq(farm.sharesOf(alice), 100);
    }

    function testTinyWithdrawalsCannotAvoidFee() public {
        _deposit(alice, 100);
        _deposit(bob, 100);
        for (uint256 i; i < 100; ++i) {
            (uint256 gross, uint256 net,, uint256 treasuryFee) = farm.previewWithdraw(1);
            assertGe(gross, 1);
            assertLe(net, gross * 85 / 100);
            assertGe(treasuryFee, Math.ceilDiv(gross, 100));
            _withdraw(alice, 1);
        }
        assertEq(simd.balanceOf(alice), 0);
        assertEq(simd.balanceOf(address(treasury)), 100);
        _assertAccounting();
    }

    function testSixDecimalUnderlyingStillHas18DecimalShares() public {
        MockToken six = new MockToken("six", 6);
        farm = new BloomFarm(owner, address(treasury), address(six), address(bloom), 6, BloomFarm.Kind.SIMD);
        vm.prank(owner);
        farm.setDepositsPaused(false);
        assertEq(_deposit(alice, 100e6), 100 ether);
        // One internal share is smaller than one underlying base unit. It cannot be burned for zero gross.
        vm.prank(alice);
        vm.expectRevert(BloomFarm.ZeroAssets.selector);
        farm.withdraw(1, 0, payable(alice), false);
        assertEq(farm.sharesOf(alice), 100 ether);
        assertEq(_withdraw(alice, 100 ether), 85e6);
        _assertAccounting();
    }

    function testLowDecimalDustDepositIsRejectedOrClosableWhole() public {
        MockToken six = new MockToken("six", 6);
        farm = new BloomFarm(owner, address(treasury), address(six), address(bloom), 6, BloomFarm.Kind.SIMD);
        vm.prank(owner);
        farm.setDepositsPaused(false);
        _deposit(alice, 1000);
        _deposit(bob, 1000);
        _withdraw(alice, 1e15);
        assertEq(farm.accountedAssets(), 1140);
        // A one-unit deposit would mint shares whose whole redemption floors to zero: refused up front.
        six.mint(carol, 1);
        vm.startPrank(carol);
        six.approve(address(farm), 1);
        vm.expectRevert(BloomFarm.ZeroAssets.selector);
        farm.deposit(1, 1);
        vm.stopPrank();
        assertEq(six.balanceOf(carol), 1);
        // A holder who shrinks their own position below one unit can still close it whole.
        uint256 bobShares = farm.sharesOf(bob);
        _withdraw(bob, bobShares - 1);
        (uint256 gross,,,) = farm.previewWithdraw(1);
        assertEq(gross, 0);
        assertEq(_withdraw(bob, 1), 0);
        assertEq(farm.sharesOf(bob), 0);
        assertEq(farm.totalShares(), 0);
        assertEq(farm.accountedAssets(), 0);
        assertEq(six.balanceOf(address(treasury)) + six.balanceOf(alice) + six.balanceOf(bob), 2000);
        _assertAccounting();
    }

    function testSharesAreNonTransferableAndNoAllowanceExists() public {
        _deposit(alice, 100 ether);
        vm.startPrank(alice);
        (bool transferOK,) =
            address(farm).call(abi.encodeWithSignature("transfer(address,uint256)", bob, 1 ether));
        (bool approveOK,) =
            address(farm).call(abi.encodeWithSignature("approve(address,uint256)", bob, 1 ether));
        (bool transferFromOK,) = address(farm)
            .call(abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, bob, 1 ether));
        vm.stopPrank();
        assertFalse(transferOK);
        assertFalse(approveOK);
        assertFalse(transferFromOK);
        assertEq(farm.sharesOf(alice), 100 ether);
    }

    function testFeeSnipingIsPossibleUnderImmediateEligibility() public {
        // Concrete economic risk required by Model B: a small position can capture a large exit's fee.
        _deposit(alice, 1000 ether);
        _deposit(bob, 10 ether);
        _withdraw(alice, 1000 ether);
        uint256 bobNet = _withdraw(bob, 10 ether);
        assertApproxEqAbs(bobNet, 127.5 ether, 1e8);
        assertGt(bobNet - 10 ether, 117 ether);
        assertEq(bobNet + simd.balanceOf(alice) + simd.balanceOf(address(treasury)), 1010 ether);
        _assertAccounting();
    }

    function testMultiWalletSplittingMatchesIntentionalPartialWithdrawalBenefit() public {
        _deposit(alice, 50 ether);
        _deposit(bob, 50 ether);
        _withdraw(alice, 50 ether);
        _withdraw(bob, 50 ether);
        assertApproxEqAbs(simd.balanceOf(alice) + simd.balanceOf(bob), 90.95 ether, VIRTUAL_DUST);
        assertEq(simd.balanceOf(alice) + simd.balanceOf(bob) + simd.balanceOf(address(treasury)), 100 ether);
        _assertAccounting();
    }

    function testRepeatedPartialWithdrawalsRetainTheModelBRecaptureBenefit() public {
        _deposit(alice, 1000 ether);
        for (uint256 i; i < 30; ++i) {
            _withdraw(alice, farm.sharesOf(alice) / 2);
        }
        _withdraw(alice, farm.sharesOf(alice));
        // Limiting payout is 85/86 of initial assets, because the same holder recaptures the 14%.
        assertGt(simd.balanceOf(alice), 988.37 ether);
        assertLt(simd.balanceOf(alice), 988.38 ether);
        assertEq(simd.balanceOf(alice) + simd.balanceOf(address(treasury)), 1000 ether);
        _assertAccounting();
    }

    function testLastDepositorDoesNotInheritPriorRoundingOrRewards() public {
        _deposit(alice, 101);
        _withdraw(alice, 101);
        assertEq(simd.balanceOf(address(treasury)), 16);
        assertEq(_deposit(bob, 101), 101);
        assertEq(_withdraw(bob, 101), 85);
        _assertAccounting();
    }

    function testFuzzFeeConservation(uint128 assetsSeed, uint128 otherSeed, uint128 shareSeed) public {
        uint256 first = bound(uint256(assetsSeed), 1, 1e30);
        uint256 second = bound(uint256(otherSeed), 1, 1e30);
        _deposit(alice, first);
        _deposit(bob, second);
        uint256 shares = bound(uint256(shareSeed), 1, first);
        uint256 beforeAssets = farm.accountedAssets();
        (uint256 gross, uint256 net, uint256 retained, uint256 feeToTreasury) = farm.previewWithdraw(shares);
        assertEq(gross, shares);
        assertEq(gross, net + retained + feeToTreasury);
        assertEq(net, Math.mulDiv(gross, 85, 100));
        uint256 got = _withdraw(alice, shares);
        assertEq(got, net);
        assertEq(farm.accountedAssets(), beforeAssets - gross + retained);
        assertEq(simd.balanceOf(address(treasury)), feeToTreasury);
        _assertAccounting();
    }

    function testFuzzFiveToOneThousandUsers(uint16 countSeed) public {
        uint256 count = bound(uint256(countSeed), 5, 1000);
        uint256 deposited;
        for (uint256 i; i < count; ++i) {
            address user = address(uint160(10_000 + i));
            uint256 amount = (i + 1) * 1e12;
            _deposit(user, amount);
            deposited += amount;
        }
        uint256 paid;
        for (uint256 i; i < count; ++i) {
            address user = address(uint160(10_000 + i));
            paid += _withdraw(user, farm.sharesOf(user));
        }
        assertEq(paid + simd.balanceOf(address(treasury)), deposited);
        _assertAccounting();
    }
}
