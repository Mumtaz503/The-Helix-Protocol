// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICollateralManager} from "./interfaces/ICollateralManager.sol";

contract CollateralManager is ICollateralManager {
    function addCollateral(address user, address underlying, uint256 amount) external {
        // TODO: Implement
    }

    function removeCollateral(address user, address underlying, uint256 amount) external {
        // TODO: Implement
    }

    function getCollateral(address user) external view returns (uint256) {
        // TODO: Implement
    }
}
