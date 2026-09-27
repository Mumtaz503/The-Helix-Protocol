// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LendingPool, LendingPool__FOT} from "../../../src/LendingPool.sol";
import {CollateralManager} from "../../../src/CollateralManager.sol";
import {InterestRateModel} from "../../../src/InterestRateModel.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {MockERC20FoT} from "../../../src/mocks/MockERC20FoT.sol";
import {InvalidAmount, InvalidAddress, InsufficientBalance} from "../../../src/libraries/HelixMath.sol";

contract CollateralManagerDepositHarness is CollateralManager {
    LendingPool public reenterPool;
    bool public attackEnabled;

    function setPool(address pool, uint8 status) external {
        isPool[pool] = status;
    }

    function setAssetEnabled(address asset, uint8 enabled) external {
        AssetConfig storage cfg = assetConfig[asset];
        cfg.enabled = enabled;
        cfg.decimals = 6;
        cfg.ltvWad = 0.75e18;
        cfg.liquidationThresholdWad = 0.8e18;
    }

    function setReenterPool(address pool_) external {
        reenterPool = LendingPool(pool_);
    }

    function enableAttack(bool enabled) external {
        attackEnabled = enabled;
    }

    function addCollateral(
        address user,
        address underlying,
        uint256 amount
    ) public override {
        if (attackEnabled && address(reenterPool) != address(0)) {
            attackEnabled = false;
            reenterPool.deposit(1, user);
        }
        super.addCollateral(user, underlying, amount);
    }
}

contract DepositHarness is LendingPool {
    constructor(
        address _underlying,
        address _collateralManager,
        address _oracle,
        address _interestRateModel,
        uint256 _reserveFactor,
        uint256 _dust
    )
        LendingPool(
            _underlying,
            _collateralManager,
            _oracle,
            _interestRateModel,
            _reserveFactor,
            _dust
        )
    {}

    function pausePool() external {
        _pause();
    }

    function setUsingAsCollateral(address user, uint8 status) external {
        usingAsCollateral[user] = status;
    }

    function supplySharesOf(address user) external view returns (uint256) {
        return supplyShares[user];
    }

    function totalSupplyShares() external view returns (uint256) {
        return _market.totalSupplyShares;
    }

    function seedSupply(uint256 assets, uint256 shares) external {
        MarketState memory state = _market;
        state.totalSupplyAssets = uint128(assets);
        state.totalSupplyShares = uint128(shares);
        _market = state;
    }

    function seedTotals(uint256 supplyAssets, uint256 borrowAssets) external {
        MarketState memory state = _market;
        state.totalSupplyAssets = uint128(supplyAssets);
        state.totalBorrowAssets = uint128(borrowAssets);
        _market = state;
    }
}

