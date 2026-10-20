// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture} from "./helpers/FarmFixture.sol";
import {BloomFarm} from "src/BloomFarm.sol";
import {SelectiveRoles} from "src/SelectiveRoles.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Properties of the revision that added ERC-4626-style virtual offsets, the last-exit residual
/// rule, the FUND-before-EMISSION renouncement order and permissionless stranded-reserve recovery.
contract VirtualOffsetAndRecoveryTest is FarmFixture {
    function _bloomFarm() internal {
        vm.startPrank(owner);
        farm = factory.createFarm(BloomFarm.Kind.BLOOM);
        farm.setDepositsPaused(false);
        vm.stopPrank();
    }

    function _renounce(uint256 roles) internal {
        bytes32 confirmation = farm.renouncementHash(roles);
        vm.prank(owner);
        farm.renounceRoles(roles, confirmation);
    }

    /// Model B: the 14% retention belongs to the remaining shares. With the virtual offset the remaining
    /// real holders must still receive all of it except the virtual shares' pro-rata part, which for any
    /// position of at least 1e12 shares (1e-6 of a token) is at most one millionth.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_retentionReachesRemainingHoldersExceptVirtualFraction(uint256 stay, uint256 leave)
        public
    {
        stay = bound(stay, 1e12, 1e27);
        leave = bound(leave, 1, 1e27);
        uint256 stayShares = _deposit(alice, stay);
        uint256 leaveShares = _deposit(bob, leave);
        assertEq(stayShares, stay, "empty-farm price is one share per wei");

        (uint256 gross,, uint256 retained, uint256 toTreasury) = farm.previewWithdraw(leaveShares);
        uint256 treasuryBefore = simd.balanceOf(address(treasury));
        uint256 net = _withdraw(bob, leaveShares);
        assertEq(simd.balanceOf(address(treasury)) - treasuryBefore, toTreasury);
        assertEq(net + retained + toTreasury, gross, "fee conservation on a partial exit");
        assertGe(toTreasury, Math.ceilDiv(gross, 100), "Treasury receives at least 1%");
        assertLe(gross, leave, "an immediate round trip never returns more than was deposited");

        // Exact Model B would let alice redeem every accounted unit as the last holder.
        uint256 pool = farm.accountedAssets();
        assertEq(pool, stay + leave - net - toTreasury);
        (uint256 aliceGross, uint256 aliceNet,, uint256 lastTreasury) = farm.previewWithdraw(stayShares);
        uint256 diverted = pool - aliceGross;
        assertLe(diverted, pool / 1e6 + 1, "virtual shares absorb at most one millionth of the pool");

        treasuryBefore = simd.balanceOf(address(treasury));
        assertEq(_withdraw(alice, stayShares), aliceNet);
        assertEq(aliceNet, Math.mulDiv(aliceGross, 85, 100));
        assertEq(simd.balanceOf(address(treasury)) - treasuryBefore, lastTreasury);
        assertEq(lastTreasury, pool - aliceNet, "the last exit pays every remaining unit to the Treasury");
        assertEq(farm.accountedAssets(), 0);
        assertEq(simd.balanceOf(address(farm)), 0, "no principal or dust stays behind for future depositors");
        assertEq(
            simd.balanceOf(alice) + simd.balanceOf(bob) + simd.balanceOf(address(treasury)), stay + leave
        );

        // The empty farm restarts at the initial price for the next depositor.
        assertEq(_deposit(carol, 1 ether), 1 ether);
        _assertAccounting();
    }

    /// Share price (A + vA) / (S + vS) never falls under any deposit or exit, so the first depositor's
    /// position is never diluted by rounding in favour of later ones.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_sharePriceIsMonotoneAcrossDepositsAndExits(uint256[6] memory amounts, uint256 exitSeed)
        public
    {
        address[3] memory users = [alice, bob, carol];
        uint256 num = farm.virtualAssets();
        uint256 den = farm.virtualShares();
        for (uint256 i; i < amounts.length; ++i) {
            address user = users[i % 3];
            if (i % 2 == 0 || farm.sharesOf(user) == 0) {
                uint256 amount = bound(amounts[i], 1, 1e24);
                if (farm.previewDeposit(amount) == 0) {
                    MockLike(address(simd)).mint(user, amount);
                    vm.startPrank(user);
                    simd.approve(address(farm), amount);
                    vm.expectRevert(BloomFarm.ZeroShares.selector);
                    farm.deposit(amount, 1);
                    vm.stopPrank();
                    continue;
                }
                _deposit(user, amount);
            } else {
                uint256 owned = farm.sharesOf(user);
                uint256 shares = bound(uint256(keccak256(abi.encode(exitSeed, i))), 1, owned);
                (uint256 gross,,,) = farm.previewWithdraw(shares);
                if (gross == 0 && shares != owned) continue;
                _withdraw(user, shares);
            }
            if (farm.totalShares() == 0) {
                num = farm.virtualAssets();
                den = farm.virtualShares();
                continue;
            }
            uint256 newNum = farm.accountedAssets() + farm.virtualAssets();
            uint256 newDen = farm.totalShares() + farm.virtualShares();
            assertGe(newNum * den, num * newDen, "share price fell");
            (num, den) = (newNum, newDen);
        }
        _assertAccounting();
    }

    /// The renouncement order is enforced on every combination: EMISSION alone, or EMISSION with DEPOSIT,
    /// is rejected while FUND survives; FUND may go first, alone, and EMISSION may then follow.
    function test_emissionRenouncementRequiresFundGoneFirstOrTogether() public {
        _deposit(alice, 1 ether);
        _fund(10 ether);
        _epoch(10 ether, 1);
        uint256 fundRole = farm.FUND_ROLE();
        uint256 emissionRole = farm.EMISSION_ROLE();
        uint256 depositRole = farm.DEPOSIT_ROLE();
        uint256[2] memory rejected = [emissionRole, emissionRole | depositRole];
        for (uint256 i; i < 2; ++i) {
            bytes32 confirmation = farm.renouncementHash(rejected[i]);
            vm.prank(owner);
            vm.expectRevert(BloomFarm.RenouncementOrder.selector);
            farm.renounceRoles(rejected[i], confirmation);
        }
        assertEq(farm.activeRoles(), fundRole | emissionRole | depositRole);
        // While EMISSION survives, nobody can pull the reserve.
        vm.prank(carol);
        vm.expectRevert(BloomFarm.RoleStillActive.selector);
        farm.recoverStrandedReserve();

        _renounce(fundRole);
        vm.prank(carol);
        vm.expectRevert(BloomFarm.RoleStillActive.selector);
        farm.recoverStrandedReserve();
        _renounce(emissionRole);
        assertEq(farm.activeRoles(), depositRole);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SelectiveRoles.RoleDisabled.selector, emissionRole));
        farm.setEpoch(0, 1, BloomFarm.EpochMode.Restart);
    }

    /// Recovery after EMISSION is gone takes only unallocated reserve: rewards already scheduled keep
    /// vesting and every earned unit stays claimable, while the BLOOM farm's principal (same token) is
    /// untouched. Any caller may trigger it; the tokens can only reach the Treasury.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_strandedRecoveryNeverReachesScheduledEarnedOrPrincipal(
        uint256 funded,
        uint256 scheduled,
        uint256 principal,
        uint256 stakeAfter,
        uint256 recoverAt,
        address caller
    ) public {
        vm.assume(caller != address(farm));
        _bloomFarm();
        funded = bound(funded, 1 ether, 1e27);
        scheduled = bound(scheduled, 1, funded);
        principal = bound(principal, 1e12, 1e27);
        _fund(funded);
        _epoch(scheduled, 10);
        uint256 end = farm.epochEnd();
        uint256 start = vm.getBlockTimestamp();
        stakeAfter = bound(stakeAfter, 0, 10 days);
        recoverAt = bound(recoverAt, stakeAfter, 12 days);

        _renounce(farm.FUND_ROLE() | farm.EMISSION_ROLE());
        vm.warp(start + stakeAfter);
        uint256 shares = _deposit(alice, principal);
        uint256 reserveBeforeStake = farm.rewardReserve();
        // Emissions that vested before alice staked returned to reserve, nothing else did.
        assertEq(reserveBeforeStake, funded - scheduled + Math.mulDiv(scheduled, stakeAfter, 10 days));

        vm.warp(start + recoverAt);
        // Crystallize vesting first so the snapshot compares like with like.
        farm.checkpoint();
        uint256 earnedBefore = farm.earned(alice);
        uint256 scheduledBefore = farm.scheduledRewards();
        uint256 reserve = farm.rewardReserve();
        uint256 treasuryBefore = bloom.balanceOf(address(treasury));
        if (reserve == 0) {
            vm.prank(caller);
            vm.expectRevert(BloomFarm.NoSurplus.selector);
            farm.recoverStrandedReserve();
        } else {
            vm.prank(caller);
            assertEq(farm.recoverStrandedReserve(), reserve);
            assertEq(bloom.balanceOf(address(treasury)) - treasuryBefore, reserve);
            assertEq(bloom.balanceOf(caller == address(treasury) ? address(0) : caller), 0);
        }
        assertEq(farm.earned(alice), earnedBefore, "recovery cannot touch earned rewards");
        assertEq(farm.scheduledRewards(), scheduledBefore, "recovery cannot touch scheduled rewards");
        assertEq(farm.accountedAssets(), principal, "recovery cannot touch principal");
        _assertAccounting();

        // Finish the epoch: alice receives everything vested while she was staked, minus index dust.
        vm.warp(end + 1);
        vm.prank(alice);
        uint256 claimed = farm.claim(alice);
        uint256 owed = scheduled - Math.mulDiv(scheduled, stakeAfter, 10 days);
        assertLe(claimed, owed);
        assertGe(claimed + 1, owed, "earned rewards survive recovery");
        _withdraw(alice, shares);
        if (farm.rewardReserve() != 0) farm.recoverStrandedReserve();
        _assertAccounting();
        assertEq(
            farm.totalClaimed() + farm.totalRecovered() + farm.rewardBacking(),
            funded,
            "every funded unit is claimed, recovered or still backed"
        );
        assertEq(bloom.balanceOf(address(farm)), farm.rewardBacking(), "principal fully exited");
    }
}

interface MockLike {
    function mint(address to, uint256 amount) external;
}
