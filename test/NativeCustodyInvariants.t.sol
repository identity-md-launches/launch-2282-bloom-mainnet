// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FarmFixture} from "./helpers/FarmFixture.sol";
import {MockToken, MockWETH, RejectETH, GasHungryReceiver, ReentrantReceiver} from "./helpers/Mocks.sol";
import {BloomFarm} from "src/BloomFarm.sol";
import {Treasury} from "src/Treasury.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Ghost accounting uses actual inputs and recipient balance changes, not farm previews.
/// All WETH in this harness is created by depositing ETH, including donations.
contract NativeCustodyHandler is Test {
    BloomFarm public immutable farm;
    Treasury public immutable treasury;
    MockWETH public immutable weth;
    MockToken public immutable bloom;
    address public immutable owner;
    address public immutable beneficiary;
    address[5] public actors;
    uint256[5] public modelShares;

    uint256 public deposited;
    uint256 public paidUsers;
    uint256 public feeReceipts;
    uint256 public nativeDonations;
    uint256 public wrappedDonations;
    uint256 public sweptNative;
    uint256 public sweptWrapped;
    uint256 public treasuryNativePaid;
    uint256 public treasuryWrappedPaid;
    uint256 public funded;
    uint256 public claimed;
    uint256 public rewardDonations;
    uint256 public sweptRewards;
    uint256 public treasuryRewardsPaid;
    uint256 public successfulWithdrawals;
    uint256 public successfulClaims;
    uint256 public fallbackWithdrawals;

    constructor(BloomFarm farm_, Treasury treasury_, address owner_) {
        farm = farm_;
        treasury = treasury_;
        owner = owner_;
        weth = MockWETH(payable(address(farm_.asset())));
        bloom = MockToken(address(farm_.rewardToken()));
        beneficiary = makeAddr("native invariant treasury beneficiary");
        actors[0] = makeAddr("native invariant alice");
        actors[1] = makeAddr("native invariant bob");
        actors[2] = address(new RejectETH());
        actors[3] = address(new GasHungryReceiver());
        actors[4] = address(new ReentrantReceiver(farm_));
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) public {
        uint256 i = actorSeed % actors.length;
        address user = actors[i];
        uint256 amount = bound(amountSeed, 1, 1000 ether);
        uint256 beforeShares = farm.totalShares();
        uint256 beforeAssets = farm.accountedAssets();
        vm.deal(user, user.balance + amount);
        if (farm.depositsPaused()) {
            vm.prank(user);
            vm.expectRevert(BloomFarm.DepositsPaused.selector);
            farm.depositETH{value: amount}(1);
            return;
        }
        // Independent model of the virtual-offset price: floor(amount * (S + vS) / (A + vA)).
        uint256 vS = farm.virtualShares();
        uint256 vA = farm.virtualAssets();
        uint256 expected = Math.mulDiv(amount, beforeShares + vS, beforeAssets + vA);
        if (expected == 0) {
            vm.prank(user);
            vm.expectRevert(BloomFarm.ZeroShares.selector);
            farm.depositETH{value: amount}(1);
            return;
        }
        vm.prank(user);
        uint256 minted = farm.depositETH{value: amount}(expected);
        assertEq(minted, expected, "deposit mints exactly the rounded-down virtual-price quote");
        if (beforeShares == 0) assertEq(minted, amount, "empty-farm price is one share per wei");
        assertEq(farm.accountedAssets(), beforeAssets + amount);
        modelShares[i] += minted;
        deposited += amount;
    }

    function withdraw(uint256 actorSeed, uint256 shareSeed, uint256 recipientSeed, bool asWETH, bool full)
        public
    {
        uint256 i = actorSeed % actors.length;
        if (modelShares[i] == 0) return;
        uint256 shares = full ? modelShares[i] : bound(shareSeed, 1, modelShares[i]);
        address recipient = actors[recipientSeed % actors.length];
        uint256 supply = farm.totalShares();
        uint256 assets = farm.accountedAssets();
        uint256 gross = Math.mulDiv(shares, assets + farm.virtualAssets(), supply + farm.virtualShares());
        uint256 expectedNet = gross * 85 / 100;
        // The last exit pays the Treasury everything the user does not receive; otherwise 1% rounded up.
        uint256 expectedTreasury = shares == supply ? assets - expectedNet : (gross + 99) / 100;
        if (gross == 0 && shares != modelShares[i]) {
            vm.prank(actors[i]);
            vm.expectRevert(BloomFarm.ZeroAssets.selector);
            farm.withdraw(shares, 0, payable(recipient), asWETH);
            return;
        }
        assertLe(expectedNet + expectedTreasury, assets, "an exit never pays out more than the pool holds");
        // Price per share (A + vA) / (S + vS) must never fall across an exit.
        uint256 priceNum = assets + farm.virtualAssets();
        uint256 priceDen = supply + farm.virtualShares();
        uint256 beforeNative = recipient.balance;
        uint256 beforeWrapped = weth.balanceOf(recipient);
        uint256 beforeTreasury = address(treasury).balance;

        vm.prank(actors[i]);
        assertEq(farm.withdraw(shares, expectedNet, payable(recipient), asWETH), expectedNet);

        uint256 nativePaid = recipient.balance - beforeNative;
        uint256 wrappedPaid = weth.balanceOf(recipient) - beforeWrapped;
        assertEq(nativePaid + wrappedPaid, expectedNet, "exactly one delivery of the 85% payout");
        assertEq(address(treasury).balance - beforeTreasury, expectedTreasury);
        assertEq(farm.accountedAssets(), assets - expectedNet - expectedTreasury);
        if (asWETH) {
            assertEq(nativePaid, 0);
        } else if (recipient == actors[2] || recipient == actors[3]) {
            assertEq(nativePaid, 0);
            assertEq(wrappedPaid, expectedNet);
            if (expectedNet != 0) ++fallbackWithdrawals;
        } else {
            assertEq(wrappedPaid, 0);
        }
        modelShares[i] -= shares;
        if (farm.totalShares() != 0) {
            assertGe(
                (farm.accountedAssets() + farm.virtualAssets()) * priceDen,
                priceNum * (farm.totalShares() + farm.virtualShares()),
                "exits never lower the price of a remaining share"
            );
        }
        paidUsers += nativePaid + wrappedPaid;
        feeReceipts += address(treasury).balance - beforeTreasury;
        ++successfulWithdrawals;
    }

    function fund(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 1, 1000 ether);
        uint256 beforeBudget = farm.epochBudget();
        uint256 beforeStart = farm.epochStart();
        uint256 beforeEnd = farm.epochEnd();
        bloom.mint(owner, amount);
        vm.startPrank(owner);
        bloom.approve(address(farm), amount);
        farm.fundRewards(amount);
        vm.stopPrank();
        funded += amount;
        assertEq(farm.epochBudget(), beforeBudget, "funding must not change the schedule");
        assertEq(farm.epochStart(), beforeStart);
        assertEq(farm.epochEnd(), beforeEnd);
    }

    function schedule(uint256 amountSeed, uint256 daysSeed, bool restart) public {
        farm.checkpoint();
        uint256 allocation = bound(amountSeed, 0, farm.rewardReserve());
        if (allocation + farm.scheduledRewards() == 0) return;
        restart = restart || farm.epochEnd() <= vm.getBlockTimestamp();
        uint256 duration = restart ? bound(daysSeed, 1, 3650) : 0;
        uint256 oldEnd = farm.epochEnd();
        uint256 oldId = farm.epochId();
        uint256[5] memory oldEarned;
        for (uint256 i; i < actors.length; ++i) {
            oldEarned[i] = farm.earned(actors[i]);
        }
        vm.prank(owner);
        farm.setEpoch(
            allocation, duration, restart ? BloomFarm.EpochMode.Restart : BloomFarm.EpochMode.Continue
        );
        assertEq(farm.epochId(), oldId + (restart ? 1 : 0));
        assertEq(farm.epochEnd(), restart ? vm.getBlockTimestamp() + duration * 1 days : oldEnd);
        for (uint256 i; i < actors.length; ++i) {
            assertEq(farm.earned(actors[i]), oldEarned[i], "rescheduling cannot confiscate earned rewards");
        }
    }

    function claim(uint256 actorSeed, uint256 recipientSeed) public {
        address user = actors[actorSeed % actors.length];
        address recipient = actors[recipientSeed % actors.length];
        uint256 beforeBalance = bloom.balanceOf(recipient);
        uint256 beforeShares = farm.sharesOf(user);
        uint256 beforeAssets = farm.accountedAssets();
        vm.prank(user);
        uint256 amount = farm.claim(recipient);
        assertEq(bloom.balanceOf(recipient) - beforeBalance, amount, "rewards have no withdrawal fee");
        assertEq(farm.sharesOf(user), beforeShares);
        assertEq(farm.accountedAssets(), beforeAssets);
        claimed += bloom.balanceOf(recipient) - beforeBalance;
        if (amount != 0) ++successfulClaims;
        vm.prank(user);
        assertEq(farm.claim(recipient), 0, "a same-time second claim cannot pay again");
    }

    function advance(uint256 secondsSeed) public {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 4000 days));
    }

    function checkpoint() public {
        farm.checkpoint();
        uint256 index = farm.rewardIndex();
        uint256 backing = farm.rewardBacking();
        farm.checkpoint();
        assertEq(farm.rewardIndex(), index, "same-time checkpoint is idempotent");
        assertEq(farm.rewardBacking(), backing);
    }

    function pause(bool paused) public {
        vm.prank(owner);
        farm.setDepositsPaused(paused);
    }

    function donate(uint256 amountSeed, uint8 kindSeed) public {
        uint256 amount = bound(amountSeed, 1, 1000 ether);
        uint256 beforeAssets = farm.accountedAssets();
        uint256 beforeBacking = farm.rewardBacking();
        uint256 beforeQuote = farm.previewDeposit(1 ether);
        if (kindSeed % 3 == 0) {
            // Models forced ETH without a SELFDESTRUCT helper.
            vm.deal(address(farm), address(farm).balance + amount);
            nativeDonations += amount;
        } else if (kindSeed % 3 == 1) {
            vm.deal(address(this), amount);
            weth.deposit{value: amount}();
            weth.transfer(address(farm), amount);
            wrappedDonations += amount;
        } else {
            bloom.mint(address(farm), amount);
            rewardDonations += amount;
        }
        assertEq(farm.accountedAssets(), beforeAssets);
        assertEq(farm.rewardBacking(), beforeBacking);
        assertEq(farm.previewDeposit(1 ether), beforeQuote);
    }

    function sweep(uint8 kindSeed) public {
        uint256 beforeAssets = farm.accountedAssets();
        uint256 beforeBacking = farm.rewardBacking();
        if (kindSeed % 3 == 0) {
            if (nativeDonations == sweptNative) {
                vm.expectRevert(BloomFarm.NoSurplus.selector);
                farm.sweepNativeDonations();
            } else {
                uint256 balance = address(treasury).balance;
                farm.sweepNativeDonations();
                uint256 received = address(treasury).balance - balance;
                assertEq(received, nativeDonations - sweptNative);
                sweptNative += received;
            }
        } else if (kindSeed % 3 == 1) {
            if (wrappedDonations == sweptWrapped) {
                vm.expectRevert(BloomFarm.NoSurplus.selector);
                farm.sweepSurplus(weth);
            } else {
                uint256 balance = weth.balanceOf(address(treasury));
                assertEq(farm.sweepSurplus(weth), wrappedDonations - sweptWrapped);
                sweptWrapped += weth.balanceOf(address(treasury)) - balance;
            }
        } else {
            if (rewardDonations == sweptRewards) {
                vm.expectRevert(BloomFarm.NoSurplus.selector);
                farm.sweepSurplus(bloom);
            } else {
                uint256 balance = bloom.balanceOf(address(treasury));
                assertEq(farm.sweepSurplus(bloom), rewardDonations - sweptRewards);
                sweptRewards += bloom.balanceOf(address(treasury)) - balance;
            }
        }
        assertEq(farm.accountedAssets(), beforeAssets, "sweeps cannot reach share backing");
        assertEq(farm.rewardBacking(), beforeBacking, "sweeps cannot reach any reward bucket");
    }

    function treasuryPay(uint256 amountSeed, uint8 kindSeed, bool unauthorized) public {
        uint256 nativeBefore = address(treasury).balance;
        uint256 wrappedBefore = weth.balanceOf(address(treasury));
        uint256 rewardBefore = bloom.balanceOf(address(treasury));
        uint256 balance = kindSeed % 3 == 0 ? nativeBefore : kindSeed % 3 == 1 ? wrappedBefore : rewardBefore;
        uint256 amount = balance == 0 ? 1 : bound(amountSeed, 1, balance);
        if (unauthorized) {
            vm.prank(actors[0]);
            vm.expectRevert(Treasury.Unauthorized.selector);
            if (kindSeed % 3 == 0) treasury.payNative(payable(beneficiary), amount);
            else treasury.payToken(kindSeed % 3 == 1 ? weth : bloom, beneficiary, amount);
            assertEq(address(treasury).balance, nativeBefore);
            assertEq(weth.balanceOf(address(treasury)), wrappedBefore);
            assertEq(bloom.balanceOf(address(treasury)), rewardBefore);
            return;
        }
        if (balance == 0) return;
        vm.prank(owner);
        if (kindSeed % 3 == 0) {
            treasury.payNative(payable(beneficiary), amount);
            treasuryNativePaid += amount;
        } else if (kindSeed % 3 == 1) {
            treasury.payToken(weth, beneficiary, amount);
            treasuryWrappedPaid += amount;
        } else {
            treasury.payToken(bloom, beneficiary, amount);
            treasuryRewardsPaid += amount;
        }
    }

    function closeAll() external {
        for (uint256 i; i < actors.length; ++i) {
            withdraw(i, 0, i, false, true);
            claim(i, i);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract NativeCustodyInvariants is FarmFixture {
    NativeCustodyHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        farm = factory.createFarm(BloomFarm.Kind.ETH);
        farm.setDepositsPaused(false);
        vm.stopPrank();
        handler = new NativeCustodyHandler(farm, treasury, owner);

        // Seed real shares and an active epoch so every history can move value.
        for (uint256 i; i < 5; ++i) {
            handler.deposit(i, (i + 1) * 1 ether);
        }
        handler.fund(100 ether);
        handler.schedule(100 ether, 1, true);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.fund.selector;
        selectors[3] = handler.schedule.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.checkpoint.selector;
        selectors[7] = handler.pause.selector;
        selectors[8] = handler.donate.selector;
        selectors[9] = handler.sweep.selector;
        selectors[10] = handler.treasuryPay.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_nativeAndWrappedPrincipalConservation() public view {
        farm.assertSolvent();
        assertEq(farm.accountedAssets() + handler.paidUsers() + handler.feeReceipts(), handler.deposited());
        assertEq(
            weth.balanceOf(address(farm)),
            farm.accountedAssets() + handler.wrappedDonations() - handler.sweptWrapped()
        );
        assertEq(address(farm).balance, handler.nativeDonations() - handler.sweptNative());
        assertEq(weth.totalSupply(), address(weth).balance, "every wrapped payout remains redeemable");
        uint256 sum;
        for (uint256 i; i < 5; ++i) {
            assertEq(farm.sharesOf(handler.actors(i)), handler.modelShares(i));
            sum += handler.modelShares(i);
        }
        assertEq(sum, farm.totalShares());
        if (sum == 0) assertEq(farm.accountedAssets(), 0);
    }

    function invariant_treasuryOnlySpendsActualReceipts() public view {
        assertEq(
            address(treasury).balance + handler.treasuryNativePaid(),
            handler.feeReceipts() + handler.sweptNative()
        );
        assertEq(weth.balanceOf(address(treasury)) + handler.treasuryWrappedPaid(), handler.sweptWrapped());
        assertEq(bloom.balanceOf(address(treasury)) + handler.treasuryRewardsPaid(), handler.sweptRewards());
        assertEq(handler.beneficiary().balance, handler.treasuryNativePaid());
        assertEq(weth.balanceOf(handler.beneficiary()), handler.treasuryWrappedPaid());
        assertEq(bloom.balanceOf(handler.beneficiary()), handler.treasuryRewardsPaid());
        assertEq(treasury.owner(), owner);
        assertEq(farm.sharesOf(address(treasury)), 0);
    }

    function invariant_rewardsAndLiabilitiesRemainSeparatelyBacked() public view {
        assertEq(farm.totalFunded(), handler.funded());
        assertEq(farm.totalClaimed(), handler.claimed());
        assertEq(farm.rewardBacking() + handler.claimed(), handler.funded());
        assertEq(
            bloom.balanceOf(address(farm)) + handler.claimed() + handler.sweptRewards(),
            handler.funded() + handler.rewardDonations()
        );
        uint256 accrued;
        uint256 earned;
        uint256 delivered;
        for (uint256 i; i < 5; ++i) {
            address user = handler.actors(i);
            accrued += farm.accruedRewards(user);
            earned += farm.earned(user);
            delivered += bloom.balanceOf(user);
        }
        assertEq(delivered, handler.claimed());
        assertEq(accrued, farm.totalAccrued());
        assertLe(accrued, farm.rewardLiability());
        assertLe(earned, handler.funded() - handler.claimed());
    }

    function afterInvariant() public {
        handler.closeAll();
        assertEq(farm.totalShares(), 0, "all actors can exit, even while deposits are paused");
        assertEq(farm.accountedAssets(), 0);
        assertEq(farm.rewardLiability(), 0, "all pre-exit whole-unit claims remain payable");
        assertEq(farm.totalAccrued(), 0);
        assertEq(handler.paidUsers() + handler.feeReceipts(), handler.deposited());
        invariant_nativeAndWrappedPrincipalConservation();
        invariant_treasuryOnlySpendsActualReceipts();
        invariant_rewardsAndLiabilitiesRemainSeparatelyBacked();
    }

    function test_handlerExercisesFallbackRewardsAndTreasuryPayouts() public {
        handler.advance(1 days);
        handler.withdraw(0, 0, 2, false, true);
        handler.withdraw(1, 0, 3, false, true);
        handler.claim(0, 0);
        handler.donate(1 ether, 0);
        handler.donate(2 ether, 1);
        handler.donate(3 ether, 2);
        for (uint8 i; i < 3; ++i) {
            handler.sweep(i);
            handler.treasuryPay(1 ether, i, true);
            handler.treasuryPay(1 ether, i, false);
        }
        assertEq(handler.fallbackWithdrawals(), 2);
        assertGt(handler.successfulClaims(), 0);
        afterInvariant();
    }
}
