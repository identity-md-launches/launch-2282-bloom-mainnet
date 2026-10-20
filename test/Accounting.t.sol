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

    function testRedistributionAndFullCompoundedPositionFee() public {
        _deposit(alice, 100 ether);
        _deposit(bob, 100 ether);
        assertEq(_withdraw(alice, 100 ether), 85 ether);
        assertEq(farm.accountedAssets(), 114 ether);
        assertEq(farm.previewDeposit(114 ether), 100 ether);
        assertEq(simd.balanceOf(address(treasury)), 1 ether);
        assertEq(_withdraw(bob, 100 ether), 96.9 ether);
        assertEq(simd.balanceOf(address(treasury)), 18.1 ether);
        _assertAccounting();
    }

    function testPartialWithdrawerIntentionallyBenefits() public {
        _deposit(alice, 100 ether);
        assertEq(_withdraw(alice, 50 ether), 42.5 ether);
        assertEq(farm.accountedAssets(), 57 ether);
        assertEq(farm.sharesOf(alice), 50 ether);
        assertEq(_withdraw(alice, 50 ether), 48.45 ether);
        assertEq(simd.balanceOf(alice), 90.95 ether);
        assertEq(simd.balanceOf(address(treasury)), 9.05 ether);
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
        simd.mint(carol, 300);
        vm.startPrank(carol);
        simd.approve(address(farm), 300);
        vm.expectRevert(BloomFarm.ZeroShares.selector);
        farm.deposit(140, 1);
        vm.expectRevert(BloomFarm.Slippage.selector);
        farm.deposit(282, 3);
        assertEq(farm.deposit(282, 2), 2);
        vm.stopPrank();
        assertEq(farm.accountedAssets(), 423);
        assertEq(farm.totalShares(), 3);
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
        assertEq(_withdraw(bob, 10 ether), 127.5 ether);
        assertEq(simd.balanceOf(bob) - 10 ether, 117.5 ether);
        _assertAccounting();
    }

    function testMultiWalletSplittingMatchesIntentionalPartialWithdrawalBenefit() public {
        _deposit(alice, 50 ether);
        _deposit(bob, 50 ether);
        _withdraw(alice, 50 ether);
        _withdraw(bob, 50 ether);
        assertEq(simd.balanceOf(alice) + simd.balanceOf(bob), 90.95 ether);
        assertEq(simd.balanceOf(address(treasury)), 9.05 ether);
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
