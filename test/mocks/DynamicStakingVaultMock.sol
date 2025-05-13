// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {DynamicStakingVault} from "../../src/DynamicStakingVault.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC4626Test} from "erc4626-tests/ERC4626.test.sol";


contract DynamicStakingVaultMock is DynamicStakingVault {
    constructor(address underlying, uint underlyingDecimals) DynamicStakingVault(underlying, underlyingDecimals) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
