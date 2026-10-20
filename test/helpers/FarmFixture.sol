// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BloomFarm} from "../../src/BloomFarm.sol";
import {FarmFactory} from "../../src/FarmFactory.sol";
import {Treasury} from "../../src/Treasury.sol";
import {SelectiveRoles} from "../../src/SelectiveRoles.sol";
import {MockToken, MockWETH} from "./Mocks.sol";

abstract contract FarmFixture is Test {
    address internal owner = makeAddr("requester");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    MockToken internal simd;
    MockToken internal bloom;
    MockWETH internal weth;
    Treasury internal treasury;
    FarmFactory internal factory;
    BloomFarm internal farm;

    function setUp() public virtual {
        vm.warp(1_000_000);
        simd = new MockToken("sIMD", 18);
        bloom = new MockToken("BLOOM", 18);
        weth = new MockWETH();
        treasury = new Treasury(owner);
        factory = new FarmFactory(owner, address(treasury));
        vm.startPrank(owner);
        factory.configureToken(BloomFarm.Kind.SIMD, address(simd), keccak256("test sIMD evidence"));
        factory.configureToken(BloomFarm.Kind.BLOOM, address(bloom), keccak256("test BLOOM evidence"));
        factory.configureToken(BloomFarm.Kind.ETH, address(weth), keccak256("test WETH evidence"));
        factory.setWhitelisted(address(simd), true);
        factory.setWhitelisted(address(bloom), true);
        factory.setWhitelisted(address(weth), true);
        farm = factory.createFarm(BloomFarm.Kind.SIMD);
        farm.setDepositsPaused(false);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        MockToken underlying = MockToken(address(farm.asset()));
        underlying.mint(who, amount);
        vm.startPrank(who);
        underlying.approve(address(farm), amount);
        shares = farm.deposit(amount, 1);
        vm.stopPrank();
    }

    function _withdraw(address who, uint256 shares) internal returns (uint256 net) {
        vm.prank(who);
        net = farm.withdraw(shares, 0, payable(who), false);
    }

    function _fund(uint256 amount) internal {
        bloom.mint(owner, amount);
        vm.startPrank(owner);
        bloom.approve(address(farm), amount);
        farm.fundRewards(amount);
        vm.stopPrank();
    }

    function _epoch(uint256 amount, uint256 durationDays) internal {
        vm.prank(owner);
        farm.setEpoch(amount, durationDays, BloomFarm.EpochMode.Restart);
    }

    function _assertAccounting() internal view {
        farm.assertSolvent();
        assertEq(farm.rewardBacking() + farm.totalClaimed() + farm.totalRecovered(), farm.totalFunded());
        assertLe(farm.totalAccrued(), farm.rewardLiability());
        assertEq(
            farm.asset().balanceOf(address(farm)),
            farm.accountedAssets() + (farm.asset() == farm.rewardToken() ? farm.rewardBacking() : 0)
        );
        if (farm.totalShares() == 0) assertEq(farm.accountedAssets(), 0);
    }
}
