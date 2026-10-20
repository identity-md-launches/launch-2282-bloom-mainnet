// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {FarmFixture} from "./helpers/FarmFixture.sol";
import {BloomFarm} from "../src/BloomFarm.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {Treasury} from "../src/Treasury.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract FarmHandler is Test {
    BloomFarm public immutable farm;
    MockToken public immutable asset;
    MockToken public immutable bloom;
    address public immutable owner;
    address public immutable treasury;
    address[8] public actors;
    uint256 public deposited;
    uint256 public grossWithdrawn;
    uint256 public retained;
    uint256 public paid;
    uint256 public treasuryPaid;
    uint256 public donations;
    uint256 public swept;
    uint256 public claimed;
    uint256 public funded;

    constructor(BloomFarm farm_, address owner_) {
        farm = farm_;
        owner = owner_;
        treasury = farm_.treasury();
        asset = MockToken(address(farm_.asset()));
        bloom = MockToken(address(farm_.rewardToken()));
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(100_000 + i));
        }
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        if (farm.depositsPaused()) return;
        address user = actors[actorSeed % actors.length];
        uint256 amount = bound(amountSeed, 1, 1e24);
        if (farm.previewDeposit(amount) == 0) return;
        asset.mint(user, amount);
        vm.startPrank(user);
        asset.approve(address(farm), amount);
        farm.deposit(amount, 1);
        vm.stopPrank();
        deposited += amount;
    }

    function withdraw(uint256 actorSeed, uint256 shareSeed) external {
        address user = actors[actorSeed % actors.length];
        uint256 balance = farm.sharesOf(user);
        if (balance == 0) return;
        uint256 shares = bound(shareSeed, 1, balance);
        _withdraw(user, shares);
    }

    function _withdraw(address user, uint256 shares) private {
        (uint256 gross, uint256 net, uint256 keep, uint256 fee) = farm.previewWithdraw(shares);
        assertEq(net, Math.mulDiv(gross, 85, 100));
        assertEq(gross, net + keep + fee);
        uint256 oldAssets = farm.accountedAssets();
        vm.prank(user);
        assertEq(farm.withdraw(shares, net, payable(user), false), net);
        assertEq(farm.accountedAssets(), oldAssets - gross + keep);
        grossWithdrawn += gross;
        retained += keep;
        paid += net;
        treasuryPaid += fee;
    }

    function fund(uint256 seed) external {
        uint256 amount = bound(seed, 1, 1e24);
        bloom.mint(owner, amount);
        uint256 oldEnd = farm.epochEnd();
        vm.startPrank(owner);
        bloom.approve(address(farm), amount);
        farm.fundRewards(amount);
        vm.stopPrank();
        assertEq(farm.epochEnd(), oldEnd);
        funded += amount;
    }

    function epoch(uint256 seed, uint8 daySeed, bool restart) external {
        uint256 amount = bound(seed, 0, farm.rewardReserve());
        if (farm.scheduledRewards() + amount == 0) return;
        if (farm.epochEnd() <= vm.getBlockTimestamp()) restart = true;
        // A completely vested old epoch contributes nothing after checkpointing.
        if (farm.epochEnd() <= vm.getBlockTimestamp() && amount == 0) return;
        uint256[8] memory previouslyEarned;
        for (uint256 i; i < actors.length; ++i) {
            previouslyEarned[i] = farm.earned(actors[i]);
        }
        uint256 days_ = restart ? bound(uint256(daySeed), 1, 30) : 0;
        vm.prank(owner);
        farm.setEpoch(amount, days_, restart ? BloomFarm.EpochMode.Restart : BloomFarm.EpochMode.Continue);
        for (uint256 i; i < actors.length; ++i) {
            assertEq(farm.earned(actors[i]), previouslyEarned[i]);
        }
    }

    function claim(uint256 actorSeed) external {
        _claim(actors[actorSeed % actors.length]);
    }

    function _claim(address user) private {
        uint256 expected = farm.earned(user);
        vm.prank(user);
        uint256 amount = farm.claim(user);
        assertEq(amount, expected);
        claimed += amount;
    }

    function advance(uint32 seed) external {
        vm.warp(vm.getBlockTimestamp() + bound(uint256(seed), 1, 40 days));
    }

    function checkpoint() external {
        farm.checkpoint();
    }

    function donate(uint128 seed) external {
        uint256 amount = bound(uint256(seed), 1, 1e24);
        uint256 beforeShares = farm.previewDeposit(1 ether);
        asset.mint(address(farm), amount);
        donations += amount;
        assertEq(farm.previewDeposit(1 ether), beforeShares);
    }

    function sweep() external {
        if (donations == swept) return;
        uint256 amount = farm.sweepSurplus(asset);
        assertEq(amount, donations - swept);
        swept += amount;
    }

    function pause(bool value) external {
        vm.prank(owner);
        farm.setDepositsPaused(value);
    }

    function exitAll() external {
        for (uint256 i; i < actors.length; ++i) {
            uint256 shares = farm.sharesOf(actors[i]);
            if (shares != 0) _withdraw(actors[i], shares);
            _claim(actors[i]);
        }
    }
}

