// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";

abstract contract InterestRateModel is IInterestRateModel {

    constructor(uint256 _baseRatePerSecond) {

    }

    function getBorrowRate(uint256 totalBorrowAssets) external view returns (uint256) {

    }
}
