// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockInterestRateModel} from "../../src/mocks/MockInterestRateModel.sol";
import {RAY, BASIS_POINTS} from "../../src/libraries/HelixLib.sol";

contract LendingPoolHarness is LendingPool {
    constructor(
        address _underlying,
        address _collateralManager,
        address _oracle,
        address _interestRateModel,
        uint256 _reserveFactor,
        uint256 _dust
    )
        LendingPool(
            _underlying,
            _collateralManager,
            _oracle,
            _interestRateModel,
            _reserveFactor,
            _dust
        )
    {}

    function accrueInterest() external {
        _accrueInterest();
    }

    function seedTotals(uint256 supplyAssets, uint256 borrowAssets) external {
        MarketState memory state = _market;
        state.totalSupplyAssets = uint128(supplyAssets);
        state.totalBorrowAssets = uint128(borrowAssets);
        _market = state;
    }
}

contract AccrueInterestTest is Test {
    LendingPoolHarness internal pool;
    MockInterestRateModel internal irm;

    uint256 internal constant RESERVE_FACTOR = 1000; // 10%
    uint256 internal constant DUST = 1e6;
    // ~5% APR in RAY per second: 5e25 / 365.25 days / 86400 sec
    uint256 internal constant RATE_PER_SECOND = 1585489599188227405;

    function setUp() public {
        irm = new MockInterestRateModel(RATE_PER_SECOND);
        pool = new LendingPoolHarness(
            address(0x1),
            address(0x2),
            address(0x3),
            address(irm),
            RESERVE_FACTOR,
            DUST
        );
    }

    function test_indexesInitializeToRay() public view {
        assertEq(pool.borrowIndex(), RAY);
        assertEq(pool.supplyIndex(), RAY);
        assertEq(pool.lastUpdateTimestamp(), block.timestamp);
    }

    function test_accrueIsIdempotentWithinBlock() public {
        _seedMarket(1_000_000e6, 500_000e6);
        pool.accrueInterest();
        uint256 borrowIndexAfter = pool.borrowIndex();
        uint256 supplyIndexAfter = pool.supplyIndex();
        uint256 reservesAfter = pool.reserves();

        pool.accrueInterest();

        assertEq(pool.borrowIndex(), borrowIndexAfter);
        assertEq(pool.supplyIndex(), supplyIndexAfter);
        assertEq(pool.reserves(), reservesAfter);
    }

    function test_accrueWithZeroBorrowOnlyUpdatesTimestamp() public {
        _seedMarket(1_000_000e6, 0);
        uint256 tsBefore = pool.lastUpdateTimestamp();

        vm.warp(block.timestamp + 30 days);
        pool.accrueInterest();

        assertEq(pool.borrowIndex(), RAY);
        assertEq(pool.supplyIndex(), RAY);
        assertEq(pool.reserves(), 0);
        assertEq(pool.lastUpdateTimestamp(), tsBefore + 30 days);
    }

    function test_accrueIncreasesBorrowIndexAndReserves() public {
        _seedMarket(1_000_000e6, 500_000e6);

        vm.warp(block.timestamp + 1 days);
        pool.accrueInterest();

        assertGt(pool.borrowIndex(), RAY);
        assertGt(pool.supplyIndex(), RAY);
        assertGt(pool.reserves(), 0);
        assertGt(pool.totalBorrowAssets(), 500_000e6);
        assertGt(pool.totalSupplyAssets(), 1_000_000e6);
    }

    function test_accrueReserveFactorSplit() public {
        uint256 supply = 1_000_000e6;
        uint256 borrow = 500_000e6;
        _seedMarket(supply, borrow);

        vm.warp(block.timestamp + 7 days);
        pool.accrueInterest();

        uint256 reserves = pool.reserves();
        assertGt(reserves, 0);

        // Reserves should be roughly reserveFactor fraction of total borrow interest.
        // Exact bound check: reserves < total implied interest
        uint256 indexGrowth = pool.borrowIndex() - RAY;
        uint256 impliedInterest = (borrow * indexGrowth) / RAY;
        assertLe(reserves, impliedInterest);
        assertGe(
            reserves,
            (impliedInterest * RESERVE_FACTOR) / BASIS_POINTS - 1
        );
    }

    function test_accrueCatchUp30Days() public {
        _seedMarket(10_000_000e6, 8_000_000e6);

        vm.warp(block.timestamp + 30 days);
        pool.accrueInterest();

        assertGt(pool.borrowIndex(), RAY);
        assertGt(pool.supplyIndex(), RAY);
    }

    function _seedMarket(uint256 supplyAssets, uint256 borrowAssets) internal {
        pool.seedTotals(supplyAssets, borrowAssets);
    }
}
