// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SelectiveRoles} from "./SelectiveRoles.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";

/// @notice One isolated farm, with non-transferable shares and separately funded BLOOM rewards.
/// @dev Supports exact-transfer, non-rebasing tokens only. Native ETH is held as WETH9.
contract BloomFarm is SelectiveRoles, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Kind {
        SIMD,
        ETH,
        BLOOM
    }
    enum EpochMode {
        Continue,
        Restart
    }

    uint256 public constant FUND_ROLE = 1;
    uint256 public constant EMISSION_ROLE = 2;
    uint256 public constant DEPOSIT_ROLE = 4;
    uint256 public constant PRECISION = 1e36;
    uint256 public constant MAX_BALANCE = type(uint128).max;
    uint256 public constant MAX_DURATION_DAYS = 3650;
    uint256 public constant ETH_SEND_GAS = 50_000;
    uint8 public constant decimals = 18;
    uint256 public constant WITHDRAWAL_FEE_BPS = 1500;
    uint256 public constant TREASURY_FEE_BPS = 100;

    IERC20 public immutable asset;
    IERC20 public immutable rewardToken;
    address public immutable treasury;
    Kind public immutable kind;
    uint8 public immutable assetDecimals;
    uint256 public immutable initialShareScale;

    bool public depositsPaused = true;
    bool public hasActivated;
    bool public hasScheduled;
    uint256 public totalShares;
    uint256 public accountedAssets;
    mapping(address => uint256) public sharesOf;

    uint256 public rewardReserve;
    /// @notice Conservative liability: includes rewards earned but not yet checkpointed and rounding dust.
    uint256 public rewardLiability;
    /// @notice Exact sum of checkpointed, unclaimed whole-token-unit rewards.
    uint256 public totalAccrued;
    uint256 public totalFunded;
    uint256 public totalClaimed;
    uint256 public rewardIndex;
    uint256 public indexRemainder;
    mapping(address => uint256) public paidIndex;
    mapping(address => uint256) public accruedRewards;
    mapping(address => uint256) public rewardFraction;

    uint256 public epochId;
    uint256 public epochStartedAt;
    /// @notice Start of the current rate segment, which changes on Continue and Restart.
    uint256 public epochStart;
    uint256 public epochEnd;
    uint256 public epochBudget;
    uint256 public epochReleased;

    error InvalidAmount();
    error UnsupportedAsset();
    error DepositsPaused();
    error Slippage();
    error ZeroShares();
    error ZeroAssets();
    error InsufficientShares();
    error BalanceLimit();
    error Insolvent();
    error InexactTransfer();
    error InvalidDuration();
    error NoActiveEpoch();
    error InsufficientReserve();
    error UnexpectedETH();
    error NoSurplus();

    event Deposited(address indexed account, uint256 assets, uint256 shares);
    event Withdrawn(
        address indexed account,
        address indexed recipient,
        uint256 shares,
        uint256 gross,
        uint256 net,
        uint256 retainedFee,
        uint256 treasuryFee
    );
    event Claimed(address indexed account, address indexed recipient, uint256 amount);
    event DepositsPauseChanged(bool paused);
    event RewardsFunded(uint256 amount);
    event EpochSet(
        EpochMode indexed mode, uint256 newlyAllocated, uint256 budget, uint256 start, uint256 end
    );
    event RewardsCheckpointed(uint256 emitted, uint256 index, bool empty);
    event EmptyRewardDustRecycled(uint256 amount);
    event SurplusSwept(address indexed token, uint256 amount);
    event WETHFallback(address indexed recipient, uint256 amount);

    constructor(
        address owner_,
        address treasury_,
        address asset_,
        address rewardToken_,
        uint8 assetDecimals_,
        Kind kind_
    ) SelectiveRoles(owner_, FUND_ROLE | EMISSION_ROLE | DEPOSIT_ROLE) {
        if (treasury_ == address(0) || asset_ == address(0) || rewardToken_ == address(0)) {
            revert InvalidAddress();
        }
        if (assetDecimals_ > 18 || (kind_ == Kind.ETH && assetDecimals_ != 18)) revert UnsupportedAsset();
        if ((kind_ == Kind.BLOOM) != (asset_ == rewardToken_)) revert UnsupportedAsset();
        treasury = treasury_;
        asset = IERC20(asset_);
        rewardToken = IERC20(rewardToken_);
        assetDecimals = assetDecimals_;
        initialShareScale = 10 ** (18 - assetDecimals_);
        kind = kind_;
    }

    receive() external payable {
        if (kind != Kind.ETH || msg.sender != address(asset)) revert UnexpectedETH();
    }

    function shareSymbol() external view returns (string memory) {
        if (kind == Kind.SIMD) return "stakedSIMD";
        if (kind == Kind.ETH) return "stakedETH";
        return "stakedBLOOM";
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        if (totalShares == 0) return Math.mulDiv(assets, initialShareScale, 1);
        return Math.mulDiv(assets, totalShares, accountedAssets);
    }

    function previewWithdraw(uint256 shares)
        public
        view
        returns (uint256 gross, uint256 net, uint256 retainedFee, uint256 treasuryFee)
    {
        if (shares == 0 || shares > totalShares) return (0, 0, 0, 0);
        gross = Math.mulDiv(shares, accountedAssets, totalShares);
        // User payout rounds DOWN; total fee and Treasury's minimum 1% round UP.
        uint256 fee = Math.mulDiv(gross, WITHDRAWAL_FEE_BPS, 10_000, Math.Rounding.Ceil);
        net = gross - fee;
        treasuryFee =
            shares == totalShares ? fee : Math.mulDiv(gross, TREASURY_FEE_BPS, 10_000, Math.Rounding.Ceil);
        retainedFee = fee - treasuryFee;
    }

    function deposit(uint256 assets, uint256 minSharesOut) external nonReentrant returns (uint256 shares) {
        if (kind == Kind.ETH) revert UnsupportedAsset();
        shares = _prepareDeposit(assets, minSharesOut);
        _pullExact(asset, msg.sender, assets);
        _assertSolvent();
        emit Deposited(msg.sender, assets, shares);
    }

    function depositETH(uint256 minSharesOut) external payable nonReentrant returns (uint256 shares) {
        if (kind != Kind.ETH) revert UnsupportedAsset();
        shares = _prepareDeposit(msg.value, minSharesOut);
        uint256 beforeBalance = asset.balanceOf(address(this));
        IWETH9(address(asset)).deposit{value: msg.value}();
        if (asset.balanceOf(address(this)) != beforeBalance + msg.value) revert InexactTransfer();
        _assertSolvent();
        emit Deposited(msg.sender, msg.value, shares);
    }

    function _prepareDeposit(uint256 assets, uint256 minSharesOut) private returns (uint256 shares) {
        if (depositsPaused) revert DepositsPaused();
        if (assets == 0 || minSharesOut == 0) revert InvalidAmount();
        _assertSolvent();
        _checkpoint(msg.sender);
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();
        if (shares < minSharesOut) revert Slippage();
        if (assets > MAX_BALANCE - accountedAssets || shares > MAX_BALANCE - totalShares) {
            revert BalanceLimit();
        }
        accountedAssets += assets;
        totalShares += shares;
        sharesOf[msg.sender] += shares;
        // Fractional global index dust cannot be assigned to a different shareholder set.
        indexRemainder = 0;
    }

    /// @param asWETH For ETH farms, bypass native delivery and receive WETH directly.
    /// @dev A failed bounded ETH call automatically falls back to WETH for this recipient.
    function withdraw(uint256 shares, uint256 minAssetsOut, address payable recipient, bool asWETH)
        external
        nonReentrant
        returns (uint256 net)
    {
        _checkRecipient(recipient);
        if (shares == 0 || shares > sharesOf[msg.sender]) revert InsufficientShares();
        _assertSolvent();
        _checkpoint(msg.sender);
        (uint256 gross, uint256 payout, uint256 retained, uint256 treasuryFee) = previewWithdraw(shares);
        if (gross == 0) revert ZeroAssets();
        if (payout < minAssetsOut) revert Slippage();
        net = payout;
        // Burn first, then redistribute the retained 14% to the remaining shares.
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        accountedAssets = accountedAssets - gross + retained;
        indexRemainder = 0;
        if (sharesOf[msg.sender] == 0) rewardFraction[msg.sender] = 0;
        if (totalShares == 0) _recycleEmptyRewardDust();
        _payUnderlying(payable(treasury), treasuryFee, false);
        _payUnderlying(recipient, net, asWETH);
        _assertSolvent();
        emit Withdrawn(msg.sender, recipient, shares, gross, net, retained, treasuryFee);
    }

    /// @notice Rewards are immediately claimable, including after all shares have been withdrawn.
    function claim(address recipient) external nonReentrant returns (uint256 amount) {
        _checkRecipient(recipient);
        _assertSolvent();
        _checkpoint(msg.sender);
        amount = accruedRewards[msg.sender];
        if (amount != 0) {
            accruedRewards[msg.sender] = 0;
            totalAccrued -= amount;
            rewardLiability -= amount;
            totalClaimed += amount;
            _sendExact(rewardToken, recipient, amount);
        }
        _assertSolvent();
        emit Claimed(msg.sender, recipient, amount);
    }

    /// @notice Funding adds to reserve only. It does not start or change emissions.
    function fundRewards(uint256 amount) external onlyRole(FUND_ROLE) nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (amount > MAX_BALANCE - totalFunded) revert BalanceLimit();
        _assertSolvent();
        _updateGlobal();
        totalFunded += amount;
        rewardReserve += amount;
        _pullExact(rewardToken, msg.sender, amount);
        _assertSolvent();
        emit RewardsFunded(amount);
    }

    /// @param newlyAllocated Additional reserve to allocate, excluding the old epoch's unvested rewards.
    /// @param durationDays Restart: length from now. Continue: must be zero; preserves the existing end.
    function setEpoch(uint256 newlyAllocated, uint256 durationDays, EpochMode mode)
        external
        onlyRole(EMISSION_ROLE)
        nonReentrant
    {
        _setEpoch(newlyAllocated, durationDays, mode);
    }

    /// @notice Increase emission rate by allocating additional reserve to the existing remaining time.
    function boost(uint256 additionalRewards) external onlyRole(EMISSION_ROLE) nonReentrant {
        if (additionalRewards == 0) revert InvalidAmount();
        _setEpoch(additionalRewards, 0, EpochMode.Continue);
    }

    function _setEpoch(uint256 newlyAllocated, uint256 durationDays, EpochMode mode) private {
        _assertSolvent();
        _updateGlobal();
        uint256 end;
        if (mode == EpochMode.Continue) {
            if (epochEnd <= block.timestamp) revert NoActiveEpoch();
            if (durationDays != 0) revert InvalidDuration();
            end = epochEnd;
        } else {
            if (durationDays == 0 || durationDays > MAX_DURATION_DAYS) revert InvalidDuration();
            end = block.timestamp + durationDays * 1 days;
        }
        if (newlyAllocated > rewardReserve) revert InsufficientReserve();
        uint256 budget = scheduledRewards() + newlyAllocated;
        if (budget == 0) revert InvalidAmount();
        rewardReserve -= newlyAllocated;
        if (mode == EpochMode.Restart) {
            ++epochId;
            epochStartedAt = block.timestamp;
        }
        epochStart = block.timestamp;
        epochEnd = end;
        epochBudget = budget;
        epochReleased = 0;
        hasScheduled = true;
        emit EpochSet(mode, newlyAllocated, budget, block.timestamp, end);
    }

    function setDepositsPaused(bool paused) external onlyRole(DEPOSIT_ROLE) nonReentrant {
        // Live validation happens on activation, never in the deployment constructor.
        if (!paused) {
            if (
                address(asset).code.length == 0 || address(rewardToken).code.length == 0
                    || treasury.code.length == 0
            ) {
                revert UnsupportedAsset();
            }
            _assertSolvent();
            hasActivated = true;
        }
        depositsPaused = paused;
        emit DepositsPauseChanged(paused);
    }

    function scheduledRewards() public view returns (uint256) {
        return epochBudget - epochReleased;
    }

    /// @notice All BLOOM owed to reserves, an epoch or users; unchanged by checkpointing.
    function rewardBacking() public view returns (uint256) {
        return rewardReserve + scheduledRewards() + rewardLiability;
    }

    function earned(address account) external view returns (uint256) {
        uint256 index = rewardIndex;
        uint256 emitted = _vested() - epochReleased;
        if (emitted != 0 && totalShares != 0) {
            (uint256 increase,) = _indexIncrease(emitted);
            index += increase;
        }
        uint256 delta = index - paidIndex[account];
        uint256 whole = Math.mulDiv(sharesOf[account], delta, PRECISION);
        uint256 fraction = mulmod(sharesOf[account], delta, PRECISION) + rewardFraction[account];
        return accruedRewards[account] + whole + fraction / PRECISION;
    }

    /// @notice Anyone can crystallize emissions; there is no external keeper requirement.
    function checkpoint() external nonReentrant {
        _updateGlobal();
    }

    function _vested() private view returns (uint256) {
        if (epochBudget == 0 || block.timestamp <= epochStart) return 0;
        if (block.timestamp >= epochEnd) return epochBudget;
        return Math.mulDiv(epochBudget, block.timestamp - epochStart, epochEnd - epochStart);
    }

    function _indexIncrease(uint256 emitted) private view returns (uint256 increase, uint256 remainder) {
        increase = Math.mulDiv(emitted, PRECISION, totalShares);
        remainder = mulmod(emitted, PRECISION, totalShares) + indexRemainder;
        increase += remainder / totalShares;
        remainder %= totalShares;
    }

    function _updateGlobal() private {
        uint256 vested = _vested();
        uint256 emitted = vested - epochReleased;
        if (emitted == 0) return;
        epochReleased = vested;
        if (totalShares == 0) {
            rewardReserve += emitted;
        } else {
            (uint256 increase, uint256 remainder) = _indexIncrease(emitted);
            rewardIndex += increase;
            indexRemainder = remainder;
            rewardLiability += emitted;
        }
        emit RewardsCheckpointed(emitted, rewardIndex, totalShares == 0);
    }

    function _checkpoint(address account) private {
        _updateGlobal();
        uint256 delta = rewardIndex - paidIndex[account];
        uint256 whole = Math.mulDiv(sharesOf[account], delta, PRECISION);
        uint256 fraction = mulmod(sharesOf[account], delta, PRECISION) + rewardFraction[account];
        whole += fraction / PRECISION;
        rewardFraction[account] = fraction % PRECISION;
        paidIndex[account] = rewardIndex;
        accruedRewards[account] += whole;
        totalAccrued += whole;
    }

    function _recycleEmptyRewardDust() private {
        // Every exiting position was settled before its shares were burned.
        // Accrued whole-unit claims survive; fractions of an indivisible token unit are forfeited at exit.
        uint256 dust = rewardLiability - totalAccrued;
        rewardLiability = totalAccrued;
        rewardReserve += dust;
        emit EmptyRewardDustRecycled(dust);
    }

    /// @notice Donations are never shares or rewards. Anyone may send only excess to the Treasury.
    function sweepSurplus(IERC20 token) external nonReentrant returns (uint256 amount) {
        _assertSolvent();
        uint256 reserved;
        if (token == asset) reserved += accountedAssets;
        if (token == rewardToken) reserved += rewardBacking();
        uint256 balance = token.balanceOf(address(this));
        if (balance <= reserved) revert NoSurplus();
        amount = balance - reserved;
        _sendExact(token, treasury, amount);
        _assertSolvent();
        emit SurplusSwept(address(token), amount);
    }

    /// @notice Forced ETH is isolated from WETH share backing.
    function sweepNativeDonations() external nonReentrant {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NoSurplus();
        (bool ok,) = payable(treasury).call{value: amount, gas: ETH_SEND_GAS}("");
        if (!ok) revert UnexpectedETH();
        emit SurplusSwept(address(0), amount);
    }

    function assertSolvent() external view {
        _assertSolvent();
    }

    function _assertSolvent() private view {
        uint256 rewards = rewardBacking();
        if (asset == rewardToken) {
            if (asset.balanceOf(address(this)) < accountedAssets + rewards) revert Insolvent();
        } else if (
            asset.balanceOf(address(this)) < accountedAssets || rewardToken.balanceOf(address(this)) < rewards
        ) {
            revert Insolvent();
        }
    }

    function _payUnderlying(address payable recipient, uint256 amount, bool asWETH) private {
        if (amount == 0) return;
        if (kind != Kind.ETH || asWETH) {
            _sendExact(asset, recipient, amount);
            return;
        }
        uint256 beforeBalance = asset.balanceOf(address(this));
        uint256 beforeETH = address(this).balance;
        IWETH9(address(asset)).withdraw(amount);
        if (
            asset.balanceOf(address(this)) != beforeBalance - amount
                || address(this).balance != beforeETH + amount
        ) {
            revert InexactTransfer();
        }
        (bool ok,) = recipient.call{value: amount, gas: ETH_SEND_GAS}("");
        if (!ok) {
            IWETH9(address(asset)).deposit{value: amount}();
            if (asset.balanceOf(address(this)) != beforeBalance) revert InexactTransfer();
            _sendExact(asset, recipient, amount);
            emit WETHFallback(recipient, amount);
        }
    }

    function _pullExact(IERC20 token, address from, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) revert InexactTransfer();
    }

    function _sendExact(IERC20 token, address recipient, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 beforeRecipient = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        if (
            token.balanceOf(address(this)) != beforeBalance - amount
                || token.balanceOf(recipient) != beforeRecipient + amount
        ) revert InexactTransfer();
    }

    function _checkRecipient(address recipient) private view {
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
    }

    function _checkRenouncement(uint256 roles) internal view override {
        if (!hasActivated) revert EssentialSetupIncomplete();
        if (roles & (FUND_ROLE | EMISSION_ROLE) != 0 && !hasScheduled) revert EssentialSetupIncomplete();
        if (roles & DEPOSIT_ROLE != 0 && depositsPaused) revert EssentialSetupIncomplete();
    }
}
