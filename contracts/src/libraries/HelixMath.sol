// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RAY, WAD} from "./HelixLib.sol";

/// @title HelixMath
/// @notice RAY-scaled fixed-point math for Helix markets. All divisions truncate (floor)
///         unless noted — rounding favors the protocol per the Helix rounding table.
library HelixMath {
    /// @dev Compound factor in RAY: (1 + ratePerSecond/RAY)^seconds, computed via binary exponentiation.
    ///      `ratePerSecond` is the per-second borrow rate in RAY (e.g. 1e27 = 100%/sec is impossible in practice).
    ///      Returns RAY when `seconds_` or `ratePerSecond` is zero.
    function rayCompound(
        uint256 ratePerSecond,
        uint256 seconds_
    ) internal pure returns (uint256 factorRay) {
        factorRay = RAY;

        // If no time has passed or borrow rate is 0 then return the base precision
        if (seconds_ == 0 || ratePerSecond == 0) return factorRay;

        uint256 base = RAY + ratePerSecond;
        uint256 exp = seconds_;

        while (exp != 0) {
            // if exp is odd include the current base power in the result
            if (exp & 1 != 0) {
                factorRay = (factorRay * base) / RAY;
            }

            // square the base for each iteration
            // -> base^2, base^4, base^8, base^16, ...
            base = (base * base) / RAY;
            unchecked {
                exp >>= 1;
            }
        }
    }

    /// @dev Floor multiply: `a * b / RAY`
    function rayMul(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256 result) {
        result = (a * b) / RAY;
    }

    /// @dev Floor divide: `a * RAY / b`
    function rayDiv(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256 result) {
        result = (a * RAY) / b;
    }

    /// @dev Floor multiply: `a * b / WAD`
    function wadMul(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256 result) {
        result = (a * b) / WAD;
    }

    /// @dev Floor divide: `a * WAD / b`
    function wadDiv(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256 result) {
        result = (a * WAD) / b;
    }
}
