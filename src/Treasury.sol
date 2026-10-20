// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Holds only funds actually paid to it. It has no authority over any farm.
contract Treasury is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable owner;

    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error NativeTransferFailed();

    event NativeReceived(address indexed sender, uint256 amount);
    event Paid(address indexed asset, address indexed recipient, uint256 amount);

    constructor(address owner_) {
        if (owner_ == address(0)) revert InvalidAddress();
        owner = owner_;
    }

    receive() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }

    /// @dev Treasury control is permanent. There is deliberately no renounce or transfer function.
    function payToken(IERC20 token, address recipient, uint256 amount) external nonReentrant {
        _checkPayment(recipient, amount);
        if (address(token) == address(0)) revert InvalidAddress();
        token.safeTransfer(recipient, amount);
        emit Paid(address(token), recipient, amount);
    }

    function payNative(address payable recipient, uint256 amount) external nonReentrant {
        _checkPayment(recipient, amount);
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit Paid(address(0), recipient, amount);
    }

    function _checkPayment(address recipient, uint256 amount) private view {
        if (msg.sender != owner) revert Unauthorized();
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
    }
}
