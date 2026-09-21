// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    CollateralManager,
    CollateralManager__PoolNotSet,
    CollateralManager__AssetNotEnabled,
    CollateralManager__PrimaryAssetMismatch,
    CollateralManager__AmountOverflow,
    CollateralManager__ZeroUser
} from "../../src/CollateralManager.sol";
import {InvalidAmount} from "../../src/libraries/HelixMath.sol";

contract CollateralManagerHarness is CollateralManager {
    function setPool(address pool, uint8 status) external {
        isPool[pool] = status;
    }

    function setAssetEnabled(address asset, uint8 enabled) external {
        AssetConfig storage cfg = assetConfig[asset];
        cfg.enabled = enabled;
        cfg.decimals = 18;
        cfg.ltvWad = 0.75e18;
        cfg.liquidationThresholdWad = 0.8e18;
    }

    function setMode(address user, uint8 mode) external {
        positions[user].mode = mode;
    }
}

contract AddCollateralTest is Test {
    CollateralManagerHarness internal cm;

    address internal pool = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal usdc;
    address internal wbtc;

    function setUp() public {
        usdc = address(0x1111);
        wbtc = address(0x2222);
        cm = new CollateralManagerHarness();
        cm.setPool(pool, 2);
        cm.setAssetEnabled(usdc, 2);
        cm.setAssetEnabled(wbtc, 2);
    }

    function test_addCollateral_increasesAmount() public {
        vm.prank(pool);
        cm.addCollateral(alice, usdc, 1_000e6);

        assertEq(cm.collateralAmounts(alice, usdc), 1_000e6);
        (, , uint32 lastInteracted, , , , ) = cm.positions(alice);
        assertEq(lastInteracted, block.timestamp);
    }

    function test_addCollateral_accumulates() public {
        vm.startPrank(pool);
        cm.addCollateral(alice, usdc, 100e6);
        cm.addCollateral(alice, usdc, 50e6);
        vm.stopPrank();

        assertEq(cm.collateralAmounts(alice, usdc), 150e6);
    }

    function test_addCollateral_isolatedSetsPrimary() public {
        cm.setMode(alice, 1);

        vm.prank(pool);
        cm.addCollateral(alice, usdc, 100e6);

        assertEq(cm.primaryAsset(alice), usdc);
        assertEq(cm.collateralAmounts(alice, usdc), 100e6);
    }

    function test_addCollateral_isolatedRejectsSecondAsset() public {
        cm.setMode(alice, 1);

        vm.startPrank(pool);
        cm.addCollateral(alice, usdc, 100e6);
        vm.expectRevert(CollateralManager__PrimaryAssetMismatch.selector);
        cm.addCollateral(alice, wbtc, 1e8);
        vm.stopPrank();
    }

    function test_addCollateral_crossAllowsMultipleAssets() public {
        cm.setMode(alice, 2);

        vm.startPrank(pool);
        cm.addCollateral(alice, usdc, 100e6);
        cm.addCollateral(alice, wbtc, 1e8);
        vm.stopPrank();

        assertEq(cm.collateralAmounts(alice, usdc), 100e6);
        assertEq(cm.collateralAmounts(alice, wbtc), 1e8);
        assertEq(cm.primaryAsset(alice), address(0));
    }

    function test_addCollateral_revertsIfNotPool() public {
        vm.expectRevert(CollateralManager__PoolNotSet.selector);
        cm.addCollateral(alice, usdc, 100e6);
    }

    function test_addCollateral_revertsIfAssetDisabled() public {
        cm.setAssetEnabled(usdc, 1);
        vm.prank(pool);
        vm.expectRevert(CollateralManager__AssetNotEnabled.selector);
        cm.addCollateral(alice, usdc, 100e6);
    }

    function test_addCollateral_revertsIfZeroAmount() public {
        vm.prank(pool);
        vm.expectRevert(abi.encodeWithSelector(InvalidAmount.selector, address(cm)));
        cm.addCollateral(alice, usdc, 0);
    }

    function test_addCollateral_revertsIfZeroUser() public {
        vm.prank(pool);
        vm.expectRevert(CollateralManager__ZeroUser.selector);
        cm.addCollateral(address(0), usdc, 100e6);
    }

    function test_addCollateral_revertsOnUint128Overflow() public {
        vm.startPrank(pool);
        cm.addCollateral(alice, usdc, type(uint128).max);
        vm.expectRevert(CollateralManager__AmountOverflow.selector);
        cm.addCollateral(alice, usdc, 1);
        vm.stopPrank();
    }
}
