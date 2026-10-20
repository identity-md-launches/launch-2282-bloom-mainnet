// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FarmFixture} from "./helpers/FarmFixture.sol";
import {MockToken} from "./helpers/Mocks.sol";
import {BloomFarm} from "src/BloomFarm.sol";

/// @dev Independent integral oracle: three fixed stakes have weights 1:3:4.
/// Integer rates divisible by eight make every expected user amount exact.
/// This oracle never reads rewardIndex, paidIndex, accruedRewards or earned to calculate an entitlement.
contract RewardOracleHandler is Test {
    BloomFarm public immutable farm;
    MockToken public immutable bloom;
    address public immutable owner;
    address[3] public actors;
    uint256[3] public weights = [uint256(1), 3, 4];
    uint256[3] public owed;
    uint256[3] public received;
    uint256 public modelRate;
    uint256 public modelLast;
    uint256 public modelEnd;
    uint256 public modelStarted;
    uint256 public modelEpoch;
    uint256 public modelReserve;
    uint256 public funded;
    uint256 public claimed;
    uint256 public restarts;
    uint256 public continues;
    uint256 public boosts;

    constructor(BloomFarm farm_, address owner_) {
        farm = farm_;
        bloom = MockToken(address(farm_.rewardToken()));
        owner = owner_;
        MockToken underlying = MockToken(address(farm_.asset()));
        for (uint256 i; i < 3; ++i) {
            address user = makeAddr(string.concat("reward oracle ", vm.toString(i)));
            actors[i] = user;
            uint256 depositAmount = weights[i] * 1 ether;
            underlying.mint(user, depositAmount);
            vm.startPrank(user);
            underlying.approve(address(farm_), depositAmount);
            farm_.deposit(depositAmount, depositAmount);
            vm.stopPrank();
        }
    }

    function expected(uint256 i) public view returns (uint256) {
        uint256 end = vm.getBlockTimestamp() < modelEnd ? vm.getBlockTimestamp() : modelEnd;
        uint256 elapsed = end > modelLast ? end - modelLast : 0;
        return owed[i] + elapsed * modelRate * weights[i] / 8;
    }

    function _settle() private {
        uint256 end = vm.getBlockTimestamp() < modelEnd ? vm.getBlockTimestamp() : modelEnd;
        if (end <= modelLast) return;
        uint256 emission = (end - modelLast) * modelRate;
        for (uint256 i; i < 3; ++i) {
            owed[i] += emission * weights[i] / 8;
        }
        modelLast = end;
    }

    function _fund(uint256 amount) private {
        if (amount == 0) return;
        bloom.mint(owner, amount);
        vm.startPrank(owner);
        bloom.approve(address(farm), amount);
        farm.fundRewards(amount);
        vm.stopPrank();
        modelReserve += amount;
        funded += amount;
    }

    function fund(uint256 amountSeed) public {
        _settle();
        _fund(bound(amountSeed, 1, 1e24));
    }

    function restart(uint256 rateSeed, uint256 daysSeed) public {
        _settle();
        uint256 now_ = vm.getBlockTimestamp();
        uint256 duration = bound(daysSeed, 1, 3650) * 1 days;
        uint256 unvested = modelEnd > now_ ? (modelEnd - now_) * modelRate : 0;
        uint256 rate = 8 * (unvested / (8 * duration) + bound(rateSeed, 1, 1e12));
        uint256 allocation = rate * duration - unvested;
        if (allocation > modelReserve) _fund(allocation - modelReserve);
        vm.prank(owner);
        farm.setEpoch(allocation, duration / 1 days, BloomFarm.EpochMode.Restart);
        modelReserve -= allocation;
        modelRate = rate;
        modelLast = now_;
        modelEnd = now_ + duration;
        modelStarted = now_;
        ++modelEpoch;
        ++restarts;
    }

    function continueEpoch(uint256 rateSeed, bool useBoost) public {
        _settle();
        uint256 now_ = vm.getBlockTimestamp();
        if (now_ >= modelEnd) {
            vm.prank(owner);
            vm.expectRevert(BloomFarm.NoActiveEpoch.selector);
            if (useBoost) farm.boost(1);
            else farm.setEpoch(1, 0, BloomFarm.EpochMode.Continue);
            return;
        }
        uint256 increase = bound(rateSeed, 1, 1e12) * 8;
        uint256 allocation = increase * (modelEnd - now_);
        if (allocation > modelReserve) _fund(allocation - modelReserve);
        vm.prank(owner);
        if (useBoost) {
            farm.boost(allocation);
            ++boosts;
        } else {
            farm.setEpoch(allocation, 0, BloomFarm.EpochMode.Continue);
            ++continues;
        }
        modelRate += increase;
        modelReserve -= allocation;
        modelLast = now_;
    }

    function advance(uint256 secondsSeed) public {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 4000 days));
    }

    function claim(uint256 actorSeed) public {
        _settle();
        uint256 i = actorSeed % 3;
        uint256 beforeBalance = bloom.balanceOf(actors[i]);
        vm.prank(actors[i]);
        uint256 amount = farm.claim(actors[i]);
        assertEq(amount, owed[i], "claim must equal independently integrated emissions");
        assertEq(bloom.balanceOf(actors[i]) - beforeBalance, owed[i]);
        received[i] += owed[i];
        claimed += owed[i];
        owed[i] = 0;
    }

    function checkpoint() public {
        _settle();
        farm.checkpoint();
    }

    function pause(bool paused) public {
        vm.prank(owner);
        farm.setDepositsPaused(paused);
    }

    function claimAll() external {
        for (uint256 i; i < 3; ++i) {
            claim(i);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract RewardOracleInvariants is FarmFixture {
    RewardOracleHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new RewardOracleHandler(farm, owner);
        handler.restart(1e9, 7);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.restart.selector;
        selectors[2] = handler.continueEpoch.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.checkpoint.selector;
        selectors[6] = handler.pause.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_independentOracleMatchesEveryUser() public view {
        uint256 outstanding;
        for (uint256 i; i < 3; ++i) {
            assertEq(farm.earned(handler.actors(i)), handler.expected(i));
            assertEq(bloom.balanceOf(handler.actors(i)), handler.received(i));
            outstanding += handler.expected(i);
        }
        uint256 unvested = handler.modelEnd() > vm.getBlockTimestamp()
            ? (handler.modelEnd() - vm.getBlockTimestamp()) * handler.modelRate()
            : 0;
        assertEq(outstanding + handler.claimed() + unvested + handler.modelReserve(), handler.funded());
        assertEq(farm.rewardReserve(), handler.modelReserve());
        assertEq(farm.totalClaimed(), handler.claimed());
        assertEq(farm.rewardBacking() + handler.claimed(), handler.funded());
        assertEq(bloom.balanceOf(address(farm)) + handler.claimed(), handler.funded());
        assertEq(farm.epochEnd(), handler.modelEnd());
        assertEq(farm.epochStartedAt(), handler.modelStarted());
        assertEq(farm.epochId(), handler.modelEpoch());
        assertEq(farm.accountedAssets(), 8 ether, "reward control cannot change underlying assets");
    }

    function afterInvariant() public {
        handler.claimAll();
        invariant_independentOracleMatchesEveryUser();
        assertEq(farm.totalAccrued(), 0);
        assertEq(farm.rewardLiability(), 0, "integer oracle leaves no unpayable dust");
    }

    function test_oracleExercisesContinueRestartBoostAndExpiredFailure() public {
        handler.advance(1 days);
        handler.claim(0);
        handler.continueEpoch(123, false);
        handler.advance(1 days);
        handler.continueEpoch(456, true);
        handler.restart(789, 1);
        handler.advance(1 days);
        handler.continueEpoch(1, true);
        handler.continueEpoch(1, false);
        assertEq(handler.restarts(), 2);
        assertEq(handler.continues(), 1);
        assertEq(handler.boosts(), 1);
        afterInvariant();
    }
}

contract RewardBoundaryTest is FarmFixture {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_staggeredEntryAndExitUsesSharesRatherThanCompoundedAssetBalances(
        uint256 rateSeed,
        uint256 durationSeed
    ) public {
        uint256 rate = bound(rateSeed, 1, 1e18) * 4;
        uint256 quarter = bound(durationSeed, 1, 900) * 1 days;
        uint256 budget = rate * quarter * 4;
        _deposit(alice, 1 ether);
        _fund(budget);
        _epoch(budget, quarter * 4 / 1 days);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + quarter);
        _deposit(bob, 1 ether);
        vm.warp(start + 2 * quarter);
        _deposit(carol, 2 ether);
        vm.warp(start + 3 * quarter);
        // Bob's exit increases assets per share but must not change reward weights.
        _withdraw(bob, 1 ether);
        _withdraw(alice, 1 ether);
        vm.warp(start + 4 * quarter);
        vm.prank(alice);
        assertEq(farm.claim(alice), rate * quarter * 7 / 4);
        vm.prank(bob);
        assertEq(farm.claim(bob), rate * quarter * 3 / 4);
        vm.prank(carol);
        assertEq(farm.claim(carol), rate * quarter * 3 / 2);
        assertEq(farm.totalClaimed(), budget);
        assertEq(bloom.balanceOf(address(treasury)), 0, "rewards are not subject to withdrawal fees");
        _withdraw(carol, 2 ether);
        _assertAccounting();
    }

    function test_epochStartEndAndOneSecondOutsideAreExact() public {
        _deposit(alice, 1 ether);
        _fund(1 days);
        _epoch(1 days, 1);
        uint256 start = vm.getBlockTimestamp();
        assertEq(farm.earned(alice), 0);
        vm.warp(start + 1);
        assertEq(farm.earned(alice), 1);
        vm.warp(start + 1 days - 1);
        assertEq(farm.earned(alice), 1 days - 1);
        vm.warp(start + 1 days);
        assertEq(farm.earned(alice), 1 days);
        vm.warp(start + 1 days + 1);
        assertEq(farm.earned(alice), 1 days);
        vm.prank(owner);
        vm.expectRevert(BloomFarm.NoActiveEpoch.selector);
        farm.boost(1);
        vm.prank(alice);
        assertEq(farm.claim(alice), 1 days);
    }

    function test_expiredEmptyEpochCanAllocateTheJustRecycledReserve() public {
        _fund(172800);
        _epoch(172800, 2);
        vm.warp(farm.epochEnd());
        // There has been no keeper checkpoint: setEpoch must first return the empty epoch to reserve.
        _epoch(172800, 1);
        _deposit(alice, 1 ether);
        vm.warp(farm.epochEnd());
        vm.prank(alice);
        assertEq(farm.claim(alice), 172800);
        assertEq(farm.totalFunded(), 172800);
        _assertAccounting();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_checkpointAndClaimFrequencyCannotChangeRewards(uint256 stakeSeed, uint256 budgetSeed)
        public
    {
        uint256 stake = bound(stakeSeed, 1, type(uint128).max);
        uint256 budget = bound(budgetSeed, 1, type(uint128).max);
        _deposit(alice, stake);
        _fund(budget);
        _epoch(budget, 1);
        uint256 start = vm.getBlockTimestamp();
        uint256 saved = vm.snapshotState();
        vm.warp(start + 1 days);
        vm.prank(alice);
        uint256 once = farm.claim(alice);
        assertTrue(vm.revertToState(saved));
        uint256 frequent;
        for (uint256 i = 1; i <= 19; ++i) {
            vm.warp(start + 1 days * i / 19);
            farm.checkpoint();
            vm.prank(alice);
            frequent += farm.claim(alice);
        }
        assertEq(frequent, once, "frequency may not confiscate whole-unit rewards");
        _assertAccounting();
    }
}
