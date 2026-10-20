// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BloomFarm} from "../../src/BloomFarm.sol";

/// @dev Test fixture only. No token is deployed by the application or deployment script.
contract MockToken is IERC20Metadata {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public fee;
    bool public returnsFalse;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackBlocked;

    constructor(string memory symbol_, uint8 decimals_) {
        name = symbol_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) public {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function setReturnsFalse(bool value) external {
        returnsFalse = value;
    }

    function setCallback(address target, bytes memory data) external {
        callbackTarget = target;
        callbackData = data;
        callbackBlocked = false;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (returnsFalse) return false;
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (returnsFalse) return false;
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        uint256 tax = amount * fee / 10_000;
        balanceOf[to] += amount - tax;
        totalSupply -= tax;
        emit Transfer(from, to, amount - tax);
        if (callbackTarget != address(0)) {
            (bool ok,) = callbackTarget.call(callbackData);
            callbackBlocked = !ok;
        }
    }
}

contract MockWETH is MockToken {
    constructor() MockToken("WETH", 18) {}

    function deposit() public payable {
        mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {
        deposit();
    }
}

contract RejectETH {
    receive() external payable {
        revert("no ETH");
    }
}

contract GasHungryReceiver {
    receive() external payable {
        assembly ("memory-safe") { for {} 1 {} {} }
    }
}

contract ReturnBombReceiver {
    receive() external payable {
        assembly ("memory-safe") { revert(0, 65536) }
    }
}

contract ReentrantReceiver {
    BloomFarm public farm;
    bool public attempted;
    bool public blocked;

    constructor(BloomFarm farm_) {
        farm = farm_;
    }

    receive() external payable {
        attempted = true;
        (bool ok,) = address(farm).call(abi.encodeCall(farm.claim, (address(this))));
        blocked = !ok;
    }
}

/// @dev Historical optional-return ERC20, exercising the actual SafeERC20 library.
contract NoReturnToken {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address to, uint256 amount) external {
        allowance[msg.sender][to] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
