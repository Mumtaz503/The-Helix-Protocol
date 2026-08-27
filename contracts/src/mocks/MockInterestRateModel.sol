// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInterestRateModel} from "../interfaces/IInterestRateModel.sol";

/// @dev Fixed per-second borrow rate for unit tests.
contract MockInterestRateModel is IInterestRateModel {
    uint256 public borrowRatePerSecond;

    constructor(uint256 _borrowRatePerSecond) {
        borrowRatePerSecond = _borrowRatePerSecond;
    }

    function getBorrowRate(
        uint256,
        uint256 totalBorrowAssets
    ) external view returns (uint256) {
        if (totalBorrowAssets == 0) return 0;
        return borrowRatePerSecond;
    }

    function getUtilization(
        uint256 _totalSupplyAssets,
        uint256 totalBorrowAssets
    ) external pure returns (uint256) {
        if (_totalSupplyAssets == 0) return 0;
        return totalBorrowAssets / _totalSupplyAssets;
    }
}
