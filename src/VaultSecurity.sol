// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @dev Role-based access control with roles ADMIN_ROLE and EMERGENCY_ROLE.
 *
 * Both roles are managed by themselves to prevent total control of a malicious admin. 
 * _emergencyWallet is controlled by EMERGENCY_ROLE. All other privileged operations are controlled by ADMIN_ROLE.
 */
abstract contract VaultSecurity is AccessControl, Pausable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    address public _emergencyWallet;

    /**
     * @dev Emitted when the emergency wallet is set
     */
    event EmergencyWalletSet(address sender, address newEmergencyWallet);

    constructor() {
        _grantRole(ADMIN_ROLE, msg.sender);
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);

        _grantRole(EMERGENCY_ROLE, msg.sender);
        _setRoleAdmin(EMERGENCY_ROLE, EMERGENCY_ROLE);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function setEmergencyWallet(address emergencyWallet) external onlyRole(EMERGENCY_ROLE) {
        _emergencyWallet = emergencyWallet;
        emit EmergencyWalletSet(msg.sender, emergencyWallet);
    }
}