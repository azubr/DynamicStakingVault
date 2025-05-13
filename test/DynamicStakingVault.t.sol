// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {DynamicStakingVaultMock} from "./mocks/DynamicStakingVaultMock.sol";
import {DynamicStakingVault} from "../src/DynamicStakingVault.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IMockERC20, ERC4626Test} from "erc4626-tests/ERC4626.test.sol";

contract DynamicStakingVaultTest is ERC4626Test {
    address private _owner;
    address private _owner2;
    address private _admin;
    address private _other;
    uint private immutable _assetsCount = 100; // produces no reward within 2 weeks
    uint private immutable _assetsCountBig = 500 ether;

    function setUp() public override {
        _owner = vm.addr(1);
        _owner2 = vm.addr(2);
        _admin = vm.addr(3);
        _other = vm.addr(4);

        _underlying_ = address(new ERC20Mock());
        vm.prank(_admin); _vault_ = address(new DynamicStakingVaultMock(_underlying_, 18));
        _delta_ = 0;
        _vaultMayBeEmpty = true;
        _unlimitedAmount = false;

        IMockERC20(_underlying_).mint(_owner, _assetsCount);
        IMockERC20(_underlying_).mint(_owner2, _assetsCountBig * 1000);
        DynamicStakingVaultMock(_underlying_).mint(_vault_, _assetsCountBig * 100);
    }

    //
    // simple deposit/withdraw roundtrips
    //

    /**
     * redeem(deposit(a),wait(10)) == a
     */
    function test_DepositRedeemFull() public {
        _approve(_underlying_, _owner, _vault_, _assetsCount);
        vm.startPrank(_owner);

        uint shares = DynamicStakingVault(_vault_).deposit(_assetsCount, _owner);
        _waitDays(10); // 10 days since deposit: no fees anymore
        uint assetsPreview = DynamicStakingVault(_vault_).previewRedeem(shares);
        uint assets = DynamicStakingVault(_vault_).redeem(shares, _owner, _owner);
        assertEq(assets, assetsPreview, "Redeemed other than previewed");
        assertEq(assets, _assetsCount, "Redeemed other than deposited");
    }

    /**
     * withdraw(maxWithdraw) == deposit(a)
     */
    function test_DepositWithdrawFull() public {
        _approve(_underlying_, _owner, _vault_, _assetsCount);
        vm.startPrank(_owner);

        // _waitDays(1*365); // 1 years since deployment
        uint shares = DynamicStakingVault(_vault_).deposit(_assetsCount, _owner);
        // _waitDays(1); // 1 day since deposit
        uint maxWithdraw = DynamicStakingVault(_vault_).maxWithdraw(_owner);
        uint shares2Preview = DynamicStakingVault(_vault_).previewWithdraw(maxWithdraw);
        uint shares2 = DynamicStakingVault(_vault_).withdraw(maxWithdraw, _owner, _owner);

        assertEq(shares2, shares2Preview, "Withdrawn other than previewed");
        assertEq(shares, shares2, "Withdrawn other than deposited");
    }

    /**
     * withdraw(maxWithdraw/2) == deposit(a)/2
     */
    function test_DepositWithdrawHalf() public {
        _approve(_underlying_, _owner, _vault_, _assetsCount);
        vm.startPrank(_owner);
        
        // _waitDays(1*365); // 1 years since deployment
        uint shares = DynamicStakingVault(_vault_).deposit(_assetsCount, _owner);
        // _waitDays(1); // 1 day since deposit
        uint halfMaxAssets = DynamicStakingVault(_vault_).maxWithdraw(_owner) / 2;
        uint halfSharesPreview = DynamicStakingVault(_vault_).previewWithdraw(halfMaxAssets);
        uint halfShares = DynamicStakingVault(_vault_).withdraw(halfMaxAssets, _owner, _owner);

        assertEq(halfShares, halfSharesPreview, "Withdrawn other than previewed");
        uint sharePrice = shares / _assetsCount;
        assertApproxEqAbs(shares, halfShares * 2, sharePrice, "Withdrawn other than deposited");
    }

    //
    // fees withdrawal
    //

    /**
     * redeem(deposit(a)) == a * 95%
     */
    function test_FeesFull() public {
        _approve(_underlying_, _owner, _vault_, _assetsCount);
        vm.startPrank(_owner);

        uint shares = DynamicStakingVault(_vault_).deposit(_assetsCount, _owner);
        uint assetsPreview = DynamicStakingVault(_vault_).previewRedeem(shares);
        uint assets = DynamicStakingVault(_vault_).redeem(shares, _owner, _owner);
        assertEq(assets, assetsPreview, "Redeemed other than previewed");
        assertEq(assets, _assetsCount * 95 / 100, "Redeemed other than deposited");
    }

    /**
     * redeem(deposit(a/2),deposit(a/2)) == a * 95%
     */
    function test_Fees2() public {
        _approve(_underlying_, _owner, _vault_, _assetsCount);
        vm.startPrank(_owner);

        uint shares1 = DynamicStakingVault(_vault_).deposit(_assetsCount / 2, _owner);
        _waitDays(1);
        uint shares2= DynamicStakingVault(_vault_).deposit(_assetsCount / 2, _owner);
        _waitDays(1);
        uint shares = shares1 + shares2;
        uint assetsPreview = DynamicStakingVault(_vault_).previewRedeem(shares);
        uint assets = DynamicStakingVault(_vault_).redeem(shares, _owner, _owner);
        assertEq(assets, assetsPreview, "Redeemed other than previewed");
        assertEq(assets, _assetsCount * 95 / 100, "Redeemed other than deposited");
    }

    /**
     * redeem(deposit(a/2),wait(5),deposit(a/2),wait(5)) == a/2 * 95% + a/2
     */
    function test_FeesHalf() public {
        _approve(_underlying_, _owner, _vault_, _assetsCount);
        vm.startPrank(_owner);

        uint shares1 = DynamicStakingVault(_vault_).deposit(_assetsCount / 2, _owner);
       _waitDays(5);
        uint shares2 = DynamicStakingVault(_vault_).deposit(_assetsCount / 2, _owner);
        _waitDays(5);
        uint shares = shares1 + shares2;
        uint assetsPreview = DynamicStakingVault(_vault_).previewRedeem(shares);
        uint assets = DynamicStakingVault(_vault_).redeem(shares, _owner, _owner);
        assertEq(assets, assetsPreview, "Redeemed other than previewed");
        assertEq(assets, _assetsCount * 95 / 200 + _assetsCount / 2, "Redeemed other than deposited");
    }

    /**
      * checks that timelocks are correctly transferred along with shares transfer
      */
    function test_FeesTransferRestricted() public {
        _approve(_underlying_, _owner, _vault_, _assetsCount);
        _approve(_underlying_, _owner2, _vault_, _assetsCount);

        vm.prank(_owner); uint shares1 = DynamicStakingVault(_vault_).deposit(_assetsCount / 2, _owner);
        _waitDays(1);
        vm.prank(_owner2); uint shares2 = DynamicStakingVault(_vault_).deposit(_assetsCount / 2, _owner2);
        _waitDays(1);
        vm.prank(_owner); uint shares3 = DynamicStakingVault(_vault_).deposit(_assetsCount / 2, _owner);
        _waitDays(1);
        vm.prank(_owner2); uint shares4 = DynamicStakingVault(_vault_).deposit(_assetsCount / 2, _owner2);
        _waitDays(1);

        vm.prank(_owner); DynamicStakingVault(_vault_).transfer(_owner2, (shares1 / 2) + shares3);

        _waitDays(2); // 6 days since start, no deposit timelocks exceeded
        vm.prank(_owner); uint assetsPreview1 = DynamicStakingVault(_vault_).previewRedeem(shares1 / 2);
        assertEq((_assetsCount / 4) * 95 / 100, assetsPreview1, "Wrong remaining assets fees");
        vm.prank(_owner2); uint assetsPreview2 = DynamicStakingVault(_vault_).previewRedeem((shares1 / 2) + shares2 + shares3 + shares4);
        assertEq((_assetsCount * 7 / 4) * 95 / 100, assetsPreview2, "Wrong transferred assets fees");


        _waitDays(2); // 8 days since start, 1st deposit timelock exceeded for both _owner and _owner2
        vm.prank(_owner); assetsPreview1 = DynamicStakingVault(_vault_).previewRedeem(shares1 / 2);
        assertEq(_assetsCount / 4, assetsPreview1, "Unexpected remaining assets fees");
        uint redeemShares = (shares1 / 2) + shares2 + shares3 + shares4;
        vm.prank(_owner2); assetsPreview2 = DynamicStakingVault(_vault_).previewRedeem(redeemShares);
        assertApproxEqAbs((_assetsCount * 6 / 4) * 95 / 100 + _assetsCount / 4, assetsPreview2, 1, "Unexpected transferred assets fees, day 8");

        _waitDays(1); // 9 days since start, 1st and 2nd deposit timelocks exceeded
        vm.prank(_owner2); assetsPreview2 = DynamicStakingVault(_vault_).previewRedeem(redeemShares);
        assertApproxEqAbs(_assetsCount * 95 / 100 + _assetsCount * 3 / 4, assetsPreview2, 1, "Unexpected transferred assets fees, day 9");


        vm.prank(_owner2); uint assets2 = DynamicStakingVault(_vault_).redeem(redeemShares, _owner2, _owner2);
        assertEq(assets2, assetsPreview2, "Redeemed other than previewed");
    }

    //
    // rewards
    //

    /*
     * redeem(deposit(a),wait(365)) == a * 110%
     */
    function test_RewardsApyMin() public {
        _approve(_underlying_, _owner2, _vault_, _assetsCountBig);
        DynamicStakingVaultMock(_underlying_).mint(_vault_, _assetsCountBig);
        vm.startPrank(_owner2);

        _waitDays(3 * 365); // 3 years since deployment
        uint shares = DynamicStakingVault(_vault_).deposit(_assetsCountBig, _owner2);
        _waitDays(365); // 1 year since deposit
        uint assets = DynamicStakingVault(_vault_).redeem(shares, _owner2, _owner2);
        uint perSecondRewardPrecision = _assetsCountBig / 1000 / 365 days; // 1% of average reward for 1 second

        assertApproxEqAbs(assets, _assetsCountBig * 1100 / 1000, perSecondRewardPrecision, "Redeemed wrong rewards");
    }

    /*
     * checks that APY is increased to 10.1% on 10000 tokens threshold
     */
    function test_RewardsApyStep() public {
        _approve(_underlying_, _owner2, _vault_, _assetsCountBig * 100);
        DynamicStakingVaultMock(_underlying_).mint(_vault_, _assetsCountBig * 100);
        vm.startPrank(_owner2);

        _waitDays(10 * 365); // 10 years since deployment
        uint shares = DynamicStakingVault(_vault_).deposit(_assetsCountBig, _owner2);
        _waitDays(365); // 1 year since deposit
        shares += DynamicStakingVault(_vault_).deposit(_assetsCountBig, _owner2); // update APY
        _waitDays(365); // 1 year more

        uint assets = DynamicStakingVault(_vault_).redeem(shares, _owner2, _owner2);
        uint perSecondRewardPrecision = _assetsCountBig / 1000 / 365 days; // 1% of average reward for 1 second

        uint firstYearAssets = _assetsCountBig * 1100 / 1000;
        uint secondYearAssets = (firstYearAssets + _assetsCountBig) * 1101 / 1000;

        assertApproxEqAbs(assets, secondYearAssets, perSecondRewardPrecision, "Redeemed wrong rewards");
    }

    /*
     * checks that APY is increased to max 20% on 100_0000 tokens threshold
     */
    function test_RewardsApyMax() public {
        _approve(_underlying_, _owner2, _vault_, _assetsCountBig * 1000);
        DynamicStakingVaultMock(_underlying_).mint(_vault_, _assetsCountBig * 1000);
        vm.startPrank(_owner2);

        _waitDays(10 * 365); // 10 years since deployment
        uint shares = DynamicStakingVault(_vault_).deposit(_assetsCountBig, _owner2);
        _waitDays(365); // 1 year since deposit
        shares += DynamicStakingVault(_vault_).deposit(_assetsCountBig * 500, _owner2); // update APY
        _waitDays(365); // 1 year more

        uint assets = DynamicStakingVault(_vault_).redeem(shares, _owner2, _owner2);
        uint perSecondRewardPrecision = _assetsCountBig * 500 / 2000 / 365 days; // 1% of average reward for 1 second

        uint firstYearAssets = _assetsCountBig * 1100 / 1000;
        uint secondYearAssets = (firstYearAssets + _assetsCountBig * 500) * 1200 / 1000;

        assertApproxEqAbs(assets, secondYearAssets, perSecondRewardPrecision, "Redeemed wrong rewards");
    }

    //
    // emergency pause and withdrawal
    //

    function test_Pause() public {
        _approve(_underlying_, _owner, _vault_, _assetsCount);
        vm.prank(_owner); uint shares = DynamicStakingVault(_vault_).deposit(_assetsCount / 2, _owner);

        vm.prank(_admin); DynamicStakingVault(_vault_).pause();

        vm.prank(_owner); DynamicStakingVault(_vault_).previewRedeem(shares);
        
        vm.expectRevert();
        vm.prank(_owner); DynamicStakingVault(_vault_).redeem(shares, _owner, _owner);

        vm.expectRevert();
        vm.prank(_owner); DynamicStakingVault(_vault_).withdraw(1, _owner, _owner);

        vm.expectRevert();
        vm.prank(_owner); DynamicStakingVault(_vault_).deposit(_assetsCount / 2, _owner);

        vm.expectRevert();
        vm.prank(_owner); DynamicStakingVault(_vault_).mint(1, _owner);
    }

    function test_Unpause() public {
        _approve(_underlying_, _owner, _vault_, _assetsCount);
        vm.prank(_owner); uint shares = DynamicStakingVault(_vault_).deposit(_assetsCount, _owner);

        vm.prank(_admin); DynamicStakingVault(_vault_).pause();
        
        vm.expectRevert();
        vm.prank(_owner); DynamicStakingVault(_vault_).redeem(shares, _owner, _owner);

        vm.prank(_admin); DynamicStakingVault(_vault_).unpause();
        vm.prank(_owner); DynamicStakingVault(_vault_).redeem(shares, _owner, _owner);
    }

    function test_EmergencyWithdraw() public {
        _approve(_underlying_, _owner, _vault_, _assetsCount);
        vm.prank(_owner); DynamicStakingVault(_vault_).deposit(_assetsCount, _owner);
        uint vaultBalance = IMockERC20(_underlying_).balanceOf(_vault_);

        bytes32 EMERGENCY_ROLE = DynamicStakingVault(_vault_).EMERGENCY_ROLE();
        vm.prank(_admin); DynamicStakingVault(_vault_).grantRole(EMERGENCY_ROLE, _owner2);
        
        vm.expectRevert();
        vm.prank(_admin);  DynamicStakingVault(_vault_).emergencyWithdraw();

        vm.prank(_admin); DynamicStakingVault(_vault_).pause();

        vm.expectRevert();
        vm.prank(_admin);  DynamicStakingVault(_vault_).emergencyWithdraw();

        vm.prank(_owner2); DynamicStakingVault(_vault_).setEmergencyWallet(_other);
        vm.prank(_admin); DynamicStakingVault(_vault_).emergencyWithdraw();

        uint vaultBalanceNew = IMockERC20(_underlying_).balanceOf(_vault_);
        assertEq(vaultBalanceNew, 0, "Valut is not empty");

        uint emergencyBalance = IMockERC20(_underlying_).balanceOf(_other);
        assertEq(emergencyBalance, vaultBalance, "Tokens not transferred");
    }

    function test_Permissions() public { 
        // move EMERGENCY_ROLE to _owner2
        bytes32 EMERGENCY_ROLE = DynamicStakingVault(_vault_).EMERGENCY_ROLE();
        vm.prank(_admin); DynamicStakingVault(_vault_).grantRole(EMERGENCY_ROLE, _owner2);
        vm.prank(_admin); DynamicStakingVault(_vault_).revokeRole(EMERGENCY_ROLE, _admin);


        // only ADMIN_ROLE can pause
        vm.expectRevert();
        vm.prank(_owner); DynamicStakingVault(_vault_).pause();
        vm.expectRevert();
        vm.prank(_owner2); DynamicStakingVault(_vault_).pause();
        vm.prank(_admin); DynamicStakingVault(_vault_).pause();

        // only EMERGENCY_ROLE can setEmergencyWallet
        vm.expectRevert();
        vm.prank(_owner); DynamicStakingVault(_vault_).setEmergencyWallet(_other);
        vm.expectRevert();
        vm.prank(_admin); DynamicStakingVault(_vault_).setEmergencyWallet(_other);
        vm.prank(_owner2); DynamicStakingVault(_vault_).setEmergencyWallet(_other);


        // only ADMIN_ROLE can emergencyWithdraw
        vm.expectRevert();
        vm.prank(_owner); DynamicStakingVault(_vault_).emergencyWithdraw();
        vm.expectRevert();
        vm.prank(_owner2); DynamicStakingVault(_vault_).emergencyWithdraw();
        vm.prank(_admin); DynamicStakingVault(_vault_).emergencyWithdraw();
        
        // only ADMIN_ROLE can unpause
        vm.expectRevert();
        vm.prank(_owner); DynamicStakingVault(_vault_).unpause();
        vm.expectRevert();
        vm.prank(_owner2); DynamicStakingVault(_vault_).unpause();
        vm.prank(_admin); DynamicStakingVault(_vault_).unpause();
    }

    //
    // openzepplin tests false negatives workarounds
    // note that openzepplin tests may also return false positives
    //

    /**
     * set 'other' account to 'owner' 
     * it makes previewRedeem called from 'owner' account to consider withdrawal fees
     */
    function test_previewRedeem(Init memory init, uint shares) public override {
        init.user[3] = init.user[2]; 
        super.test_previewRedeem(init, shares);
    }

    /**
     * set 'other' account to 'owner' 
     * it makes previewWithdraw called from 'owner' account to consider withdrawal fees
     */
    function test_previewWithdraw(Init memory init, uint shares) public override {
        init.user[3] = init.user[2]; 
        super.test_previewWithdraw(init, shares);
    }

    /** Calls obsolete testFail_redeem and expects revert
     */
    function test_RevertWhen_redeem(Init memory init, uint shares) public {
        vm.expectRevert();
        this.testFail_redeem(init, shares);
    }

    /** Calls obsolete testFail_withdraw and expects revert
     */
    function test_RevertWhen_withdraw(Init memory init, uint shares) public {
        vm.expectRevert();
        this.testFail_withdraw(init, shares);
    }

    //
    // helpers
    //

    function _waitDays(uint n) private {
        vm.warp(block.timestamp + n * 1 days);
    }
}

