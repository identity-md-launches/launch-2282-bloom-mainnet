// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SelectiveRoles} from "./SelectiveRoles.sol";
import {Treasury} from "./Treasury.sol";
import {BloomFarm} from "./BloomFarm.sol";

/// @notice Deploys standalone isolated farms; never deploys a token or a liquidity pool.
contract FarmFactory is SelectiveRoles, ReentrancyGuard {
    uint256 public constant CONFIG_ROLE = 1;
    uint256 public constant CREATE_ROLE = 2;
    address public immutable treasury;

    address public bloom;
    address public simd;
    address public weth;
    mapping(address => bool) public whitelisted;
    mapping(address => uint8) public tokenDecimals;
    mapping(address => bytes32) public verificationEvidence;
    address[] public farms;
    mapping(address => bool) public isFarm;

    error AlreadyConfigured();
    error NotConfigured();
    error InvalidToken();
    error NotWhitelisted();
    error InvalidTreasury();

    event TokenConfigured(
        BloomFarm.Kind indexed kind, address indexed token, uint8 decimals, bytes32 evidence
    );
    event WhitelistChanged(address indexed asset, bool allowed);
    event FarmCreated(
        uint256 indexed index, address indexed farm, BloomFarm.Kind indexed kind, address asset
    );

    constructor(address owner_, address treasury_) SelectiveRoles(owner_, CONFIG_ROLE | CREATE_ROLE) {
        if (treasury_ == address(0)) revert InvalidAddress();
        treasury = treasury_;
    }

    /// @notice One-time registration of a verified official token. Evidence is an off-chain review hash.
    /// @dev Token identity cannot be proven by a symbol. The owner must verify source and provenance.
    function configureToken(BloomFarm.Kind kind, address token, bytes32 evidence)
        external
        onlyRole(CONFIG_ROLE)
        nonReentrant
    {
        _validateTreasury();
        if (token == address(0) || token.code.length == 0 || evidence == bytes32(0)) revert InvalidToken();
        if (token == bloom || token == simd || token == weth) revert InvalidToken();
        uint8 tokenDecimals_ = IERC20Metadata(token).decimals();
        if (tokenDecimals_ > 18 || (kind == BloomFarm.Kind.ETH && tokenDecimals_ != 18)) {
            revert InvalidToken();
        }
        if (kind == BloomFarm.Kind.BLOOM) {
            if (bloom != address(0)) revert AlreadyConfigured();
            bloom = token;
        } else if (kind == BloomFarm.Kind.SIMD) {
            if (simd != address(0)) revert AlreadyConfigured();
            simd = token;
        } else {
            if (weth != address(0)) revert AlreadyConfigured();
            weth = token;
        }
        tokenDecimals[token] = tokenDecimals_;
        verificationEvidence[token] = evidence;
        emit TokenConfigured(kind, token, tokenDecimals_, evidence);
    }

    function setWhitelisted(address token, bool allowed) external onlyRole(CONFIG_ROLE) {
        if (token == address(0) || (token != bloom && token != simd && token != weth)) {
            revert NotConfigured();
        }
        whitelisted[token] = allowed;
        emit WhitelistChanged(token, allowed);
    }

    function createFarm(BloomFarm.Kind kind)
        external
        onlyRole(CREATE_ROLE)
        nonReentrant
        returns (BloomFarm farm)
    {
        _validateTreasury();
        if (bloom == address(0)) revert NotConfigured();
        address underlying = kind == BloomFarm.Kind.SIMD ? simd : kind == BloomFarm.Kind.ETH ? weth : bloom;
        if (underlying == address(0)) revert NotConfigured();
        if (!whitelisted[underlying] || !whitelisted[bloom]) revert NotWhitelisted();
        if (underlying.code.length == 0 || bloom.code.length == 0) revert InvalidToken();
        farm = new BloomFarm(owner, treasury, underlying, bloom, tokenDecimals[underlying], kind);
        isFarm[address(farm)] = true;
        farms.push(address(farm));
        emit FarmCreated(farms.length - 1, address(farm), kind, underlying);
    }

    function farmCount() external view returns (uint256) {
        return farms.length;
    }

    function _validateTreasury() private view {
        if (treasury.code.length == 0 || Treasury(payable(treasury)).owner() != owner) {
            revert InvalidTreasury();
        }
    }

    function _checkRenouncement(uint256 roles) internal view override {
        if (roles & CONFIG_ROLE != 0) {
            if (
                bloom == address(0) || simd == address(0) || weth == address(0) || !whitelisted[bloom]
                    || !whitelisted[simd] || !whitelisted[weth]
            ) revert EssentialSetupIncomplete();
        }
        if (roles & CREATE_ROLE != 0 && farms.length == 0) revert EssentialSetupIncomplete();
    }
}
