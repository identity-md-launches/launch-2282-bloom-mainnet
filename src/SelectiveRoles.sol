// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice All powers belong to the explicit launch owner. Disabled powers can never be restored.
/// @dev Ownership is immutable: there is no transfer, delegate, grant, upgrade or recovery path.
abstract contract SelectiveRoles {
    address public immutable owner;
    uint256 public activeRoles;

    error Unauthorized();
    error InvalidAddress();
    error RoleDisabled(uint256 role);
    error InvalidRenouncement();
    error EssentialSetupIncomplete();

    event RolesRenounced(uint256 indexed roles);

    constructor(address owner_, uint256 roles_) {
        if (owner_ == address(0)) revert InvalidAddress();
        owner = owner_;
        activeRoles = roles_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyRole(uint256 role) {
        if (msg.sender != owner) revert Unauthorized();
        if (activeRoles & role != role) revert RoleDisabled(role);
        _;
    }

    /// @notice Explicit confirmation bound to this chain, contract and exact set of powers.
    function renouncementHash(uint256 roles) public view returns (bytes32) {
        return keccak256(abi.encode("BLOOM_IRREVERSIBLE_RENOUNCEMENT", block.chainid, address(this), roles));
    }

    function renounceRoles(uint256 roles, bytes32 confirmation) external onlyOwner {
        if (roles == 0 || roles & activeRoles != roles || confirmation != renouncementHash(roles)) {
            revert InvalidRenouncement();
        }
        _checkRenouncement(roles);
        activeRoles &= ~roles;
        emit RolesRenounced(roles);
    }

    function _checkRenouncement(uint256 roles) internal view virtual;
}
