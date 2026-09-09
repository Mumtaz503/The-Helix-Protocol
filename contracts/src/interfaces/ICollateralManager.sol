// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICollateralManager {
    function addCollateral(address user, address underlying, uint256 amount) external;
    function removeCollateral(address user, address underlying, uint256 amount) external;
    function getCollateral(address user) external view returns (uint256);
}
