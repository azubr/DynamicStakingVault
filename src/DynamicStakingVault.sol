// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ABDKMath64x64} from "lib/abdk-libraries-solidity/ABDKMath64x64.sol";
import {VaultToken} from "./VaultToken.sol";
import {VaultSecurity} from "./VaultSecurity.sol";
import {VaultTimelock} from "./VaultTimelock.sol";

/**
 * @dev DynamicStakingVault implements staking logic with dynamic rewards distribution, withdrawal fees, and emergency safety features.
 *
 * Implementation of the ERC-4626 "Tokenized Vault Standard" as defined in
 * https://eips.ethereum.org/EIPS/eip-4626[ERC-4626].
 * 
 * The Vault allows the minting and burning of "shares" (represented using the ERC-20 inheritance) in exchange for
 * underlying "assets" through standardized {deposit}, {mint}, {redeem} and {burn} workflows. This contract extends
 * the ERC-20 standard.
 *
 * Virtual assets and shares are used to mitigate inflation attack.
 * More details about the inflation attack can be found https://blog.openzeppelin.com/a-novel-defense-against-erc4626-inflation-attacks[here].
 * Vault token decimals are computed by adding the decimal offset on top of the underlying asset's decimals.
 * 
 * Rewards accrue continuously based on staking duration.
 * Rewards distribution follow a dynamic Annual Percentage Yield (APY) structure:
 *  - APY starts at a base rate of 10%.
 *  - APY increases dynamically by 0.1% for every additional 1000 tokens staked globally in the vault, capped at a maximum APY of 20%.
 *  - APY recalculates instantly upon each deposit or withdrawal event.
 * 
 * Implemented a minimum lock-up period of 7 days. Withdrawal within this period triggers a penalty fee of 5%.
 * Withdrawals after the lock-up period incur no penalty.
 *
 * Emergency stop mechanism (pause/unpause) halts deposits and withdrawals when triggered by an admin.
 * Allows emergency withdrawal of tokens by the admin to a predefined secure wallet.
 * Role-based access control with openzeppelin is used: https://docs.openzeppelin.com/contracts/5.x/access-control#role-based-access-control[details]
 */
