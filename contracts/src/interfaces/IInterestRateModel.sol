// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IInterestRateModel
/// @notice Swappable kinked (or other) rate curve for a Helix market.
interface IInterestRateModel {
    /// @return borrowRatePerSecond Per-second borrow rate in RAY (27 decimals).
    function getBorrowRate(
        uint256 _totalSupplyAssets,
        uint256 _totalBorrowAssets
    ) external view returns (uint256 borrowRatePerSecond);

}
