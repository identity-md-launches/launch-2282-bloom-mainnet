// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmFixture} from "./helpers/FarmFixture.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {BloomFarm} from "../src/BloomFarm.sol";
import {FarmFactory} from "../src/FarmFactory.sol";
import {Treasury} from "../src/Treasury.sol";
import {SelectiveRoles} from "../src/SelectiveRoles.sol";

contract AdminTest is FarmFixture {
    function testOwnershipAlwaysExplicitNotDeployer() public view {
        assertEq(factory.owner(), owner);
        assertEq(treasury.owner(), owner);
        assertEq(farm.owner(), owner);
        assertTrue(factory.owner() != address(this));
        assertTrue(farm.owner() != address(factory));
        assertEq(farm.treasury(), address(treasury));
        assertTrue(factory.isFarm(address(farm)));
        assertEq(factory.farms(0), address(farm));
        assertEq(factory.farmCount(), 1);
    }

    function testUnavailableBloomDoesNotBlockInfrastructureDeployment() public {
        FarmFactory waiting = new FarmFactory(owner, address(treasury));
        assertEq(waiting.owner(), owner);
        vm.startPrank(owner);
        vm.expectRevert(FarmFactory.NotConfigured.selector);
        waiting.createFarm(BloomFarm.Kind.BLOOM);
        waiting.configureToken(BloomFarm.Kind.BLOOM, address(bloom), keccak256("verified later"));
        vm.expectRevert(FarmFactory.NotWhitelisted.selector);
        waiting.createFarm(BloomFarm.Kind.BLOOM);
        waiting.setWhitelisted(address(bloom), true);
        BloomFarm later = waiting.createFarm(BloomFarm.Kind.BLOOM);
        vm.stopPrank();
        assertTrue(later.depositsPaused());
        assertEq(later.epochBudget(), 0);
        assertEq(later.owner(), owner);
    }

    function testUnconfiguredUnderlyingFailsAndIMDCannotBeWhitelisted() public {
        FarmFactory waiting = new FarmFactory(owner, address(treasury));
        MockToken imd = new MockToken("IMD", 18);
        vm.startPrank(owner);
        waiting.configureToken(BloomFarm.Kind.BLOOM, address(bloom), keccak256("verified"));
        waiting.setWhitelisted(address(bloom), true);
        vm.expectRevert(FarmFactory.NotConfigured.selector);
        waiting.createFarm(BloomFarm.Kind.SIMD);
        vm.expectRevert(FarmFactory.NotConfigured.selector);
        waiting.createFarm(BloomFarm.Kind.ETH);
        vm.expectRevert(FarmFactory.NotConfigured.selector);
        waiting.setWhitelisted(address(imd), true);
        vm.stopPrank();
    }

    function testAllOwnerPermissionsRejectOtherWallets() public {
        vm.startPrank(alice);
        vm.expectRevert(SelectiveRoles.Unauthorized.selector);
        factory.createFarm(BloomFarm.Kind.BLOOM);
        vm.expectRevert(SelectiveRoles.Unauthorized.selector);
        factory.configureToken(BloomFarm.Kind.BLOOM, address(bloom), keccak256("bad"));
        vm.expectRevert(SelectiveRoles.Unauthorized.selector);
        factory.setWhitelisted(address(simd), false);
        vm.expectRevert(SelectiveRoles.Unauthorized.selector);
        farm.setDepositsPaused(true);
        vm.expectRevert(SelectiveRoles.Unauthorized.selector);
        farm.fundRewards(1);
        vm.expectRevert(SelectiveRoles.Unauthorized.selector);
        farm.setEpoch(1, 1, BloomFarm.EpochMode.Restart);
        vm.expectRevert(SelectiveRoles.Unauthorized.selector);
        farm.boost(1);
        vm.expectRevert(SelectiveRoles.Unauthorized.selector);
        farm.renounceRoles(1, bytes32(0));
        vm.expectRevert(Treasury.Unauthorized.selector);
        treasury.payToken(simd, alice, 1);
        vm.expectRevert(Treasury.Unauthorized.selector);
        treasury.payNative(payable(alice), 1);
        vm.stopPrank();
    }

    function testClaimsSurviveAnUnderlyingShortfallWhileWithdrawalsRejectIt() public {
        _deposit(alice, 100 ether);
        _fund(1000 ether);
        _epoch(1000 ether, 10);
        vm.warp(block.timestamp + 5 days);
        simd.burn(address(farm), 1);
        vm.startPrank(alice);
        assertEq(farm.claim(alice), 500 ether);
        vm.expectRevert(BloomFarm.Insolvent.selector);
        farm.withdraw(100 ether, 0, payable(alice), false);
        vm.stopPrank();
        assertEq(bloom.balanceOf(alice), 500 ether);
        // A shortfall of the reward token itself still blocks claims.
        bloom.burn(address(farm), 1);
        vm.warp(farm.epochEnd());
        vm.prank(alice);
        vm.expectRevert(BloomFarm.Insolvent.selector);
        farm.claim(alice);
    }

    function testPauseHolderCapturesRetentionOfExitsMadeWhilePaused() public {
        // Documented trust assumption (SECURITY.md): the pauser decides who may still be staked when others exit.
        _deposit(owner, 100 ether);
        _deposit(alice, 10_000 ether);
        vm.prank(owner);
        farm.setDepositsPaused(true);
        vm.prank(bob);
        vm.expectRevert(BloomFarm.DepositsPaused.selector);
        farm.deposit(1 ether, 1);
        _withdraw(alice, 10_000 ether);
        (uint256 ownerGross,,,) = farm.previewWithdraw(100 ether);
        assertApproxEqAbs(ownerGross, 1500 ether, 1e10);
        assertEq(simd.balanceOf(address(treasury)), 100 ether);
        vm.prank(owner);
        farm.setDepositsPaused(false);
        _assertAccounting();
    }

    function testPauseLeavesWithdrawalsAndClaimsAvailable() public {
        _deposit(alice, 100 ether);
        _fund(100 ether);
        _epoch(100 ether, 1);
        vm.prank(owner);
        farm.setDepositsPaused(true);
        vm.prank(bob);
        vm.expectRevert(BloomFarm.DepositsPaused.selector);
        farm.deposit(1, 1);
        vm.warp(farm.epochEnd());
        vm.prank(alice);
        assertEq(farm.claim(alice), 100 ether);
        assertEq(_withdraw(alice, 100 ether), 85 ether);
        vm.prank(owner);
        farm.setDepositsPaused(false);
        _deposit(bob, 100 ether);
        _assertAccounting();
    }

    function testSelectiveFarmRenouncementIsPermanentAndTreasuryUnaffected() public {
        _deposit(alice, 100 ether);
        _fund(100 ether);
        _epoch(100 ether, 1);
        uint256 emissionRole = farm.EMISSION_ROLE();
        uint256 fundRole = farm.FUND_ROLE();
        // Giving up emissions while funding stays possible would only lock tokens.
        bytes32 emissionHash = farm.renouncementHash(emissionRole);
        bytes32 bothHash = farm.renouncementHash(fundRole | emissionRole);
        vm.startPrank(owner);
        vm.expectRevert(BloomFarm.RenouncementOrder.selector);
        farm.renounceRoles(emissionRole, emissionHash);
        farm.renounceRoles(fundRole | emissionRole, bothHash);
        vm.stopPrank();
        assertEq(farm.activeRoles(), farm.DEPOSIT_ROLE());
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(SelectiveRoles.RoleDisabled.selector, emissionRole));
        farm.boost(1);
        vm.expectRevert(abi.encodeWithSelector(SelectiveRoles.RoleDisabled.selector, fundRole));
        farm.fundRewards(1);
        farm.setDepositsPaused(true);
        vm.stopPrank();
        vm.warp(farm.epochEnd());
        _withdraw(alice, farm.sharesOf(alice));
        vm.prank(alice);
        farm.claim(alice);
        vm.prank(owner);
        treasury.payToken(simd, owner, 15 ether);
        assertEq(simd.balanceOf(owner), 15 ether);
        _assertAccounting();
    }

    function testFundRoleMayGoFirstAndStrandedReserveIsRecoverableOnlyAfterEmissionRenouncement() public {
        _fund(1000 ether);
        _epoch(1000 ether, 10);
        uint256 fundRole = farm.FUND_ROLE();
        uint256 emissionRole = farm.EMISSION_ROLE();
        bytes32 fundHash = farm.renouncementHash(fundRole);
        bytes32 emissionHash = farm.renouncementHash(emissionRole);
        vm.prank(owner);
        farm.renounceRoles(fundRole, fundHash);
        vm.expectRevert(BloomFarm.RoleStillActive.selector);
        farm.recoverStrandedReserve();
        vm.prank(owner);
        farm.renounceRoles(emissionRole, emissionHash);
        // Half the epoch vests with nobody staked, then alice earns the second half.
        vm.warp(block.timestamp + 5 days);
        _deposit(alice, 100 ether);
        vm.warp(farm.epochEnd());
        assertEq(farm.earned(alice), 500 ether);
        assertEq(farm.recoverStrandedReserve(), 500 ether);
        assertEq(bloom.balanceOf(address(treasury)), 500 ether);
        assertEq(farm.rewardReserve(), 0);
        assertEq(farm.totalRecovered(), 500 ether);
        vm.expectRevert(BloomFarm.NoSurplus.selector);
        farm.recoverStrandedReserve();
        vm.prank(alice);
        assertEq(farm.claim(alice), 500 ether);
        _withdraw(alice, 100 ether);
        _assertAccounting();
        assertEq(bloom.balanceOf(address(farm)), 0);
    }

    function testRenouncingAllFarmRolesDoesNotDisableUsersOrReenableViaUnknownCalls() public {
        _deposit(alice, 100 ether);
        _fund(100 ether);
        _epoch(100 ether, 1);
        uint256 roles = farm.activeRoles();
        bytes32 confirmation = farm.renouncementHash(roles);
        vm.prank(owner);
        farm.renounceRoles(roles, confirmation);
        assertEq(farm.activeRoles(), 0);
        _deposit(bob, 100 ether);
        vm.prank(owner);
        (bool ok,) = address(farm).call(abi.encodeWithSignature("grantRole(uint256,address)", 7, owner));
        assertFalse(ok);
        vm.prank(owner);
        (ok,) = address(farm).call(abi.encodeWithSignature("transferOwnership(address)", bob));
        assertFalse(ok);
        vm.warp(farm.epochEnd());
        _withdraw(alice, farm.sharesOf(alice));
        _withdraw(bob, farm.sharesOf(bob));
        vm.prank(alice);
        farm.claim(alice);
        _assertAccounting();
    }

    function testFarmRenouncementRequiresActivationScheduleAndUnpausedFinalDeposits() public {
        vm.startPrank(owner);
        BloomFarm fresh = factory.createFarm(BloomFarm.Kind.SIMD);
        uint256 depositRole = fresh.DEPOSIT_ROLE();
        bytes32 depositHash = fresh.renouncementHash(depositRole);
        vm.expectRevert(SelectiveRoles.EssentialSetupIncomplete.selector);
        fresh.renounceRoles(depositRole, depositHash);
        fresh.setDepositsPaused(false);
        uint256 emissionRole = fresh.EMISSION_ROLE();
        bytes32 emissionHash = fresh.renouncementHash(emissionRole);
        vm.expectRevert(SelectiveRoles.EssentialSetupIncomplete.selector);
        fresh.renounceRoles(emissionRole, emissionHash);
        fresh.setDepositsPaused(true);
        vm.expectRevert(SelectiveRoles.EssentialSetupIncomplete.selector);
        fresh.renounceRoles(depositRole, depositHash);
        vm.stopPrank();
    }

    function testRenouncementConfirmationCannotBeReplayedAcrossContractsOrRoles() public {
        uint256 role = farm.DEPOSIT_ROLE();
        bytes32 wrongContract = factory.renouncementHash(role);
        bytes32 wrongRole = farm.renouncementHash(farm.FUND_ROLE());
        vm.startPrank(owner);
        vm.expectRevert(SelectiveRoles.InvalidRenouncement.selector);
        farm.renounceRoles(role, wrongContract);
        vm.expectRevert(SelectiveRoles.InvalidRenouncement.selector);
        farm.renounceRoles(role, wrongRole);
        vm.expectRevert(SelectiveRoles.InvalidRenouncement.selector);
        farm.renounceRoles(0, bytes32(0));
        bytes32 valid = farm.renouncementHash(role);
        farm.renounceRoles(role, valid);
        vm.expectRevert(SelectiveRoles.InvalidRenouncement.selector);
        farm.renounceRoles(role, valid);
        vm.stopPrank();
    }

    function testFactoryRenouncementRequiresSetupAndCannotBeRecovered() public {
        FarmFactory waiting = new FarmFactory(owner, address(treasury));
        uint256 configRole = waiting.CONFIG_ROLE();
        uint256 creationRole = waiting.CREATE_ROLE();
        bytes32 configHash = waiting.renouncementHash(configRole);
        bytes32 createHash = waiting.renouncementHash(creationRole);
        vm.startPrank(owner);
        vm.expectRevert(SelectiveRoles.EssentialSetupIncomplete.selector);
        waiting.renounceRoles(configRole, configHash);
        vm.expectRevert(SelectiveRoles.EssentialSetupIncomplete.selector);
        waiting.renounceRoles(creationRole, createHash);
        uint256 all = factory.activeRoles();
        bytes32 allHash = factory.renouncementHash(all);
        factory.renounceRoles(all, allHash);
        vm.expectRevert(abi.encodeWithSelector(SelectiveRoles.RoleDisabled.selector, configRole));
        factory.setWhitelisted(address(simd), false);
        vm.expectRevert(abi.encodeWithSelector(SelectiveRoles.RoleDisabled.selector, creationRole));
        factory.createFarm(BloomFarm.Kind.SIMD);
        vm.stopPrank();
    }

    function testWhitelistDoesNotRetroactivelyDisableExistingFarms() public {
        _deposit(alice, 100 ether);
        vm.startPrank(owner);
        factory.setWhitelisted(address(simd), false);
        vm.expectRevert(FarmFactory.NotWhitelisted.selector);
        factory.createFarm(BloomFarm.Kind.SIMD);
        vm.stopPrank();
        assertEq(_withdraw(alice, 100 ether), 85 ether);
    }

    function testTokenConfigurationIsSingleUseAndRequiresEvidenceAndCode() public {
        FarmFactory waiting = new FarmFactory(owner, address(treasury));
        MockToken wrongDecimals = new MockToken("bad", 19);
        vm.startPrank(owner);
        vm.expectRevert(FarmFactory.InvalidToken.selector);
        waiting.configureToken(BloomFarm.Kind.BLOOM, address(bloom), bytes32(0));
        vm.expectRevert(FarmFactory.InvalidToken.selector);
        waiting.configureToken(BloomFarm.Kind.BLOOM, alice, keccak256("bad"));
        vm.expectRevert(FarmFactory.InvalidToken.selector);
        waiting.configureToken(BloomFarm.Kind.BLOOM, address(wrongDecimals), keccak256("bad"));
        waiting.configureToken(BloomFarm.Kind.BLOOM, address(bloom), keccak256("good"));
        vm.expectRevert(FarmFactory.AlreadyConfigured.selector);
        waiting.configureToken(BloomFarm.Kind.BLOOM, address(simd), keccak256("replacement"));
        vm.expectRevert(FarmFactory.InvalidToken.selector);
        waiting.configureToken(BloomFarm.Kind.SIMD, address(bloom), keccak256("duplicate"));
        vm.stopPrank();
    }

    function testWrongTreasuryOwnerRejectedOnFirstUse() public {
        Treasury wrong = new Treasury(alice);
        FarmFactory waiting = new FarmFactory(owner, address(wrong));
        vm.prank(owner);
        vm.expectRevert(FarmFactory.InvalidTreasury.selector);
        waiting.configureToken(BloomFarm.Kind.BLOOM, address(bloom), keccak256("good"));
    }

    function testTreasuryCannotReachFarmPrincipalOrRewardLiabilities() public {
        _deposit(alice, 100 ether);
        _fund(100 ether);
        vm.startPrank(owner);
        vm.expectRevert();
        treasury.payToken(simd, owner, 1);
        vm.expectRevert(BloomFarm.NoSurplus.selector);
        farm.sweepSurplus(simd);
        vm.expectRevert(BloomFarm.NoSurplus.selector);
        farm.sweepSurplus(bloom);
        vm.stopPrank();
        vm.prank(address(treasury));
        vm.expectRevert(BloomFarm.InsufficientShares.selector);
        farm.withdraw(1, 0, payable(owner), false);
        _assertAccounting();
    }
}
