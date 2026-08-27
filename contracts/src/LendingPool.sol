// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {HelixMath, RAY, BASIS_POINTS} from "./libraries/HelixMath.sol";
import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";

/*******************************************************************************
 *
 * @title: LendingPool
 * @author: mumtaz503
 *
 * This contract is the immutable accounting core for a single asset market (e.g., USDC).
 *
 * It handles:
 *  Deposits / Withdrawals – users supply liquidity and earn interest.
 *  Borrow / Repay – users borrow against collateral (tracked by CollateralManager)
 *  Interest accrual – via global indices (supplyIndex, borrowIndex) with catch-up logic
 *  Reserve factor – portion of borrower interest goes to protocol reserves (bad‑debt backstop)
 *  Collateral integration – delegates health-factor checks to CollateralManager
 *   and exposes settlement functions for the auction house (Phase 2)
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

contract LendingPool is ReentrancyGuard, Pausable {
    constructor(
        address _underlying,
        address _collateralManager,
        address _oracle,
        address _interestRateModel,
        uint256 _reserveFactor,
        uint256 _dust
    ) {
        underlying = _underlying;
        collateralManager = _collateralManager;
        oracle = _oracle;
        interestRateModel = _interestRateModel;
        reserveFactor = _reserveFactor;
        dust = _dust;

        // Indexes start at RAY — never zero (Helix storage rule).
        _market.borrowIndex = uint128(RAY);
        _market.supplyIndex = uint128(RAY);
        _market.lastUpdateTimestamp = uint40(block.timestamp);
    }

    /***************************************************************************
     *
     *
     * Event Logging
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * Storage Data Structures
     *
     *
     **************************************************************************/

    /// @dev Packed global market accounting — indexes and totals in three slots.
    ///      Indexes initialize to RAY (never zero). lastUpdateTimestamp is zero only pre-init.
    struct MarketState {
        uint128 borrowIndex;
        uint128 supplyIndex;
        uint128 totalSupplyAssets;
        uint128 totalBorrowAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowShares;

        // This is more than three slots
        // TODO: Need to fix it
        uint128 reserves;
        uint40 lastUpdateTimestamp;
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
    address public immutable underlying;
    address public immutable collateralManager;
    address public immutable oracle;

    address public interestRateModel;
    uint256 public reserveFactor;
    uint256 public dust;

    MarketState internal _market;

    /***************************************************************************
     *
     *
     * INTERNAL ACCESS STATE DATA
     *
     *
     **************************************************************************/
    uint256 internal constant VIRTUAL_SHARES = 1e18;
    uint256 internal constant VIRTUAL_ASSETS = 1e18;

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
     * EXTERNAL FUNCTIONALITY
     *
     *
     **************************************************************************/

    /**
     * Rounding: FLOOR – depositor receives no more shares than they paid for
     * Pause: new deposits blocked when paused == true
     */
    function deposit(
        uint256 amount,
        address onBehalfOf
    ) external nonReentrant whenNotPaused returns (uint256 sharesMinted) {
        // Accrues interest (_accrueInterest())
        // Transfers amount of underlying from caller.
        // Computes shares to mint sharesMinted = _convertToShares(amount, Math.FLOOR)
        //   (round down, per rounding table).
        // Mints shares to onBehalfOf via _mintSupplyShares().
        // If usingAsCollateral[onBehalfOf] is true, calls
        //   collateralManager.addCollateral(onBehalfOf, underlying, amount).
        // Emits Deposit event.
    }

    /**
     * Rounding: CEIL – user never receives more than their shares represent
     * Health check: Before removing collateral, we must ensure the owner's health factor remains ≥ 1
     *  (or they have no debt).
     *  This is done by calling _checkHealth(owner) after the collateral removal simulation.
     * Full withdrawal: If owner has no debt and is fully withdrawing, they can remove all collateral.
     *  If they have debt, they must repay first.
     */
    function withdraw(
        uint256 shares,
        address receiver,
        address owner
    ) external nonReentrant returns (uint256 assets) {
        // Accrues interest
        // Burns shares from owner
        //  (must have sufficient balance, and msg.sender must be approved via ERC‑20 style allowance
        //  or be owner – we can add a permit pattern later).
        // Computes underlying assets to return:
        //  assets = _convertToAssets(shares, Math.CEIL) (round up, per rounding table
        //  withdrawal never over‑redeems)
        // Transfers assets to receiver
        // If usingAsCollateral[owner] is true, calls collateralManager.removeCollateral(owner,
        //  underlying, assets) – but only if after removal the position remains healthy
        //  (we must check health factor before removing; if removal would make it unhealthy,
        //  revert unless it's a full withdrawal that closes the position?
        //  Actually the health factor check is integrated)
        // Emits Withdraw event
    }

    /**
     *
     * Rounding: CEIL – debt shares minted up, so borrower owes at least amount
     * Debt floor: if borrowShares[msg.sender] == 0, require amount >= dust. If they already have debt,
     *  they can borrow any amount, but the resulting total debt (in underlying) must be ≥ dust (which it already is)
     * Pause: new borrows blocked.
     */
    function borrow(
        uint256 amount,
        address to
    ) external nonReentrant whenNotPaused {
        // Accrues interest
        // Enforces amount >= dust if borrowShares[msg.sender] == 0 (new borrower must borrow at least dust).
        //  If already has debt, no minimum check (but total debt must stay above dust after borrow? It already is;
        //  we can allow any incremental amount)
        // Computes shares to mint sharesMinted = _convertToShares(amount, Math.CEIL)
        //  (round down, per rounding table) Borrower owes at least what they drew.
        // Mints shares to msg.sender
        // Transfers amount of underlying to `to`
        // Calls collateralManager.updateBorrow(msg.sender, amount) to notify collateral manager of increased debt.
        // Checks health factor after borrow: _requireHealthy(msg.sender) – reverts if HF < 1.
        // Emits Borrow event.
    }

    /**
     * Rounding: FLOOR – debt shares burned down, so protocol may be left with tiny dust
     *  (which is acceptable and captured in totalBorrow drift).
     */
    function repay(
        uint256 amount,
        address borrower
    ) external nonReentrant returns (uint256 actualRepaid) {
        // Accrues interest
        // Transfers amount of underlying from caller (or less if borrower's debt is smaller)
        // Computes debt shares to burn:
        //  sharesBurned = _convertToDebtShares(amount, Math.FLOOR) – repayment never over‑credits
        // Burns sharesBurned from borrower's debt shares
        // Updates collateralManager of reduced debt
        // If after repayment the remaining debt is > 0 and < dust, we either:
        // - Revert (don't allow partial repay to leave dust), or
        // - Automatically repay the full remaining amount (as if repayAll).
        //   We'll implement the latter: if remaining debt is less than dust,
        //   we burn all remaining shares and transfer that exact amount
        //   (this may be slightly more than amount provided, so caller must have enough allowance)
        //   But this complicates the function.
        //   We can just require that after repayment, the remaining debt is either 0 or ≥ dust.
        //   If the requested repayment would leave a positive amount below dust, we revert and suggest repayAll
        // Emits Repay event.
    }

    /**
     * Used when partial repay would leave dust.
     */
    function repayAll(
        address borrower
    ) external nonReentrant returns (uint256 repaidAmount) {
        // Accrues interest
        // Computes total debt of borrower in underlying
        // Transfers exactly that amount from caller
        // Burns all debt shares of borrower (set to 0)
        // Updates collateralManager
        // Emits Repay event
    }

    function setUseAsCollateral(
        address user,
        bool enabled
    ) external nonReentrant {
        // Only callable by user (or a manager with approval)
        // If enabled:
        // - Call collateralManager.addCollateral(user, underlying, _userSupplyInUnderlying()).
        // - Call collateralManager.removeCollateral(user, underlying, _userSupplyInUnderlying()).
        // Emits CollateralStatusChanged
    }

    /**
     *
     * Only callable by auctionHouse (set by governance)
     * Important: This function must respect the debt floor
     *  if after liquidation the borrower's remaining debt is > 0 but < dust
     *  the entire remaining debt must be cleared (full liquidation of that position)
     */
    function executeLiquidation(
        address borrower,
        uint256 debtToCover,
        uint256 collateralToSeize
    ) external nonReentrant /*onlyAuctionHouse*/ {
        // Accrues interest
        // Validates that the borrower is undercollateralized (HF < 1) – computed live from oracle
        // Burns debt shares from borrower corresponding to debtToCover (floor rounding)
        // Reduces totalBorrowShares and updates indices
        // Transfers collateralToSeize from the pool? Actually the collateral is held in the
        //   CollateralManager contract. So we call
        //   collateralManager.seizeCollateral(borrower, msg.sender, collateralToSeize)
        //   to transfer seized collateral to the liquidator (or auction house).
        //   But the liquidation auction will send the debt payment to the pool and receive collateral.
        //   The executeLiquidation will take the debt payment from the auction house (already transferred)
        //   and then send the seized collateral to the auction house. We'll design this later.
        //   For Phase 1 we just stub a function that can be called by auction house to burn debt and adjust collateral
        // Emits Liquidation event
    }

    /***************************************************************************
     *
     *
     * PUBLIC AND INTERNAL ACCESS FUNCTIONALITY for the user and this contract
     *
     *
     **************************************************************************/

    function borrowIndex() external view returns (uint256) {
        return _market.borrowIndex;
    }

    function supplyIndex() external view returns (uint256) {
        return _market.supplyIndex;
    }

    function totalSupplyAssets() external view returns (uint256) {
        return _market.totalSupplyAssets;
    }

    function totalBorrowAssets() external view returns (uint256) {
        return _market.totalBorrowAssets;
    }

    function reserves() external view returns (uint256) {
        return _market.reserves;
    }

    function lastUpdateTimestamp() external view returns (uint256) {
        return _market.lastUpdateTimestamp;
    }

    /***************************************************************************
     *
     *
     * INTERNAL FUNCTIONALITY
     *
     *
     **************************************************************************/

    /// @dev Advances borrow/supply indices and protocol reserves for elapsed time.
    ///      Idempotent within a block. Index advance truncates (floor) per rounding table.
    ///      No event — accrue runs on every user action; logging is opt-in at call sites.
    function _accrueInterest() internal {
        MarketState memory state = _market;
        uint256 timestamp = block.timestamp;
        if (timestamp == state.lastUpdateTimestamp) return;

        unchecked {
            uint256 timeDelta = timestamp - state.lastUpdateTimestamp;

            // update _market's last time stamp
            state.lastUpdateTimestamp = uint40(timestamp);

            if (state.totalBorrowAssets != 0) {
                state = _accrueWithDebt(state, timeDelta);
            }
            _market = state;
        }
    }

    function _accrueWithDebt(
        MarketState memory state,
        uint256 timeDelta
    ) internal view returns (MarketState memory) {
        uint256 totalBorrow = state.totalBorrowAssets;

        // For testing we used a constant constructor set borrowRate
        uint256 borrowRate = IInterestRateModel(interestRateModel)
            .getBorrowRate(state.totalSupplyAssets, totalBorrow);

        // Global index that tracks the total debt growth over time
        uint256 oldBorrowIndex = state.borrowIndex;

        // Compund the global borrow index
        uint256 newBorrowIndex = HelixMath.rayMul(
            oldBorrowIndex,
            HelixMath.rayCompound(borrowRate, timeDelta)
        );
        state.borrowIndex = uint128(newBorrowIndex);

        uint256 newTotalBorrow = (totalBorrow * newBorrowIndex) /
            oldBorrowIndex;
        uint256 borrowInterest = newTotalBorrow - totalBorrow;
        state.totalBorrowAssets = uint128(newTotalBorrow);

        if (borrowInterest == 0) return state;

        uint256 reserveIncrease = (borrowInterest * reserveFactor) /
            BASIS_POINTS;
        state.reserves = uint128(uint256(state.reserves) + reserveIncrease);

        uint256 supplyInterest = borrowInterest - reserveIncrease;
        uint256 totalSupply = state.totalSupplyAssets;
        if (totalSupply == 0 || supplyInterest == 0) return state;

        uint256 oldSupplyIndex = state.supplyIndex;
        state.supplyIndex = uint128(
            oldSupplyIndex +
                HelixMath.rayMul(
                    oldSupplyIndex,
                    (supplyInterest * RAY) / totalSupply
                )
        );
        state.totalSupplyAssets = uint128(totalSupply + supplyInterest);
        return state;
    }

    /***************************************************************************
     *
     *
     * PRIVATE FUNCTIONALITY -- Abstract Contracts ONLY!!!
     *
     *
     **************************************************************************/
}
