// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture} from "./helpers/FarmFixture.sol";
import {BloomFarm} from "../src/BloomFarm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract RewardsTest is FarmFixture {
    function testFundingNeverStartsEmissions() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(farm.epochEnd(), 0);
        assertEq(farm.earned(alice), 0);
        assertEq(farm.rewardReserve(), 1000 ether);
        assertEq(farm.accountedAssets(), 100 ether);
        _assertAccounting();
    }

    function testRewardsAccrueOnlyDuringOwnStakeAndClaimHasNoFee() public {
        _fund(1000 ether);
        _deposit(alice, 100 ether);
        _epoch(1000 ether, 10);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 5 days);
        _deposit(bob, 100 ether);
        assertEq(farm.earned(alice), 500 ether);
        assertEq(farm.earned(bob), 0);
        vm.warp(start + 10 days);
        assertEq(farm.earned(alice), 750 ether);
        assertEq(farm.earned(bob), 250 ether);
        vm.prank(alice);
        assertEq(farm.claim(alice), 750 ether);
        assertEq(bloom.balanceOf(alice), 750 ether);
        assertEq(bloom.balanceOf(address(treasury)), 0);
        assertEq(farm.accountedAssets(), 200 ether);
        _assertAccounting();
    }

    function testZeroStakerEmissionsReturnToReserveAndDoNotRewardNextDepositor() public {
        _fund(1000 ether);
        _epoch(1000 ether, 10);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 5 days);
        _deposit(alice, 100 ether);
        assertEq(farm.rewardReserve(), 500 ether);
        assertEq(farm.earned(alice), 0);
        vm.warp(start + 10 days);
        vm.prank(alice);
        assertEq(farm.claim(alice), 500 ether);
        _assertAccounting();
    }

    function testSameTimestampEntryExitCannotCapturePreviouslyAccruedRewards() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _epoch(1000 ether, 10);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        _deposit(bob, 100 ether);
        _withdraw(bob, farm.sharesOf(bob));
        vm.prank(bob);
        assertEq(farm.claim(bob), 0);
        assertEq(farm.earned(alice), 500 ether);
        _assertAccounting();
    }

    function testOneThousandUsersCanExitAndClaimWithoutLeakingRewards() public {
        uint256 count = 1000;
        for (uint256 i; i < count; ++i) {
            _deposit(address(uint160(10_000 + i)), 1 ether);
        }
        _fund(count * 1 ether);
        _epoch(count * 1 ether, 1);
        vm.warp(farm.epochEnd());
        uint256 paid;
        for (uint256 i; i < count; ++i) {
            address user = address(uint160(10_000 + i));
            paid += _withdraw(user, farm.sharesOf(user));
            vm.prank(user);
            assertEq(farm.claim(user), 1 ether);
        }
        assertEq(paid + simd.balanceOf(address(treasury)), count * 1 ether);
        assertEq(farm.totalClaimed(), count * 1 ether);
        assertEq(farm.rewardBacking(), 0);
        _assertAccounting();
    }

    function testContinueAndBoostPreserveFinishAndAccruedClaims() public {
        _deposit(alice, 100 ether);
        _fund(2000 ether);
        _epoch(1000 ether, 10);
        uint256 end = farm.epochEnd();
        uint256 startedAt = farm.epochStartedAt();
        vm.warp(vm.getBlockTimestamp() + 5 days);
        vm.prank(owner);
        farm.boost(500 ether);
        assertEq(farm.epochEnd(), end);
        assertEq(farm.epochId(), 1);
        assertEq(farm.epochStartedAt(), startedAt);
        assertEq(farm.epochStart(), vm.getBlockTimestamp());
        assertEq(farm.epochBudget(), 1000 ether);
        assertEq(farm.rewardLiability(), 500 ether);
        assertEq(farm.earned(alice), 500 ether);
        assertEq(farm.rewardReserve(), 500 ether);
        vm.warp(end);
        assertEq(farm.earned(alice), 1500 ether);
        _assertAccounting();
    }

    function testRestartOnlyReschedulesUnvestedPlusNewAllocation() public {
        _deposit(alice, 100 ether);
        _fund(1500 ether);
        _epoch(1000 ether, 10);
        vm.warp(vm.getBlockTimestamp() + 4 days);
        _epoch(500 ether, 20);
        assertEq(farm.epochId(), 2);
        assertEq(farm.epochStartedAt(), vm.getBlockTimestamp());
        assertEq(farm.epochBudget(), 1100 ether);
        assertEq(farm.rewardLiability(), 400 ether);
        assertEq(farm.earned(alice), 400 ether);
        assertEq(farm.epochEnd(), vm.getBlockTimestamp() + 20 days);
        vm.warp(vm.getBlockTimestamp() + 20 days);
        vm.prank(alice);
        assertEq(farm.claim(alice), 1500 ether);
        _assertAccounting();
    }

    function testNewAllocationCannotReuseLiabilities() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _epoch(1000 ether, 10);
        vm.warp(farm.epochEnd());
        vm.prank(owner);
        vm.expectRevert(BloomFarm.InsufficientReserve.selector);
        farm.setEpoch(1, 1, BloomFarm.EpochMode.Restart);
        vm.prank(alice);
        farm.claim(alice);
        _assertAccounting();
    }

    function testDurationModeAndReserveFailures() public {
        _fund(100);
        vm.startPrank(owner);
        vm.expectRevert(BloomFarm.NoActiveEpoch.selector);
        farm.boost(1);
        vm.expectRevert(BloomFarm.InvalidDuration.selector);
        farm.setEpoch(100, 0, BloomFarm.EpochMode.Restart);
        vm.expectRevert(BloomFarm.InvalidDuration.selector);
        farm.setEpoch(100, 3651, BloomFarm.EpochMode.Restart);
        vm.expectRevert(BloomFarm.InsufficientReserve.selector);
        farm.setEpoch(101, 1, BloomFarm.EpochMode.Restart);
        vm.expectRevert(BloomFarm.InvalidAmount.selector);
        farm.setEpoch(0, 1, BloomFarm.EpochMode.Restart);
        farm.setEpoch(100, 1, BloomFarm.EpochMode.Restart);
        vm.expectRevert(BloomFarm.InvalidDuration.selector);
        farm.setEpoch(0, 1, BloomFarm.EpochMode.Continue);
        vm.expectRevert(BloomFarm.InvalidAmount.selector);
        farm.boost(0);
        vm.stopPrank();
        vm.warp(farm.epochEnd());
        vm.prank(owner);
        vm.expectRevert(BloomFarm.NoActiveEpoch.selector);
        farm.setEpoch(0, 0, BloomFarm.EpochMode.Continue);
    }

    function testSmallBudgetVestsExactlyWithoutZeroRateLoss() public {
        _deposit(alice, 1);
        _fund(3);
        _epoch(3, 3650);
        vm.warp(farm.epochEnd());
        vm.prank(alice);
        assertEq(farm.claim(alice), 3);
        assertEq(farm.scheduledRewards(), 0);
        _assertAccounting();
    }

    function testPerAccountFractionsSurviveFrequentClaims() public {
        _deposit(alice, 1);
        _deposit(bob, 2);
        _fund(3);
        _epoch(3, 3);
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i = 1; i <= 3; ++i) {
            vm.warp(start + i * 1 days);
            vm.prank(alice);
            farm.claim(alice);
            vm.prank(bob);
            farm.claim(bob);
        }
        assertEq(bloom.balanceOf(alice), 1);
        assertEq(bloom.balanceOf(bob), 2);
        _assertAccounting();
    }

    function testGlobalRemainderPreventsCheckpointFrequencyGrief() public {
        uint256 shares = 1e38;
        _deposit(alice, shares);
        _fund(100);
        _epoch(100, 100);
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i = 1; i <= 100; ++i) {
            vm.warp(start + i * 1 days);
            vm.prank(bob);
            farm.checkpoint();
        }
        vm.prank(alice);
        assertEq(farm.claim(alice), 100);
        _assertAccounting();
    }

    function testEmptyPoolRecyclesOnlyDustAndPreservesOldClaims() public {
        _deposit(alice, 2);
        _deposit(bob, 1);
        _fund(10);
        _epoch(10, 1);
        vm.warp(farm.epochEnd());
        _withdraw(alice, 2);
        _withdraw(bob, 1);
        assertEq(farm.totalAccrued(), 9);
        assertEq(farm.rewardLiability(), 9);
        assertEq(farm.rewardReserve(), 1);
        _deposit(carol, 100);
        assertEq(farm.earned(carol), 0);
        vm.prank(alice);
        assertEq(farm.claim(alice), 6);
        vm.prank(bob);
        assertEq(farm.claim(bob), 3);
        _assertAccounting();
    }

    function testBloomFarmSeparatesPrincipalRewardsAndDonations() public {
        vm.startPrank(owner);
        farm = factory.createFarm(BloomFarm.Kind.BLOOM);
        farm.setDepositsPaused(false);
        vm.stopPrank();
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        assertEq(farm.accountedAssets(), 100 ether);
        assertEq(farm.previewDeposit(100 ether), 100 ether);
        _epoch(1000 ether, 1);
        vm.warp(farm.epochEnd());
        bloom.mint(address(farm), 50 ether);
        assertEq(farm.sweepSurplus(bloom), 50 ether);
        vm.expectRevert(BloomFarm.NoSurplus.selector);
        farm.sweepSurplus(bloom);
        assertEq(_withdraw(alice, 100 ether), 85 ether);
        assertEq(farm.rewardLiability(), 1000 ether);
        assertEq(farm.accountedAssets(), 0);
        vm.prank(alice);
        assertEq(farm.claim(alice), 1000 ether);
        assertEq(bloom.balanceOf(alice), 1085 ether);
        assertEq(bloom.balanceOf(address(treasury)), 65 ether);
        _assertAccounting();
    }

    function testSeparateFarmsNeverShareAssetsRewardsOrSchedules() public {
        BloomFarm first = farm;
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _epoch(1000 ether, 1);
        vm.startPrank(owner);
        farm = factory.createFarm(BloomFarm.Kind.SIMD);
        farm.setDepositsPaused(false);
        vm.stopPrank();
        _deposit(bob, 200 ether);
        assertEq(farm.rewardBacking(), 0);
        assertEq(farm.epochBudget(), 0);
        _withdraw(bob, 200 ether);
        vm.warp(first.epochEnd());
        assertEq(first.accountedAssets(), 100 ether);
        assertEq(first.earned(alice), 1000 ether);
        _assertAccounting();
    }

    function testFuzzEpochReconfigurationConservesFundedRewards(
        uint128 amountSeed,
        uint32 secondsSeed,
        uint16 daysSeed,
        bool restart
    ) public {
        uint256 funded = bound(uint256(amountSeed), 2, 1e30);
        uint256 initial = funded / 2;
        uint256 elapsed = bound(uint256(secondsSeed), 1, 10 days - 1);
        _deposit(alice, 1 ether);
        _fund(funded);
        _epoch(initial, 10);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + elapsed);
        uint256 vested = Math.mulDiv(initial, elapsed, 10 days);
        uint256 duration = restart ? bound(uint256(daysSeed), 1, 3650) : 0;
        vm.prank(owner);
        farm.setEpoch(
            funded - initial, duration, restart ? BloomFarm.EpochMode.Restart : BloomFarm.EpochMode.Continue
        );
        assertEq(farm.earned(alice), vested);
        assertEq(farm.epochBudget(), funded - vested);
        assertEq(farm.rewardBacking(), funded);
        vm.warp(farm.epochEnd());
        vm.prank(alice);
        assertEq(farm.claim(alice), funded);
        _assertAccounting();
    }
}
