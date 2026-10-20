// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Treasury} from "../src/Treasury.sol";
import {FarmFactory} from "../src/FarmFactory.sol";

/// @notice Keyless deployment rehearsal. Production uses the IMD attested deployment service.
/// @dev No environment, broadcast cheatcode, token deployment or post-deployment initialization.
contract DeployBloom {
    address public constant REQUESTER = 0xDEA11b3A70b77134424d436f6eb455f1Abbd4449;

    error WrongChain();
    error WrongOwner();

    event InfrastructurePrepared(address indexed treasury, address indexed factory, address indexed owner);

    function run() external returns (Treasury treasury, FarmFactory factory) {
        return deploy(REQUESTER);
    }

    function deploy(address launchOwner) public returns (Treasury treasury, FarmFactory factory) {
        if (block.chainid != 1) revert WrongChain();
        if (launchOwner != REQUESTER) revert WrongOwner();
        treasury = new Treasury(launchOwner);
        factory = new FarmFactory(launchOwner, address(treasury));
        emit InfrastructurePrepared(address(treasury), address(factory), launchOwner);
    }
}