contract LendingPoolDepositTest is Test {
    uint256 internal constant VIRTUAL = 1e18;
    uint256 internal constant RESERVE_FACTOR = 1000;
    uint256 internal constant DUST = 1e6;

    DepositHarness internal pool;
    MockERC20 internal token;
    CollateralManagerDepositHarness internal cm;
    InterestRateModel internal irm;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    event Deposit(address indexed user, uint256 amount, uint256 sharesMinted);

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 6);
        cm = new CollateralManagerDepositHarness();
        irm = new InterestRateModel(0, 4e25, 75e25, 0.8e18, 300e25);
        pool = new DepositHarness(
            address(token),
            address(cm),
            makeAddr("oracle"), // mock oracle
            address(irm),
            RESERVE_FACTOR,
            DUST
        );
        // Wire real CM auth: pool may call addCollateral; underlying enabled.
        cm.setPool(address(pool), 2);
        cm.setAssetEnabled(address(token), 2);
    }

    function _fundAndApprove(address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(pool), type(uint256).max);
    }

    function _expectedShares(
        uint256 amountReceived,
        uint256 totalAssets,
        uint256 totalShares
    ) internal pure returns (uint256) {
        return
            (amountReceived * (totalShares + VIRTUAL)) /
            (totalAssets + VIRTUAL);
    }

    //////////////////////////////////////////////////////////////////////////////
    //                                                                          //
    //                              Happy path                                  //
    //                                                                          //
    //////////////////////////////////////////////////////////////////////////////

    function test_deposit_firstDepositor_virtualOffset() public {
        uint256 amount = 1000e6;
        _fundAndApprove(alice, amount);

        vm.prank(alice);
        uint256 shares = pool.deposit(amount, alice);

        uint256 expected = _expectedShares(amount, 0, 0);
        assertEq(shares, expected);
        assertEq(shares, amount); // with equal VIRTUAL offsets, empty pool is 1:1
        assertEq(pool.supplySharesOf(alice), expected);
        assertEq(pool.totalSupplyAssets(), amount);
        assertEq(pool.totalSupplyShares(), expected);
        assertEq(token.balanceOf(address(pool)), amount);
    }

    function test_deposit_secondDepositor_fairShare() public {
        _fundAndApprove(alice, 1000e6);
        vm.prank(alice);
        pool.deposit(1000e6, alice);

        pool.seedSupply(1_100e6, 1000e6); // assets > shares -> rate > 1

        uint256 bobAmount = 1000e6;
        _fundAndApprove(bob, bobAmount);
        uint256 expected = _expectedShares(bobAmount, 1_100e6, 1000e6);

        vm.prank(bob);
        uint256 bobShares = pool.deposit(bobAmount, bob);

        assertEq(bobShares, expected);
        assertLt(bobShares, bobAmount);
        assertEq(pool.supplySharesOf(bob), expected);
    }

    function test_deposit_onBehalfOf() public {
        uint256 amount = 500e6;
        _fundAndApprove(alice, amount);

        vm.prank(alice);
        uint256 shares = pool.deposit(amount, bob);

        assertEq(pool.supplySharesOf(bob), shares);
        assertEq(pool.supplySharesOf(alice), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(pool)), amount);
    }

    function test_deposit_accumulates() public {
        _fundAndApprove(alice, 300e6);

        vm.startPrank(alice);
        uint256 s1 = pool.deposit(100e6, alice);
        uint256 s2 = pool.deposit(200e6, alice);
        vm.stopPrank();

        assertEq(pool.supplySharesOf(alice), s1 + s2);
        assertEq(pool.totalSupplyAssets(), 300e6);
        assertEq(pool.totalSupplyShares(), s1 + s2);
    }

    function test_deposit_emitsDeposit() public {
        uint256 amount = 1000e6;
        _fundAndApprove(alice, amount);
        uint256 expectedShares = _expectedShares(amount, 0, 0);

        vm.expectEmit(true, false, false, true, address(pool));
        emit Deposit(alice, amount, expectedShares);

        vm.prank(alice);
        pool.deposit(amount, alice);
    }

    //////////////////////////////////////////////////////////////////////////////
    //                                                                          //
    //                       Rounding / accounting                              //
    //                                                                          //
    //////////////////////////////////////////////////////////////////////////////

    function test_deposit_floorMint() public {
        pool.seedSupply(1_000, 3);
        uint256 amount = 100;
        _fundAndApprove(alice, amount);

        uint256 assetsEff = 1_000 + VIRTUAL;
        uint256 sharesEff = 3 + VIRTUAL;
        uint256 product = amount * sharesEff;
        assertGt(product % assetsEff, 0);
        uint256 expected = product / assetsEff;

        vm.prank(alice);
        uint256 shares = pool.deposit(amount, alice);

        assertEq(shares, expected);
        assertLt(shares, (product + assetsEff - 1) / assetsEff);
    }

    function test_deposit_floorMint_nonzero() public {
        pool.seedSupply(1e18 + 7, 1e18 + 3);
        uint256 amount = 1_000_000;
        _fundAndApprove(alice, amount);

        uint256 assetsEff = (1e18 + 7) + VIRTUAL;
        uint256 sharesEff = (1e18 + 3) + VIRTUAL;
        uint256 product = amount * sharesEff;
        assertGt(product % assetsEff, 0);
        uint256 expected = product / assetsEff;

        vm.prank(alice);
        uint256 shares = pool.deposit(amount, alice);

        assertEq(shares, expected);
        assertLt(shares, (product + assetsEff - 1) / assetsEff);
    }

    function test_deposit_ignoresDonatedTokens() public {
        _fundAndApprove(alice, 1000e6);
        vm.prank(alice);
        uint256 aliceShares = pool.deposit(1000e6, alice);

        token.mint(attacker, 1e12);
        vm.prank(attacker);
        token.transfer(address(pool), 1e12);

        assertEq(token.balanceOf(address(pool)), 1000e6 + 1e12);
        assertEq(pool.totalSupplyAssets(), 1000e6);

        _fundAndApprove(bob, 1000e6);
        uint256 expectedBob = _expectedShares(1000e6, 1000e6, aliceShares);

        vm.prank(bob);
        uint256 bobShares = pool.deposit(1000e6, bob);

        assertEq(bobShares, expectedBob);
        assertEq(bobShares, aliceShares);
        assertEq(pool.totalSupplyAssets(), 2000e6);
    }

    function test_deposit_accruesBeforeMint() public {
        _fundAndApprove(alice, 1_000_000e6);
        vm.prank(alice);
        pool.deposit(1_000_000e6, alice);

        pool.seedTotals(1_000_000e6, 500_000e6);
        assertEq(pool.totalSupplyShares(), pool.supplySharesOf(alice));

        uint256 supplyBefore = pool.totalSupplyAssets();
        uint256 borrowIndexBefore = pool.borrowIndex();

        vm.warp(block.timestamp + 7 days);

        uint256 bobAmount = 100_000e6;
        _fundAndApprove(bob, bobAmount);

        uint256 sharesAtPreAccrual = _expectedShares(
            bobAmount,
            supplyBefore,
            pool.totalSupplyShares()
        );

        vm.prank(bob);
        uint256 bobShares = pool.deposit(bobAmount, bob);

        assertGt(pool.borrowIndex(), borrowIndexBefore);
        assertGt(pool.totalSupplyAssets(), supplyBefore + bobAmount);
        assertLt(bobShares, sharesAtPreAccrual);
    }

    //////////////////////////////////////////////////////////////////////////////
    //                                                                          //
    //                         Validation / reverts                             //
    //                                                                          //
    //////////////////////////////////////////////////////////////////////////////

    function test_deposit_revertsZeroAmount() public {
        _fundAndApprove(alice, 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidAmount.selector, address(pool))
        );
        pool.deposit(0, alice);
    }

    function test_deposit_revertsAmountAboveUint128() public {
        uint256 tooBig = uint256(type(uint128).max) + 1;
        token.mint(alice, tooBig);
        vm.prank(alice);
        token.approve(address(pool), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidAmount.selector, address(pool))
        );
        pool.deposit(tooBig, alice);
    }

    function test_deposit_revertsZeroOnBehalfOf() public {
        _fundAndApprove(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidAddress.selector, address(pool))
        );
        pool.deposit(100e6, address(0));
    }

    function test_deposit_revertsInsufficientBalance() public {
        vm.prank(alice);
        token.approve(address(pool), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(InsufficientBalance.selector, address(pool))
        );
        pool.deposit(100e6, alice);
    }

    function test_deposit_revertsInsufficientAllowance() public {
        token.mint(alice, 100e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(InsufficientBalance.selector, address(pool))
        );
        pool.deposit(100e6, alice);
    }

    function test_deposit_revertsWhenPaused() public {
        _fundAndApprove(alice, 100e6);
        pool.pausePool();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pool.deposit(100e6, alice);
    }

    function test_deposit_revertsFoTZeroReceived() public {
        MockERC20FoT fot = new MockERC20FoT(10_000); // 100% fee
        DepositHarness fotPool = new DepositHarness(
            address(fot),
            address(cm),
            makeAddr("oracle"),
            address(irm),
            RESERVE_FACTOR,
            DUST
        );

        fot.mint(alice, 1000e6);
        vm.prank(alice);
        fot.approve(address(fotPool), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(LendingPool__FOT.selector);
        fotPool.deposit(1000e6, alice);
    }

    function test_deposit_partialFoT_mintsOnReceived() public {
        MockERC20FoT fot = new MockERC20FoT(1_000); // 10% fee
        DepositHarness fotPool = new DepositHarness(
            address(fot),
            address(cm),
            makeAddr("oracle"),
            address(irm),
            RESERVE_FACTOR,
            DUST
        );

        uint256 amount = 1000e6;
        uint256 received = amount - (amount * 1_000) / 10_000; // 900e6
        fot.mint(alice, amount);
        vm.prank(alice);
        fot.approve(address(fotPool), type(uint256).max);

        uint256 expectedShares = _expectedShares(received, 0, 0);

        vm.prank(alice);
        uint256 shares = fotPool.deposit(amount, alice);

        assertEq(shares, expectedShares);
        assertEq(shares, received);
        assertEq(fotPool.totalSupplyAssets(), received);
        assertEq(fot.balanceOf(address(fotPool)), received);
    }

    //////////////////////////////////////////////////////////////////////////////
    //                                                                          //
    //           Collateral integration (real CollateralManager)                //
    //                                                                          //
    //////////////////////////////////////////////////////////////////////////////

    function test_deposit_callsAddCollateralWhenEnabled() public {
        pool.setUsingAsCollateral(alice, 2);
        _fundAndApprove(alice, 1000e6);

        vm.prank(alice);
        pool.deposit(1000e6, alice);

        assertEq(cm.collateralAmounts(alice, address(token)), 1000e6);
        (, , uint32 lastInteracted, , , , ) = cm.positions(alice);
        assertEq(lastInteracted, block.timestamp);
    }

    function test_deposit_addCollateralAccumulatesDelta() public {
        // CM.addCollateral is additive: each deposit passes amountReceived, not full supply.
        pool.setUsingAsCollateral(alice, 2);
        _fundAndApprove(alice, 300e6);

        vm.startPrank(alice);
        pool.deposit(100e6, alice);
        assertEq(cm.collateralAmounts(alice, address(token)), 100e6);
        pool.deposit(200e6, alice);
        vm.stopPrank();

        assertEq(cm.collateralAmounts(alice, address(token)), 300e6);
    }

    function test_deposit_noCollateralWhenUnset() public {
        _fundAndApprove(alice, 100e6);
        vm.prank(alice);
        pool.deposit(100e6, alice);
        assertEq(cm.collateralAmounts(alice, address(token)), 0);
    }

    function test_deposit_noCollateralWhenDisabled() public {
        pool.setUsingAsCollateral(alice, 1);
        _fundAndApprove(alice, 100e6);
        vm.prank(alice);
        pool.deposit(100e6, alice);
        assertEq(cm.collateralAmounts(alice, address(token)), 0);
    }

    //////////////////////////////////////////////////////////////////////////////
    //                                                                          //
    //                              Security                                    //
    //                                                                          //
    //////////////////////////////////////////////////////////////////////////////

    function test_deposit_reentrancyBlocked() public {
        // Reenter via CM.addCollateral (post-transfer). Token-callback reentrancy is
        // swallowed by trySafeTransferFrom and surfaces as InsufficientBalance.
        CollateralManagerDepositHarness cmR = new CollateralManagerDepositHarness();
        DepositHarness rPool = new DepositHarness(
            address(token),
            address(cmR),
            makeAddr("oracle"),
            address(irm),
            RESERVE_FACTOR,
            DUST
        );
        cmR.setPool(address(rPool), 2);
        cmR.setAssetEnabled(address(token), 2);
        cmR.setReenterPool(address(rPool));
        cmR.enableAttack(true);
        rPool.setUsingAsCollateral(alice, 2);

        token.mint(alice, 200e6);
        vm.prank(alice);
        token.approve(address(rPool), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        rPool.deposit(100e6, alice);
    }
}
