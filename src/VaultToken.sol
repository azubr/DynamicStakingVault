// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev Vault shares represented as ERC20 token
 */
abstract contract VaultToken is ERC20Pausable {
    uint private immutable _decimals;

    constructor(uint decimalsCount) ERC20('Dynamic Staking Vault', 'DSV')  {
        _decimals = decimalsCount;
    }

    /**
     * @dev Override of default decimals
     *
     * See {IERC20Metadata-decimals}.
     */
    function decimals() public view virtual override(ERC20) returns (uint8) {
        return uint8(_decimals);
    }
}