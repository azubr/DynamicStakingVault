// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @dev Token timelocks logic
 *
 * Timelocks are identified by unique id.
 * Timelocks are saved in linked lists per account. 
 * Timelocks are sorted by unlock date within each list in descending order.
 * Token transfer also results in timelocks transfer. Sender's timelocks are merged with recepient's timelocks within transfer amount.
 * Timelocks are released on withdraw, but never disposed. Disposal logic could be implemented later in order to receive gas refunds.   
 */
abstract contract VaultTimelock {
    uint64 LOCK_DURATION = 7 days;

    /**
     * @dev Packed data of timelock.
     * Timelock amount is 256 bit and cannot be packed. So it is stored separately. 
     */
    struct Timelock {
        uint64 unlockDate;
        uint64 nextLock;
    }

    uint64 _timelocksCount;
    mapping(address => uint64) private _accountTimelock;
    mapping(uint64 => Timelock) private _timelocks;
    mapping(uint64 => uint) private _timelockAmounts;

    /**
     * @dev Creates new timelock with unique id and adds it to list head of specified account
     */
    function _lock(address account, uint amount) internal returns (uint64 id) {
        id = _timelocksCount + 1;
        _timelocksCount = id;
        _timelocks[id] = Timelock({
            unlockDate: uint64(block.timestamp + LOCK_DURATION),
            nextLock: _accountTimelock[account]
        });
        _timelockAmounts[id] = amount;
        _accountTimelock[account] = id;
    }

    /**
     * @dev Returns total locked amount for specified account within maxAmount limit.
     */
    function lockedAmount(address account, uint maxAmount) public view returns (uint amount) {
        uint64 id = _accountTimelock[account];
        while(id != 0) {
            if (amount >= maxAmount) {
                break;
            }
            Timelock memory timelock = _timelocks[id];
            if (timelock.unlockDate <= block.timestamp) {
                break;
            }
            amount += _timelockAmounts[id];
            id = timelock.nextLock;
        }

        return Math.min(amount, maxAmount);
    }


    /**
     * @dev Releases timelocks for for specified account within amount limit.
     * Reduces amount of first unreleased timelock.
     */
    function _release(address account, uint amount) internal returns (uint remainingAmount) {
        uint64 id = _accountTimelock[account];
        while(id != 0) { 
            Timelock memory timelock = _timelocks[id];
            if (timelock.unlockDate <= block.timestamp) {
                return amount;
            }
            uint currentAmount = _timelockAmounts[id];
            if (amount <= currentAmount) {
                _timelockAmounts[id] = currentAmount - amount; 
                _accountTimelock[account] = id;
                return 0;
            } else {
                amount -= currentAmount; 
            }
            id = timelock.nextLock;
        }
        return amount;
    }

    /**
     * @dev Inserts specified timelock into the list of given account. 
     * Insertion point search starts after afterId timelock and stops when afterTimestamp is reached.
     * afterId == 0 starts search from the list head.
     */
    function _insertLock(address account, uint64 afterId, uint64 afterTimestamp, uint64 insertId) internal { 
        uint64 id;
        if (afterId == 0) {
            id = _accountTimelock[account];
        } else {
            id = _timelocks[afterId].nextLock;
        }
        while(id != 0) { 
            Timelock memory timelock = _timelocks[id];
            if (timelock.unlockDate <= afterTimestamp) {
                break;
            }
            afterId = id;
            id = timelock.nextLock;
        }

        _timelocks[insertId].nextLock = id;
        if (afterId == 0) {
            _accountTimelock[account] = insertId;
        } else {
            _timelocks[afterId].nextLock = insertId;
        }               
    }

    /**
     * @dev Transfers timelocks between specified accounts within amount limit.
     * Reduces amount of first untransferred timelock.
     * Creates new timelock on target accout for the remaining amount.
     */
    function _transferLocks(address fromAccount, address toAccount, uint amount) internal {
        uint64 fromId = _accountTimelock[fromAccount];
        uint64 toId = 0;
        while(fromId != 0) {
            Timelock memory timelock = _timelocks[fromId];
            if (timelock.unlockDate <= block.timestamp) {
                return;
            }
            uint currentAmount = _timelockAmounts[fromId];
            if (amount <= currentAmount) {
                _lock(toAccount, amount);
                _timelockAmounts[fromId] = currentAmount - amount; 
                _accountTimelock[fromAccount] = fromId;
                return;
            } else {
                amount -= currentAmount; 
                _insertLock(toAccount, toId, timelock.unlockDate, fromId);
                toId = fromId;
            }
 
            fromId = timelock.nextLock;
        }
    }
}