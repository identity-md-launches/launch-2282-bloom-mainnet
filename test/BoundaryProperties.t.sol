// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture} from "./helpers/FarmFixture.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {BloomFarm} from "src/BloomFarm.sol";
import {FarmFactory} from "src/FarmFactory.sol";
import {SelectiveRoles} from "src/SelectiveRoles.sol";
import {Treasury} from "src/Treasury.sol";

contract BoundaryPropertiesTest is FarmFixture {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_allSupportedDecimalsKeepRewardsAndDonationsOutOfTheSharePrice(
        uint8 decimalSeed,
        uint256 amountSeed,
        uint256 donationSeed,
        bool sameToken
    ) public {
        uint8 decimals_ = uint8(bound(uint256(decimalSeed), 0, 18));
        uint256 scale = 10 ** (18 - decimals_);
        uint256 amount = bound(amountSeed, 1, type(uint128).max / (2 * scale));
        uint256 donation = bound(donationSeed, 1, type(uint128).max);
        MockToken underlying = new MockToken("test decimal asset", decimals_);
        if (sameToken) bloom = underlying;
        farm = new BloomFarm(
            owner,
            address(treasury),
            address(underlying),
            address(bloom),
            decimals_,
            sameToken ? BloomFarm.Kind.BLOOM : BloomFarm.Kind.SIMD
        );
        vm.prank(owner);
        farm.setDepositsPaused(false);
        uint256 firstShares = _deposit(alice, amount);
        assertEq(firstShares, amount * scale);
        _fund(type(uint128).max);
        underlying.mint(address(farm), donation);
        uint256 secondShares = _deposit(bob, amount);
        assertEq(secondShares, firstShares, "separate rewards and donations cannot dilute new deposits");
        assertEq(farm.accountedAssets(), 2 * amount);
        assertEq(farm.rewardReserve(), type(uint128).max);
        assertEq(farm.epochEnd(), 0, "funding still must not activate emissions");
        assertEq(farm.sweepSurplus(underlying), donation);
        vm.expectRevert(BloomFarm.NoSurplus.selector);
        farm.sweepSurplus(underlying);
        uint256 paid = _withdraw(alice, firstShares);
        paid += _withdraw(bob, secondShares);
        assertEq(underlying.balanceOf(address(treasury)) + paid, 2 * amount + donation);
        assertEq(farm.accountedAssets(), 0);
        assertEq(farm.rewardReserve(), type(uint128).max, "last exit cannot spend reward reserve");
        _assertAccounting();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_subUnitWithdrawalCannotBurnLowDecimalShares(uint8 decimalSeed, uint256 shareSeed)
        public
    {
        uint8 decimals_ = uint8(bound(uint256(decimalSeed), 0, 17));
        uint256 scale = 10 ** (18 - decimals_);
        MockToken underlying = new MockToken("test low decimal asset", decimals_);
        farm = new BloomFarm(
            owner, address(treasury), address(underlying), address(bloom), decimals_, BloomFarm.Kind.SIMD
        );
        vm.prank(owner);
        farm.setDepositsPaused(false);
        uint256 shares = _deposit(alice, 100);
        uint256 dustShares = bound(shareSeed, 1, scale - 1);
        vm.prank(alice);
        vm.expectRevert(BloomFarm.ZeroAssets.selector);
        farm.withdraw(dustShares, 0, payable(alice), false);
        assertEq(farm.sharesOf(alice), shares);
        assertEq(farm.totalShares(), shares);
        assertEq(farm.accountedAssets(), 100);
        assertEq(_withdraw(alice, shares), 85);
        assertEq(underlying.balanceOf(address(treasury)), 15);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_eighteenDecimalRepeatedRoundTripsCannotCreateUnderlying(
        uint256 seedAmount,
        uint8 cyclesSeed
    ) public {
        // Low-decimal full-position dust exits have a separate failing proof in .imd-findings.json.
        // This property checks repeated no-profit round trips for the 18-decimal fixture.
        MockToken underlying = simd;
        uint256 original = bound(seedAmount, 100, type(uint128).max / 4);
        uint256 cycles = bound(uint256(cyclesSeed), 2, 20);
        // The passive depositor owns the retained 14%, so the round-tripper cannot recapture it.
        _deposit(bob, original);
        underlying.mint(alice, original);
        vm.prank(alice);
        underlying.approve(address(farm), type(uint256).max);
        for (uint256 i; i < cycles; ++i) {
            uint256 balance = underlying.balanceOf(alice);
            uint256 expectedShares = farm.previewDeposit(balance);
            if (expectedShares == 0) {
                vm.prank(alice);
                vm.expectRevert(BloomFarm.ZeroShares.selector);
                farm.deposit(balance, 1);
                break;
            }
            vm.prank(alice);
            uint256 shares = farm.deposit(balance, expectedShares);
            uint256 got = _withdraw(alice, shares);
            assertLe(got, balance * 85 / 100, "a round trip cannot round up to extra value");
            assertEq(underlying.balanceOf(alice), got);
            assertEq(farm.sharesOf(alice), 0);
            if (got == 0) break;
        }
        assertLe(underlying.balanceOf(alice), original);
        assertEq(
            underlying.balanceOf(alice) + underlying.balanceOf(address(treasury)) + farm.accountedAssets(),
            2 * original
        );
        _withdraw(bob, farm.sharesOf(bob));
        assertEq(
            underlying.balanceOf(alice) + underlying.balanceOf(bob) + underlying.balanceOf(address(treasury)),
            2 * original
        );
        _assertAccounting();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_everySelectiveFarmRoleMaskIsIrreversibleAndLeavesClaimsAvailable(uint8 maskSeed)
        public
    {
        _deposit(alice, 1000);
        _fund(2000);
        _epoch(1000, 1);
        uint256 mask = bound(uint256(maskSeed), 1, 7);
        bytes32 confirmation = farm.renouncementHash(mask);
        vm.prank(owner);
        farm.renounceRoles(mask, confirmation);
        assertEq(farm.activeRoles(), 7 ^ mask);
        vm.prank(owner);
        vm.expectRevert(SelectiveRoles.InvalidRenouncement.selector);
        farm.renounceRoles(mask, confirmation);

        if (mask & 1 != 0) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(SelectiveRoles.RoleDisabled.selector, uint256(1)));
            farm.fundRewards(1);
        } else {
            _fund(1);
        }
        if (mask & 2 != 0) {
            vm.startPrank(owner);
            vm.expectRevert(abi.encodeWithSelector(SelectiveRoles.RoleDisabled.selector, uint256(2)));
            farm.setEpoch(0, 1, BloomFarm.EpochMode.Restart);
            vm.expectRevert(abi.encodeWithSelector(SelectiveRoles.RoleDisabled.selector, uint256(2)));
            farm.boost(1);
            vm.stopPrank();
        } else {
            vm.prank(owner);
            farm.boost(1);
        }
        vm.startPrank(owner);
        if (mask & 4 != 0) {
            vm.expectRevert(abi.encodeWithSelector(SelectiveRoles.RoleDisabled.selector, uint256(4)));
            farm.setDepositsPaused(true);
        } else {
            farm.setDepositsPaused(true);
            farm.setDepositsPaused(false);
        }
        vm.stopPrank();
        // Deposit and exit still work even if all administration has been renounced.
        _deposit(bob, 1000);
        _withdraw(bob, 1000);
        vm.warp(farm.epochEnd());
        _withdraw(alice, 1000);
        vm.prank(alice);
        assertEq(farm.claim(alice), mask & 2 == 0 ? 1001 : 1000);
        uint256 receivedFees = simd.balanceOf(address(treasury));
        vm.prank(owner);
        treasury.payToken(simd, owner, receivedFees);
        assertEq(simd.balanceOf(owner), receivedFees);
        assertEq(farm.activeRoles(), 7 ^ mask, "user activity cannot recover renounced powers");
        assertEq(farm.owner(), owner);
        assertEq(treasury.owner(), owner);
        _assertAccounting();
    }

    function test_factoryConfigRenouncementStillPermitsLaterFarms() public {
        uint256 role = factory.CONFIG_ROLE();
        bytes32 confirmation = factory.renouncementHash(role);
        vm.startPrank(owner);
        factory.renounceRoles(role, confirmation);
        for (uint256 i; i < 3; ++i) {
            BloomFarm created = factory.createFarm(BloomFarm.Kind(i));
            assertEq(created.owner(), owner);
            assertTrue(created.depositsPaused());
            assertEq(created.rewardBacking(), 0);
            assertEq(created.activeRoles(), 7, "factory and farm roles are independent");
            assertEq(factory.farms(i + 1), address(created));
        }
        vm.expectRevert(abi.encodeWithSelector(SelectiveRoles.RoleDisabled.selector, role));
        factory.setWhitelisted(address(bloom), false);
        vm.stopPrank();
        assertEq(factory.farmCount(), 4);
    }

    function test_creationRenouncementCannotBeUndoneByWhitelistChanges() public {
        uint256 role = factory.CREATE_ROLE();
        bytes32 confirmation = factory.renouncementHash(role);
        vm.startPrank(owner);
        factory.renounceRoles(role, confirmation);
        factory.setWhitelisted(address(simd), false);
        factory.setWhitelisted(address(simd), true);
        vm.expectRevert(abi.encodeWithSelector(SelectiveRoles.RoleDisabled.selector, role));
        factory.createFarm(BloomFarm.Kind.SIMD);
        vm.stopPrank();
        assertEq(factory.farmCount(), 1);
        _deposit(alice, 100);
        assertEq(_withdraw(alice, 100), 85, "factory finalization cannot disable an existing farm");
    }

    function test_renouncementConfirmationCannotBeReplayedOnAnotherChain() public {
        vm.chainId(1);
        bytes32 confirmation = farm.renouncementHash(4);
        vm.chainId(2);
        vm.prank(owner);
        vm.expectRevert(SelectiveRoles.InvalidRenouncement.selector);
        farm.renounceRoles(4, confirmation);
        assertEq(farm.activeRoles(), 7);
        vm.chainId(1);
        vm.prank(owner);
        farm.renounceRoles(4, confirmation);
        assertEq(farm.activeRoles(), 3);
    }

    function test_unknownRoleBitsAndUnauthorizedFactoryRenouncementAreRejected() public {
        bytes32 confirmation = farm.renouncementHash(type(uint256).max);
        vm.prank(owner);
        vm.expectRevert(SelectiveRoles.InvalidRenouncement.selector);
        farm.renounceRoles(type(uint256).max, confirmation);
        bytes32 factoryConfirmation = factory.renouncementHash(3);
        vm.prank(alice);
        vm.expectRevert(SelectiveRoles.Unauthorized.selector);
        factory.renounceRoles(3, factoryConfirmation);
        assertEq(farm.activeRoles(), 7);
        assertEq(factory.activeRoles(), 3);
    }

    function test_missingTreasuryIsRejectedOnFirstUseRatherThanDuringConstruction() public {
        address absent = makeAddr("test absent dependency");
        FarmFactory waiting = new FarmFactory(owner, absent);
        vm.startPrank(owner);
        vm.expectRevert(FarmFactory.InvalidTreasury.selector);
        waiting.configureToken(BloomFarm.Kind.BLOOM, address(bloom), keccak256("test evidence"));
        vm.expectRevert(FarmFactory.InvalidTreasury.selector);
        waiting.createFarm(BloomFarm.Kind.BLOOM);
        vm.stopPrank();
        assertEq(waiting.bloom(), address(0));
        assertEq(waiting.farmCount(), 0);
    }

    function test_missingTokenCodeAtCreationDoesNotAppendAPhantomFarm() public {
        vm.etch(address(simd), hex"");
        vm.prank(owner);
        vm.expectRevert(FarmFactory.InvalidToken.selector);
        factory.createFarm(BloomFarm.Kind.SIMD);
        assertEq(factory.farmCount(), 1);
    }

    function test_activationRejectsMissingDependenciesWithoutUnlockingRenouncement() public {
        address absent = makeAddr("test absent reward token");
        BloomFarm waiting =
            new BloomFarm(owner, address(treasury), address(simd), absent, 18, BloomFarm.Kind.SIMD);
        vm.prank(owner);
        vm.expectRevert(BloomFarm.UnsupportedAsset.selector);
        waiting.setDepositsPaused(false);
        assertTrue(waiting.depositsPaused());
        assertFalse(waiting.hasActivated());
        bytes32 confirmation = waiting.renouncementHash(4);
        vm.prank(owner);
        vm.expectRevert(SelectiveRoles.EssentialSetupIncomplete.selector);
        waiting.renounceRoles(4, confirmation);
    }

    function test_nativeTokenDecimalsMustBeEighteenAndConstructorsRejectUnsupportedDecimals() public {
        FarmFactory waiting = new FarmFactory(owner, address(treasury));
        MockToken six = new MockToken("test six decimal wrapper", 6);
        vm.prank(owner);
        vm.expectRevert(FarmFactory.InvalidToken.selector);
        waiting.configureToken(BloomFarm.Kind.ETH, address(six), keccak256("test evidence"));
        assertEq(waiting.weth(), address(0));
        vm.expectRevert(BloomFarm.UnsupportedAsset.selector);
        new BloomFarm(owner, address(treasury), address(six), address(bloom), 6, BloomFarm.Kind.ETH);
        vm.expectRevert(BloomFarm.UnsupportedAsset.selector);
        new BloomFarm(owner, address(treasury), address(simd), address(bloom), 19, BloomFarm.Kind.SIMD);
    }
}