contract DynamicStakingVault is VaultToken, VaultSecurity, VaultTimelock, IERC4626 {
    using ABDKMath64x64 for int128;

    uint private constant PERCENT_DIVISOR = 1000;

    uint private constant START_APY = 100; // 10%
    uint private constant END_APY = 200; // 20%
    uint private constant STEP_APY = 1; // 0.1%
    uint private constant STEP_ASSETS = 1000;

    uint private constant FEE = 50; // 5%

    uint private constant DECIMAL_OFFSET = 18;

    /**
     * @dev Packed data for rate calculation
     *
     * First second of 10.00% growth is 1,1^(1÷(365 days)) - 1 = 3.022e-9 (fits to 40 bits in fraction part with 4 decimal valuable digits)
     * 200 years of 20% growth is 1,2^200 = 7e+15 (fits to 53 bits of integer part)
     * So 64.64-bit fixed point range is sufficient for 200 years of 10..20% growth with sub-second error 
     */
    struct RateData {
        uint8   apy;
        int128 onePlusRate64; // per-second growth rate, 64.64-bit fixed point 
        uint64  updateTimestamp;
    }

    /**
     * @dev Virtual assets and shares to mitigate inflation attack.
     *
     */
    uint private immutable _supplyOffset;
    address private immutable _asset;
    uint private immutable _stepAssetsWei;
    uint private _totalAssets;
    RateData private _rateData;

    /**
     * @dev Attempted to deposit more assets than the max amount for `receiver`.
     */
    error ExceededTotalAssets(uint assets, uint assetsDiff);

    /**
     * @dev Attempted to withdraw more assets than the max amount for `receiver`.
     */
    error ExceededMaxWithdraw(address owner, uint assets, uint max);

    /**
     * @dev Attempted to redeem more shares than the max amount for `receiver`.
     */
    error ExceededMaxRedeem(address owner, uint shares, uint max);

    constructor(address assetTokenAddress, uint assetDecimals) VaultToken( assetDecimals + DECIMAL_OFFSET) {
        _asset = assetTokenAddress;
        _supplyOffset = 10 ** DECIMAL_OFFSET;
        _rateData = RateData({
            apy: uint8(START_APY),
            onePlusRate64: _apyToOnePlusRate(START_APY),
            updateTimestamp: uint64(block.timestamp)
        });
        _stepAssetsWei = STEP_ASSETS * 10 ** assetDecimals;
    }

    /**
     * @dev Returns the address of the underlying token used for the Vault for accounting, depositing, and withdrawing.
     */
    function asset() external view returns (address assetTokenAddress) {
        return _asset;
    }

    /**
     * @dev Returns the total amount of the underlying asset that is “managed” by Vault.
     */
    function totalAssets() public view returns (uint totalManagedAssets) {
        RateData memory rateData = _rateData;
        
        uint elapsedSeconds = block.timestamp - rateData.updateTimestamp;
        if (elapsedSeconds == 0) {
            return _totalAssets;
        }
        
        return _calculateCompoundInterest(_totalAssets, rateData.onePlusRate64, elapsedSeconds);
    }

    /**
     * @dev Returns the amount of shares that the Vault would exchange for the amount of assets provided, in an ideal
     * scenario where all the conditions are met.
     * Does not consider withdrawal fees.
     */
    function convertToShares(uint assets) external view returns (uint shares) {
        return _convertToShares(assets, totalAssets(), Math.Rounding.Floor);
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     */
    function _convertToShares(uint assets, uint updatedTotalAssets, Math.Rounding rounding) private view returns (uint shares) {
        return Math.mulDiv(assets, totalSupply() + _supplyOffset, updatedTotalAssets + 1, rounding);
    }

    /**
     * @dev Returns the amount of assets that the Vault would exchange for the amount of shares provided, in an ideal
     * scenario where all the conditions are met.
     * Does not consider withdrawal fees.
     */
    function convertToAssets(uint shares) external view returns (uint assets) {
        return _convertToAssets(shares, totalAssets(), Math.Rounding.Floor);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(uint shares, uint updatedTotalAssets, Math.Rounding rounding) private view returns (uint assets) {
        return Math.mulDiv(shares, updatedTotalAssets + 1, totalSupply() + _supplyOffset, rounding);
    }

    /**
     * @dev Returns the maximum amount of the underlying asset that can be deposited into the Vault for the receiver,
     * through a deposit call.
     */
    function maxDeposit(address) pure external returns (uint maxAssets) { 
        return type(uint).max;
    }

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their deposit at the current block, given
     * current on-chain conditions.
     */
    function previewDeposit(uint assets) external view returns (uint shares) {
        return _previewDeposit(assets, totalAssets());
    }

    function _previewDeposit(uint assets, uint updatedTotalAssets) private view returns (uint shares) {
        return _convertToShares(assets, updatedTotalAssets, Math.Rounding.Floor);
    }

    /**
     * @dev Mints shares Vault shares to receiver by depositing exactly amount of underlying tokens.
     * Requires pre-approval of the Vault with the Vault’s underlying asset token.
     * Adds timelock for the deposited amount. Updates APY.
     * Emits the Deposit event. Will revert if the Vault is paused. 
     */
    function deposit(uint assets, address receiver) external returns (uint shares) {
        uint updatedTotalAssets = totalAssets();
        shares = _previewDeposit(assets, updatedTotalAssets);
        _deposit(receiver, assets, shares, updatedTotalAssets);
    }

    /**
     * @dev Returns the maximum amount of the Vault shares that can be minted for the receiver, through a mint call.
     * It's unlimited, so always returns max uint.
     */
    function maxMint(address) external pure returns (uint maxShares) {
        return type(uint256).max;
    }

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their mint at the current block, given
     * current on-chain conditions.
     */
    function previewMint(uint256 shares) external view returns (uint assets) {
        return _previewMint(shares, totalAssets());
    }

    function _previewMint(uint256 shares, uint updatedTotalAssets) private view returns (uint assets) {
        return _convertToAssets(shares, updatedTotalAssets, Math.Rounding.Ceil);
    }

    /**
     * @dev Mints exactly shares Vault shares to receiver by depositing amount of underlying tokens.
     * Requires pre-approval of the Vault with the Vault’s underlying asset token.
     * Adds timelock for the deposited amount. Updates APY.
     * Emits the Deposit event. Will revert if the Vault is paused. 
     */
    function mint(uint shares, address receiver) external returns (uint assets) {
        uint updatedTotalAssets = totalAssets();
        assets = _previewMint(shares, updatedTotalAssets);
        _deposit(receiver, assets, shares, updatedTotalAssets);
    }

    /**
     * @dev Returns the maximum amount of the underlying asset that can be withdrawn from the owner balance in the
     * Vault, through a withdraw call.
     * Deducts applicable withdrawal fees. 
     */
    function maxWithdraw(address owner) external view returns (uint maxAssets) {
        return _maxWithdraw(owner, totalAssets());
    }

    function _maxWithdraw(address owner, uint updatedTotalAssets) private view returns (uint maxAssets) {
        uint balance = balanceOf(owner);
        uint lockedShares = lockedAmount(owner, balance);
        uint lockedAssets = _convertToAssets(lockedShares, updatedTotalAssets, Math.Rounding.Floor);
        uint unlockedShares = balance - lockedShares;
        uint unlockedAssets = _convertToAssets(unlockedShares, updatedTotalAssets, Math.Rounding.Floor);

        return _deductFees(lockedAssets, Math.Rounding.Floor) + unlockedAssets;
    }

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their withdrawal at the current block,
     * given current on-chain conditions.
     * Deducts applicable withdrawal fees. 
     */
    function previewWithdraw(uint assets) external view returns (uint shares) {
        return _previewWithdraw(assets, msg.sender, totalAssets());
    }

    function _previewWithdraw(uint assets, address owner, uint updatedTotalAssets) private view returns (uint shares) {
        uint maxShares = _convertToShares(assets, updatedTotalAssets, Math.Rounding.Ceil);
        maxShares = _addFees(maxShares, Math.Rounding.Ceil);
        uint lockedShares = lockedAmount(owner, maxShares);

        uint lockedAssets = _convertToAssets(lockedShares, updatedTotalAssets, Math.Rounding.Floor);
        uint unlockedAssets = assets - _deductFees(lockedAssets, Math.Rounding.Floor);
        uint unlockedShares = _convertToShares(unlockedAssets, updatedTotalAssets, Math.Rounding.Ceil);
        return unlockedShares + lockedShares;
    }

    /**
     * @dev Burns shares from owner and sends exactly assets of underlying tokens to receiver.
     * Collects applicable withdrawal fees. Updates APY.
     * Emits the Withdraw event. 
     * Will revert if the Vault is paused, owner doesn't have enough shares or sender doesn't have enough approval. 
     */
    function withdraw(uint assets, address receiver, address owner) external returns (uint shares) {
        uint updatedTotalAssets = totalAssets();
        uint maxAssets = _maxWithdraw(owner, updatedTotalAssets);
        if (assets > maxAssets) {
            revert ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        shares = _previewWithdraw(assets, owner, updatedTotalAssets);
        _withdraw(receiver, owner, assets, shares, updatedTotalAssets);
    }

    /**
     * @dev Returns the maximum amount of Vault shares that can be redeemed from the owner balance in the Vault,
     * through a redeem call.
     */
    function maxRedeem(address owner) public view returns (uint maxShares) {
        return balanceOf(owner);
    }

    /**
     * @dev Allows an on-chain or off-chain user to simulate the effects of their redemption at the current block,
     * given current on-chain conditions.
     * Deducts applicable withdrawal fees. 
     */
    function previewRedeem(uint shares) external view returns (uint assets) {
        return _previewRedeem(shares, msg.sender, totalAssets());
    }

    function _previewRedeem(uint shares, address owner, uint updatedTotalAssets) private view returns (uint assets) {
        uint lockedShares = lockedAmount(owner, shares);
        uint lockedAssets = _convertToAssets(lockedShares, updatedTotalAssets, Math.Rounding.Floor);
        uint unlockedShares = shares - lockedShares;
        uint unlockedAssets = _convertToAssets(unlockedShares, updatedTotalAssets, Math.Rounding.Floor);
        return _deductFees(lockedAssets, Math.Rounding.Floor) + unlockedAssets;
    }

    /**
     * @dev Burns exactly shares from owner and sends assets of underlying tokens to receiver.
     * Collects applicable withdrawal fees. Updates APY.
     * Emits the Withdraw event. 
     * Will revert if the Vault is paused, owner doesn't have enough shares or sender doesn't have enough approval. 
     */
    function redeem(uint shares, address receiver, address owner) external returns (uint assets) {
        uint updatedTotalAssets = totalAssets();
        uint maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ExceededMaxRedeem(owner, shares, maxShares);
        }

        assets = _previewRedeem(shares, owner, updatedTotalAssets);
        _withdraw(receiver, owner, assets, shares, updatedTotalAssets);
    }

    /**
     * Performs emergency withdraw to predefined emergency wallet.
     * Can be only performed by admin after pausing the Vault.
     */
    function emergencyWithdraw() external whenPaused onlyRole(ADMIN_ROLE) {
        require(_emergencyWallet != address(0), "Emergency wallet is not specified");
        uint vaultBalance = IERC20(_asset).balanceOf(address(this));
        SafeERC20.safeTransfer(IERC20(_asset), _emergencyWallet, vaultBalance);
        _totalAssets = 0;
    }

    /**
     * @dev Converts Annual Percentage Yield (APY) of compound interest to per-second growth rate as
     * apy = (1 + rate) ^ seconds - 1
     * 1 + apy = (1 + rate) ^ seconds
     * (1 + apy) ^ (1 / seconds) = 1 + rate
     * 1 + rate = (1 + apy) ^ (1 / seconds) 
     * 1 + rate = 2 ^ (log2(1 + apy) / seconds)
     * exp/log approach is used because ABDKMath does not provide pow() method accepting fractional base and exponent.
     */
    function _apyToOnePlusRate(uint apy) private pure returns (int128 onePlusRate64) {
        int128 one64 = ABDKMath64x64.fromUInt(1);
        int128 apy64 = ABDKMath64x64.divu(apy, PERCENT_DIVISOR);
        int128 seconds64 = ABDKMath64x64.fromUInt(365 days);
        int128 exponent64 = one64.add(apy64).log_2().div(seconds64);
        return exponent64.exp_2();
    }

    /**
     * @dev Computes compound interest with formula
     * amount * (1 + rate) ^ seconds
     * where 1 + rate is precomputed in onePlusRate64
     */
    function _calculateCompoundInterest(uint amount, int128 onePlusRate64, uint periods) private pure returns (uint amountWithInterest) {
        int128 compoundInterest64 = onePlusRate64.pow(periods);
        return compoundInterest64.mulu(amount);
    } 

    /**
     * @dev Substracts withdrawal fees from given amount
     */
    function _deductFees(uint amount, Math.Rounding rounding) private pure returns (uint amountWithoutFees) {
        return Math.mulDiv(amount, PERCENT_DIVISOR - FEE, PERCENT_DIVISOR, rounding);
    }

    /**
     * @dev Add withdrawal fees to given amount
     */
    function _addFees(uint amount, Math.Rounding rounding) private pure returns (uint amountWithFees) {
        return Math.mulDiv(amount, PERCENT_DIVISOR, PERCENT_DIVISOR - FEE, rounding);
    }

    /**
     * @dev updates _totalAssets stored value using current APY
     * and then updates APY value based on new totalAssets
     */
    function _updateRateData(uint totalAssetsDiff, bool substract, uint updatedTotalAssets) private whenNotPaused { 
        RateData memory rateData = _rateData;
        uint elapsedSeconds = block.timestamp - rateData.updateTimestamp;
        if (elapsedSeconds == 0) {
            // there might be some reentrancy, so updatedTotalAssets is not valid anymore
            // however stored _totalAssets value is up to date and requires no additional calculation
            updatedTotalAssets = _totalAssets;
        } else {
            // at this line elapsedSeconds > 0, it means that there was no reentrancy 
            // and previous updatedTotalAssets value can be used safely
        }

        if (substract) {
            if (totalAssetsDiff > updatedTotalAssets) {
                revert ExceededTotalAssets(updatedTotalAssets, totalAssetsDiff);
            }
            updatedTotalAssets -= totalAssetsDiff;
        } else {
            updatedTotalAssets += totalAssetsDiff;
        }
        _totalAssets = updatedTotalAssets;

        uint apySteps = updatedTotalAssets / _stepAssetsWei;
        uint apy = Math.min(START_APY + apySteps * STEP_APY, END_APY);

        if (elapsedSeconds > 0 || apy != rateData.apy) {
            rateData.apy = uint8(apy);
            rateData.onePlusRate64 = _apyToOnePlusRate(rateData.apy);
            rateData.updateTimestamp = uint64(block.timestamp);
            _rateData = rateData;
        }
    }

    /**
     * @dev Deposit/mint common workflow. Also updates _totalAssets and APY.
     */
    function _deposit(address receiver, uint assets, uint shares, uint updatedTotalAssets) private {
        // If asset() is ERC-777, `transferFrom` can trigger a reentrancy BEFORE the transfer happens through the
        // `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
        // assets are transferred and before the shares are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
        SafeERC20.safeTransferFrom(IERC20(_asset), msg.sender, address(this), assets);
        _mint(receiver, shares);
        _updateRateData(assets, false, updatedTotalAssets);


        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @dev Withdraw/redeem common workflow. Also updates _totalAssets and APY.
     */
    function _withdraw(address receiver, address owner, uint assets, uint shares, uint updatedTotalAssets) private {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // If asset() is ERC-777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.
        _burn(owner, shares);
        _updateRateData(assets, true, updatedTotalAssets);
        SafeERC20.safeTransfer(IERC20(_asset), receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @dev See {ERC20-_update}.
     *
     * Also updates token timelocks for source and target accounts
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);
        if (from == address(0)) {
            _lock(to, value);
        } else  if (to == address(0)) {
            _release(from, value);
        } else {
            _transferLocks(from, to, value);
        }
    }
}