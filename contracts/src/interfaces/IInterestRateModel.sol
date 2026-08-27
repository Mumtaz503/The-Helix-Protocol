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


    /// @return utilizationWad Returns 0 if totalSupplyAssets == 0; else floor ratio in WAD.
    function getUtilization(
        uint256 _totalSupplyAssets,
        uint256 _totalBorrowAssets
    ) external pure returns (uint256 utilizationWad);
}
