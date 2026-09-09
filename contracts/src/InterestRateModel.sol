// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";
import {HelixMath, WAD} from "./libraries/HelixMath.sol";

/*******************************************************************************
 *
 * @title: InterestRateModel
 * @author: mumtaz503
 *
 * Kinked utilization curve. Storage holds **annual rates in RAY (APR-RAY)**;
 * `getBorrowRate` expands to per-second RAY via HelixMath.aprRayToPerSecond.
 *
 ******************************************************************************/

/*******************************************************************************
 *
 * PRIVATE ERRORS SPECIFIC TO THIS CONTRACT
 *
 * Only put errors here if there is a reason to not show these errors to the
 * public, such as Migration errors or errors that specifically refer to previous versions.
 *
 ******************************************************************************/

error InterestRateModel__KinkExceededWAD();
error InterestRateModel__RateTooHigh();
error InterestRateModel__Slope2TooLow();
error InterestRateModel__MaxRateTooLow();

/*******************************************************************************
 *
 * PRIVATE INTERFACES SPECIFIC TO THIS CONTRACT
 *
 * Only put interfaces here if there's a reason to not show the interface data,
 * such as Migration-specific functions within other contracts or interfaces
 *
 ******************************************************************************/

/*******************************************************************************
 *
 * PRIVATE CONSTANTS SPECIFIC TO THIS CONTRACT
 *
 * Only put constants here if there's a reason to not show the constant data,
 * such as Migration-specific functions within other contracts or interfaces
 *
 ******************************************************************************/

/*******************************************************************************
 *
 *
 * CONTRACT IMPLEMENTATION
 *
 *
 ******************************************************************************/

contract InterestRateModel is IInterestRateModel {
    /// @param _baseAprRay Annual base rate in RAY (0 = 0% APR)
    /// @param _slope1AprRay Annual slope1 in RAY per 100% util below kink (e.g. 4e25 = 4%)
    /// @param _slope2AprRay Annual slope2 in RAY per 100% util above kink (e.g. 75e25 = 75%)
    /// @param _kink Utilization threshold in WAD (e.g. 0.8e18 = 80%)
    /// @param _maxAprRay Annual borrow-rate cap in RAY (e.g. 300e25 = 300%); must be > 0
    constructor(
        uint256 _baseAprRay,
        uint256 _slope1AprRay,
        uint256 _slope2AprRay,
        uint256 _kink,
        uint256 _maxAprRay
    ) {
        require(_kink <= WAD, InterestRateModel__KinkExceededWAD());
        require(
            _baseAprRay <= type(uint96).max && _slope1AprRay <= type(uint96).max,
            InterestRateModel__RateTooHigh()
        );
        require(
            _slope2AprRay <= type(uint128).max && _maxAprRay <= type(uint128).max,
            InterestRateModel__RateTooHigh()
        );
        require(_slope2AprRay >= _slope1AprRay, InterestRateModel__Slope2TooLow());
        require(
            _maxAprRay > 0 && _maxAprRay >= _baseAprRay,
            InterestRateModel__MaxRateTooLow()
        );

        rateParams = RateParams({
            baseAprRay: uint96(_baseAprRay),
            slope1AprRay: uint96(_slope1AprRay),
            kink: uint64(_kink)
        });
        steepParams = SteepParams({
            slope2AprRay: uint128(_slope2AprRay),
            maxAprRay: uint128(_maxAprRay)
        });
    }

    /***************************************************************************
     *
     *
     * Event Logging
     *
     * TODO: is it possible to put events into the HELIX Library?  This will
     * allow us to publicize all events.  Then again, maybe that's not a good
     * idea for people to use these events...?  Could it mess with the UIs
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * Storage Data Structures
     *
     *
     **************************************************************************/

    // Slot 0
    struct RateParams {
        uint96 baseAprRay;
        uint96 slope1AprRay;
        uint64 kink; // WAD
    }

    // Slot 1: 128 + 128 = 256
    struct SteepParams {
        uint128 slope2AprRay;
        uint128 maxAprRay;
    }

    RateParams public rateParams;
    SteepParams public steepParams;
    /***************************************************************************
     *
     *
     * INTERNAL ACCESS STATE DATA
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * PRIVATE STATE DATA -- Abstract Contracts ONLY!!!
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * FUNCTION MODIFIERS
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * CONTRACT PRIVILEGE FUNCTIONALITY
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * EXTERNAL FUNCTIONALITY for the user's interface
     *
     *
     **************************************************************************/

     // TDOD: Optimizations
    function getBorrowRate(
        uint256 _totalSupplyAssets,
        uint256 _totalBorrowAssets
    ) external view returns (uint256 borrowRatePerSecond) {
        RateParams memory rp = rateParams;
        SteepParams memory sp = steepParams;

        uint256 base = HelixMath.aprRayToPerSecond(rp.baseAprRay);
        uint256 slope1 = HelixMath.aprRayToPerSecond(rp.slope1AprRay);
        uint256 slope2 = HelixMath.aprRayToPerSecond(sp.slope2AprRay);
        uint256 maxRate = HelixMath.aprRayToPerSecond(sp.maxAprRay);
        uint256 kink = rp.kink;

        if (_totalBorrowAssets == 0 || _totalSupplyAssets == 0) {
            return base;
        }

        // Extreme borrow/supply that would overflow WAD scaling -> cap at max rate.
        if (_totalBorrowAssets > type(uint256).max / WAD) {
            return maxRate;
        }

        uint256 utilization = (_totalBorrowAssets * WAD) / _totalSupplyAssets;

        // If util * slope would overflow, rate is far above any real curve — return cap.
        uint256 maxSlope = slope1 > slope2 ? slope1 : slope2;
        if (maxSlope != 0 && utilization > type(uint256).max / maxSlope) {
            return maxRate;
        }

        if (utilization <= kink) {
            borrowRatePerSecond = base + (utilization * slope1) / WAD;
        } else {
            borrowRatePerSecond =
                base +
                (kink * slope1) / WAD +
                ((utilization - kink) * slope2) / WAD;
        }

        if (borrowRatePerSecond > maxRate) {
            return maxRate;
        }
        return borrowRatePerSecond;
    }

    function getUtilization(
        uint256 _totalSupplyAssets,
        uint256 _totalBorrowAssets
    ) external pure returns (uint256 utilizationWad) {
        if (_totalSupplyAssets == 0) {
            return 0;
        }
        utilizationWad = (_totalBorrowAssets * WAD) / _totalSupplyAssets;
    }
    /***************************************************************************
     *
     *
     * PUBLIC AND INTERNAL ACCESS FUNCTIONALITY for the user and this contract
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * INTERNAL FUNCTIONALITY
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     * PRIVATE FUNCTIONALITY -- Abstract Contracts ONLY!!!
     *
     * For abstract contracts, the private functionality will be within their
     * very own section.  If this contract is not abstract, do not implement
     * private functions, and remove this comment block!
     *
     **************************************************************************/
}