abstract contract SharedFarmInvariants is FarmFixture {
    FarmHandler internal handler;

    function _target() internal {
        handler = new FarmHandler(farm, owner);
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.fund.selector;
        selectors[3] = handler.epoch.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.checkpoint.selector;
        selectors[7] = handler.donate.selector;
        selectors[8] = handler.sweep.selector;
        selectors[9] = handler.pause.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantPrincipalConservationAndTreasuryIsolation() public view {
        farm.assertSolvent();
        assertEq(farm.accountedAssets(), handler.deposited() + handler.retained() - handler.grossWithdrawn());
        assertEq(farm.accountedAssets() + handler.paid() + handler.treasuryPaid(), handler.deposited());
        assertEq(farm.asset().balanceOf(address(treasury)), handler.treasuryPaid() + handler.swept());
        uint256 expected = farm.accountedAssets() + handler.donations() - handler.swept();
        if (farm.asset() == farm.rewardToken()) expected += farm.rewardBacking();
        assertEq(farm.asset().balanceOf(address(farm)), expected);
    }

    function invariantRewardConservationAndCoverage() public view {
        assertEq(farm.totalFunded(), handler.funded());
        assertEq(farm.totalClaimed(), handler.claimed());
        assertEq(farm.rewardBacking() + farm.totalClaimed(), farm.totalFunded());
        uint256 accrued;
        uint256 earnedTotal;
        for (uint256 i; i < 8; ++i) {
            accrued += farm.accruedRewards(handler.actors(i));
            earnedTotal += farm.earned(handler.actors(i));
        }
        assertEq(accrued, farm.totalAccrued());
        assertLe(farm.totalAccrued(), farm.rewardLiability());
        assertLe(earnedTotal, farm.rewardBacking());
    }

    function invariantSharesAndEmptyPoolIsolation() public view {
        uint256 shares;
        for (uint256 i; i < 8; ++i) {
            shares += farm.sharesOf(handler.actors(i));
        }
        assertEq(shares, farm.totalShares());
        if (shares == 0) {
            assertEq(farm.accountedAssets(), 0);
            assertEq(farm.rewardLiability(), farm.totalAccrued());
        }
    }

    function afterInvariant() public {
        handler.exitAll();
        assertEq(farm.totalShares(), 0);
        assertEq(farm.accountedAssets(), 0);
        assertEq(farm.rewardLiability(), 0);
        assertEq(farm.totalAccrued(), 0);
        assertEq(handler.paid() + handler.treasuryPaid(), handler.deposited());
        assertEq(farm.rewardReserve() + farm.scheduledRewards() + farm.totalClaimed(), farm.totalFunded());
    }
}

contract SIMDInvariants is SharedFarmInvariants {
    function setUp() public override {
        super.setUp();
        _target();
    }
}

contract BLOOMInvariants is SharedFarmInvariants {
    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        farm = factory.createFarm(BloomFarm.Kind.BLOOM);
        farm.setDepositsPaused(false);
        vm.stopPrank();
        _target();
    }
}
