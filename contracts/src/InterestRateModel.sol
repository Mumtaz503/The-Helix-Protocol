// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";
import {HelixMath, WAD} from "./libraries/HelixMath.sol";

/*******************************************************************************
 *
 * InterestRateModel
 *
 * This contract implements the interest rate model for the protocol's interest accrual.
 * @notice all rates exposed by the IRM are per-second values in RAY
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
    constructor(
        uint256 _baseRatePerSecond,
        uint256 _slope1PerSecond,
        uint256 _slope2PerSecond,
        uint256 _kink,
        uint256 _maxRatePerSecond
    ) {
        require(_kink <= WAD, InterestRateModel__KinkExceededWAD());
        require(
            _baseRatePerSecond <= type(uint64).max &&
                _slope1PerSecond <= type(uint64).max &&
                _slope2PerSecond <= type(uint64).max,
            InterestRateModel__RateTooHigh()
        );
        require(
            _slope2PerSecond >= _slope1PerSecond,
            InterestRateModel__Slope2TooLow()
        );
        require(
            _maxRatePerSecond > 0 && _maxRatePerSecond >= _baseRatePerSecond,
            InterestRateModel__MaxRateTooLow()
        );
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

    //
    struct RateParams {
        // Slot 0: RateParams (256 bits)
        uint64 baseRatePerSecond; // max ~18.4 RAY/sec fits; rates are tiny (~1e18 RAY/sec max sensible)
        uint64 slope1PerSecond;
        uint64 slope2PerSecond;
        uint64 kink; // WAD, 0.8e18 = 8e17 fits in uint64
        // ^--- if kink needs full WAD, then we need to store it as uint128
        // TODO: Check/research if Kink needs full WAD
    }

    uint256 maxRatePerSecond; // Slot 1

    /***************************************************************************
     *
     *
     * Memory Data Structures
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * PUBLIC ACCESS STATE DATA
     *
     *
     **************************************************************************/

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
    function getBorrowRate(
        uint256 totalSupplyAssets,
        uint256 totalBorrowAssets
    ) external view returns (uint256 borrowRatePerSecond) {
        return 0;
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
