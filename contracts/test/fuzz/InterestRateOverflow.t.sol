// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {
    InterestRateModel,
    InterestRateModel__RateTooHigh
} from "../../src/InterestRateModel.sol";
import {HelixMath, RAY, WAD, SECONDS_PER_YEAR} from "../../src/libraries/HelixMath.sol";

/**
 * @notice Packing / overflow probes for Option B (APR-RAY storage).
 * @dev forge test --match-contract InterestRateOverflowTest -vvv
 */
contract InterestRateOverflowTest is Test {
    // Spec example APRs as annual RAY
    uint256 internal constant SPEC_BASE_APR = 0;
    uint256 internal constant SPEC_SLOPE1_APR = 4e25; // 4%
    uint256 internal constant SPEC_SLOPE2_APR = 75e25; // 75%
    uint256 internal constant SPEC_MAX_APR = 300e25; // 300%
    uint256 internal constant SPEC_KINK = 0.8e18; // 80%

    //////////////////////////////////////////////////////////////////////////
    //                          PACKING LIMITS                              //
    //////////////////////////////////////////////////////////////////////////

    function test_reportOptionBPackingLimits() public pure {
        console2.log("--- Option B field maxima ---");
        console2.log("uint96.max (base/slope1 APR-RAY):", type(uint96).max);
        console2.log("uint128.max (slope2/max APR-RAY):", type(uint128).max);
        console2.log("uint64.max (kink WAD):", type(uint64).max);

        console2.log("--- Spec APR-RAY fit ---");
        console2.log("slope1 4e25 fits uint96:", SPEC_SLOPE1_APR <= type(uint96).max);
        console2.log("slope2 75e25 fits uint128:", SPEC_SLOPE2_APR <= type(uint128).max);
        console2.log("max 300e25 fits uint128:", SPEC_MAX_APR <= type(uint128).max);
        console2.log("kink fits uint64:", SPEC_KINK <= type(uint64).max);
    }

    function test_specAprValuesFitOptionBPacking() public pure {
        assertLe(SPEC_BASE_APR, type(uint96).max);
        assertLe(SPEC_SLOPE1_APR, type(uint96).max);
        assertLe(SPEC_SLOPE2_APR, type(uint128).max);
        assertLe(SPEC_MAX_APR, type(uint128).max);
        assertLe(SPEC_KINK, type(uint64).max);
        assertLe(WAD, type(uint64).max);
    }

    function test_constructorAcceptsSpecAprValues() public {
        InterestRateModel irm = new InterestRateModel(
            SPEC_BASE_APR,
            SPEC_SLOPE1_APR,
            SPEC_SLOPE2_APR,
            SPEC_KINK,
            SPEC_MAX_APR
        );
        (uint96 base, uint96 s1, uint64 kink) = irm.rateParams();
        (uint128 s2, uint128 maxApr) = irm.steepParams();
        assertEq(base, SPEC_BASE_APR);
        assertEq(s1, SPEC_SLOPE1_APR);
        assertEq(s2, SPEC_SLOPE2_APR);
        assertEq(kink, SPEC_KINK);
        assertEq(maxApr, SPEC_MAX_APR);
    }

    function test_constructorRevertsWhenSlope1ExceedsUint96() public {
        uint256 tooBig = uint256(type(uint96).max) + 1;
        vm.expectRevert(InterestRateModel__RateTooHigh.selector);
        new InterestRateModel(0, tooBig, tooBig, SPEC_KINK, SPEC_MAX_APR);
    }

    function test_constructorRevertsWhenSlope2ExceedsUint128() public {
        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.expectRevert(InterestRateModel__RateTooHigh.selector);
        new InterestRateModel(0, 0, tooBig, SPEC_KINK, 1);
    }

    function test_legacyUint64PerSecondWouldOverflowSlope2() public pure {
        // Documents why we left per-second uint64 packing: 75% APR as per-second overflows uint64.
        uint256 slope2PerSecond = SPEC_SLOPE2_APR / SECONDS_PER_YEAR;
        assertGt(slope2PerSecond, type(uint64).max);
    }

    //////////////////////////////////////////////////////////////////////////
    //                   HOT-PATH MULTIPLY OVERFLOW BOUNDS                  //
    //////////////////////////////////////////////////////////////////////////

    function test_aprRayToPerSecond_5percent() public pure {
        uint256 fivePct = 5e25;
        uint256 perSecond = HelixMath.aprRayToPerSecond(fivePct);
        // ~1.585e18
        assertEq(perSecond, fivePct / SECONDS_PER_YEAR);
        assertGt(perSecond, 0);
    }

    function test_getBorrowRate_returnsPerSecondNotApr() public {
        InterestRateModel irm = new InterestRateModel(
            SPEC_BASE_APR,
            SPEC_SLOPE1_APR,
            SPEC_SLOPE2_APR,
            SPEC_KINK,
            SPEC_MAX_APR
        );
        // 40% util -> below kink -> rate = 0.4 * slope1PerSecond
        uint256 rate = irm.getBorrowRate(1_000_000e6, 400_000e6);
        uint256 slope1Ps = HelixMath.aprRayToPerSecond(SPEC_SLOPE1_APR);
        uint256 expected = (0.4e18 * slope1Ps) / WAD;
        assertEq(rate, expected);
        // Must be per-second scale, not APR-RAY
        assertLt(rate, SPEC_SLOPE1_APR);
    }

    function test_getBorrowRate_aboveKinkUsesSlope2() public {
        InterestRateModel irm = new InterestRateModel(
            SPEC_BASE_APR,
            SPEC_SLOPE1_APR,
            SPEC_SLOPE2_APR,
            SPEC_KINK,
            SPEC_MAX_APR
        );
        // 90% util
        uint256 rate = irm.getBorrowRate(1_000_000e6, 900_000e6);
        uint256 slope1Ps = HelixMath.aprRayToPerSecond(SPEC_SLOPE1_APR);
        uint256 slope2Ps = HelixMath.aprRayToPerSecond(SPEC_SLOPE2_APR);
        uint256 expected = (SPEC_KINK * slope1Ps) / WAD + ((0.9e18 - SPEC_KINK) * slope2Ps) / WAD;
        assertEq(rate, expected);
    }

    function test_getBorrowRate_capEnforced() public {
        // Cap at 1% APR — below uncapped rate at high util
        uint256 lowCap = 1e25;
        InterestRateModel irm = new InterestRateModel(0, SPEC_SLOPE1_APR, SPEC_SLOPE2_APR, SPEC_KINK, lowCap);
        uint256 rate = irm.getBorrowRate(1e18, 1e18);
        assertEq(rate, HelixMath.aprRayToPerSecond(lowCap));
    }

    ///////////////////////////////////////////////////////////////////////////
    //                                    FUZZ                               //
    ///////////////////////////////////////////////////////////////////////////

    function testFuzz_getBorrowRate_boundedByMaxApr(
        uint96 base,
        uint96 slope1,
        uint128 slope2,
        uint64 kink,
        uint128 supply,
        uint128 borrow
    ) public {
        // Keep APR-RAY in a range where per-second rates are meaningful (avoid dust->0 rates)
        base = uint96(bound(base, 0, 10 * RAY)); // up to 1000% APR
        slope1 = uint96(bound(slope1, 0, 10 * RAY));
        slope2 = uint128(bound(slope2, slope1, 20 * RAY));
        kink = uint64(bound(kink, 0, WAD));
        uint256 maxApr = uint256(base) + uint256(slope1) + uint256(slope2);
        if (maxApr == 0) maxApr = 1;

        InterestRateModel irm = new InterestRateModel(base, slope1, slope2, kink, maxApr);

        // Realistic pool sizes (avoid util * slope uint256 overflow grief vectors)
        supply = uint128(bound(supply, 1, 1e30));
        borrow = uint128(bound(borrow, 0, 1e30));

        uint256 rate = irm.getBorrowRate(supply, borrow);
        assertLe(rate, HelixMath.aprRayToPerSecond(maxApr));
    }

    function testFuzz_utilizationTimesPerSecondSlope_noOverflow(
        uint128 slopeAprRay,
        uint256 utilWad
    ) public pure {
        utilWad = bound(utilWad, 0, 10 * WAD);
        uint256 slopePs = HelixMath.aprRayToPerSecond(slopeAprRay);
        uint256 term = (utilWad * slopePs) / WAD;
        assertLe(term, 10 * slopePs);
    }
}
