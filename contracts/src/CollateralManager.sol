// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICollateralManager} from "./interfaces/ICollateralManager.sol";
import "./libraries/HelixMath.sol";

/*******************************************************************************
 *
 * CollateralManager
 *
 * CollateralManager answers three questions for every user:
 * What collateral do they have?
 * How much debt do they owe (in value terms)?
 * Are they healthy right now (HF ≥ 1)?
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
error CollateralManager__PoolNotSet();
error CollateralManager__AssetNotEnabled();
error CollateralManager__PrimaryAssetMismatch();
error CollateralManager__AmountOverflow();
error CollateralManager__ZeroUser();

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

contract CollateralManager is ICollateralManager {
    constructor() payable {
        // Governance / oracle / pools wired via setters (Phase 3 shape).
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

    event CollateralAdded(
        address indexed user,
        address indexed asset,
        uint256 amount
    );

    /***************************************************************************
     *
     *
     * Storage Data Structures
     *
     *
     **************************************************************************/
    // Slot 0 positions[user]
    struct Position {
        uint80 collateralValueCache;
        uint80 debtValueCache;
        // ^ truncated & WAD scaled values
        uint32 lastInteracted; // stores interaction time until year 2106
        // HEALTH FACTOR CACHE IS NEVER AUTHORITATIVE.
        // Liquidation / borrow / withdraw / disable-collateral MUST recompute live HF.
        uint32 hfCache; // WAD >> 96 — keeper / UI hint only
        uint8 mode; // 0 = unset, 1 = isolated, 2 = cross-margin
        uint8 flags; // bit0: hasDebt, bit1: inAuction
        // ^ when an entire slot only holds whether something is true or false,
        //    it's better to use uint(x) instead of bool
        uint16 reserved;
        // 80+80+32+32+8+8 = 240 bits -> 16 bits reserved
    }

    struct AssetConfig {
        uint64 ltvWad; // e.g. 0.75e18
        uint64 liquidationThresholdWad; // e.g. 0.80e18 scaled to WAD
        uint64 liquidationBonusWad; // expanded in Phase 2
        uint8 decimals;
        uint8 enabled; // 0/1/2
        // pack into <= 1 slot
    }
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
    /**
     * @dev Multi-asset cross-margin separation for collaterals
     * https://github.com/Mumtaz503/The-Helix-Protocol/blob/main/docs/CollateralManager.spec.md#single-slot-position-packing
     */
    mapping(address => mapping(address => uint128)) public collateralAmounts;
    mapping(address => address) public primaryAsset;

    mapping(address => mapping(address => uint128)) public debtUnderlying;
    // ^ user => market (LendingPool / underlying) => accrued debt units

    mapping(address => uint8) public isPool; // 0 unset, 1 false, 2 true

    address public auctionHouse;
    address public oracle;
    address public governance;
    // ^ addresses for relevant protocol contracts

    mapping(address => Position) public positions;
    mapping(address => AssetConfig) public assetConfig;

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
    /**
     * @notice Increase enabled collateral for `user` in `underlying`.
     * @dev Only callable by a registered LendingPool (`isPool == 2`).
     *      Isolated mode: first asset becomes primary; other assets revert.
     *      HF / value caches are best-effort; never authoritative for auth.
     */
    function addCollateral(
        address user,
        address underlying,
        uint256 amount
    ) external { //TODO: Access control modifer
        require(user != address(0), CollateralManager__ZeroUser());
        require(isPool[msg.sender] == 2, CollateralManager__PoolNotSet());
        require(
            assetConfig[underlying].enabled == 2,
            CollateralManager__AssetNotEnabled()
        );
        require(amount != 0 && amount <= type(uint128).max, InvalidAmount(address(this)));

        Position memory pos = positions[user];

        // Isolated mode: only one collateral asset allowed.
        if (pos.mode == 1) {
            address primary = primaryAsset[user];
            if (primary != address(0) && primary != underlying) {
                revert CollateralManager__PrimaryAssetMismatch();
            }
            if (primary == address(0)) {
                primaryAsset[user] = underlying;
            }
        }

        uint256 newAmount = uint256(collateralAmounts[user][underlying]) +
            amount;

        // TODO: forget the revert. We need to make sure that collateralAmount does not exceed uint128.max.
        // if (newAmount > type(uint128).max) {
        //     revert CollateralManager__AmountOverflow();
        // }
        collateralAmounts[user][underlying] = uint128(newAmount);

        // Opportunistic cache touch — NOT authoritative for liquidation/borrow auth.
        pos.lastInteracted = uint32(block.timestamp);
        positions[user] = pos;

        emit CollateralAdded(user, underlying, amount);
    }

    function removeCollateral(
        address user,
        address underlying,
        uint256 amount
    ) external {
        // TODO: Implement
    }

    function getCollateral(address user) external view returns (uint256) {
        // TODO: Implement
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
