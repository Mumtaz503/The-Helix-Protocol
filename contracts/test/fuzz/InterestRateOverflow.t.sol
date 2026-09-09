// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {RAY, WAD} from "../../src/libraries/HelixMath.sol";


/**
 * @notice Overflow / packing limit probes for InterestRateModel rate params.
 * @dev Run with: forge test --match-contract InterestRateOverflowTest -vvv
 */

contract InterestRateOverflowTest is Test {
    uint256 internal constant SECONDS_PER_YEAR = 31_557_600; // 365.25 * 86400

    // Spec example APRs as annual RAY (aprRay = apr% / 100 * RAY)
    uint256 internal constant SPEC_BASE_APR = 0;
    uint256 internal constant SPEC_SLOPE1_APR = 4e25; // 4%
    uint256 internal constant SPEC_SLOPE2_APR = 75e25; // 75%
    uint256 internal constant SPEC_MAX_APR = 300e25; // 300%
    uint256 internal constant SPEC_KINK = 0.8e18; // 80%

    //////////////////////////////////////////////////////////////////////////
    //                          PACKING LIMITS (uint64)                     //
    //////////////////////////////////////////////////////////////////////////


    /**
     * @notice Prints max packable per-second rates and equivalent APR.
     * @dev This is the number that answers "what overflows uint64?"
     */
    function test_reportUint64PackingLimits() public pure {
        uint256 maxU64 = type(uint64).max;

        // Max per-second RAY that fits in RateParams uint64 fields
        uint256 maxPerSecond = maxU64;

        // Equivalent continuous APR in RAY: aprRay ≈ ratePerSecond * SECONDS_PER_YEAR
        uint256 maxAprRay = maxPerSecond * SECONDS_PER_YEAR;
        // Human % ≈ aprRay / RAY * 100
        uint256 maxAprBps = (maxAprRay * 10_000) / RAY; // basis points

        console2.log("//// uint64 packing limits (current RateParams) ////");
        console2.log("type(uint64).max (max per-second RAY):", maxPerSecond);
        console2.log("max APR as RAY (perSecond * YEAR):", maxAprRay);
        console2.log("max APR in basis points (~):", maxAprBps);
        console2.log("max APR percent (~):", maxAprBps / 100);

        // Spec per-second conversions
        uint256 slope1Ps = SPEC_SLOPE1_APR / SECONDS_PER_YEAR;
        uint256 slope2Ps = SPEC_SLOPE2_APR / SECONDS_PER_YEAR;
        uint256 maxPs = SPEC_MAX_APR / SECONDS_PER_YEAR;

        console2.log("//// Spec example as per-second RAY ////");
        console2.log("slope1 4% per-second:", slope1Ps);
        console2.log("slope2 75% per-second:", slope2Ps);
        console2.log("max 300% per-second:", maxPs);

        console2.log("//// Fits in uint64? ////");
        console2.log("slope1 fits:", slope1Ps <= maxU64);
        console2.log("slope2 fits:", slope2Ps <= maxU64);
        console2.log("maxRate fits uint64:", maxPs <= maxU64);
        // maxRatePerSecond is uint256 in storage today — packing concern is RateParams only
        console2.log("kink 0.8e18 fits:", SPEC_KINK <= maxU64);
        console2.log("kink full WAD fits:", WAD <= maxU64);
    }

    /**
     * @notice Hard assertions: which spec values fit current uint64 packing.
     * 
     */
    function test_specValuesAgainstUint64() public pure {
        uint256 maxU64 = type(uint64).max;

        assertLe(SPEC_SLOPE1_APR / SECONDS_PER_YEAR, maxU64, "slope1 4% must fit uint64");
        assertLe(SPEC_KINK, maxU64, "kink 80% must fit uint64");
        assertLe(WAD, maxU64, "full WAD kink must fit uint64");

        // These are EXPECTED to fail packing if we required uint64 for slope2/max —
        // document as explicit knowledge tests (assertTrue of the overflow condition).
        assertGt(
            SPEC_SLOPE2_APR / SECONDS_PER_YEAR,
            maxU64,
            "slope2 75% MUST overflow uint64 (documents the packing bug)"
        );
        assertGt(
            SPEC_MAX_APR / SECONDS_PER_YEAR,
            maxU64,
            "max 300% MUST overflow uint64 if packed as uint64"
        );
    }

    /// @dev Constructor must reject slope2 above uint64.max.
    function test_constructorRevertsWhenSlope2ExceedsUint64() public {
        uint256 tooBig = uint256(type(uint64).max) + 1;
        vm.expectRevert(); // InterestRateModel__RateTooHigh or Panic on cast
        new InterestRateModel(0, 0, tooBig, SPEC_KINK, 1);
    }

    /// @dev Constructor accepts max packable slopes.
    function test_constructorAcceptsMaxUint64Slopes() public {
        uint256 maxU64 = type(uint64).max;
        InterestRateModel irm = new InterestRateModel(0, maxU64, maxU64, SPEC_KINK, maxU64);
        (uint64 base, uint64 s1, uint64 s2, uint64 kink) = irm.rateParams();
        assertEq(base, 0);
        assertEq(s1, maxU64);
        assertEq(s2, maxU64);
        assertEq(kink, SPEC_KINK);
    }

    //////////////////////////////////////////////////////////////////////////
    //                   HOT-PATH MULTIPLY OVERFLOW BOUNDS                  //
    //////////////////////////////////////////////////////////////////////////


    /**
     *  @dev utilization * slope must not overflow uint256 for packed uint64 slopes.
     *       Worst case: util can exceed WAD if borrow > supply (no clamp today).
     */
    function test_mulUtilizationSlope_noOverflowAtUint64Max() public pure {
        uint256 slope = type(uint64).max;
        // Extreme utilization: borrow >> supply → huge U
        // Bound U to something realistic for a grief: e.g. type(uint128).max / 1 as util wad-ish
        // Safe bound: if U <= type(uint128).max and slope <= uint64.max:
        // product <= 2^128 * 2^64 = 2^192 < 2^256
        uint256 maxSafeUtil = type(uint128).max;
        uint256 product = maxSafeUtil * slope; // must not revert
        assertTrue(product > 0);

        // Realistic WAD util
        uint256 atWad = (WAD * slope) / WAD;
        assertEq(atWad, slope);
    }

    /**
     * @dev Fuzz: for any uint64 slope and util in [0, 10 * WAD], mulDiv does not overflow.
     */
    function testFuzz_utilizationTimesSlope_noOverflow(uint64 slope, uint256 utilWad) public pure {
        utilWad = bound(utilWad, 0, 10 * WAD); // allow up to 1000% util
        uint256 term = (utilWad * uint256(slope)) / WAD;
        // term <= 10 * slope <= 10 * uint64.max — fine
        assertLe(term, 10 * uint256(type(uint64).max));
    }

    /**
     * @dev getBorrowRate at max packed params + 100% util must not revert / overflow.
     */
    function test_getBorrowRate_atMaxPackedParams() public {
        uint256 maxU64 = type(uint64).max;
        InterestRateModel irm = new InterestRateModel(0, maxU64, maxU64, SPEC_KINK, type(uint256).max);

        uint256 rate = irm.getBorrowRate(1e18, 1e18); // 100% util
        // rate = 0 + kink*slope1/WAD + (WAD-kink)*slope2/WAD
        //     <= slope1 + slope2 <= 2 * uint64.max
        assertLe(rate, 2 * maxU64);
        assertGt(rate, 0);
    }

    ///////////////////////////////////////////////////////////////////////////
    //                          WIDER TYPE HEADROOM                          //
    ///////////////////////////////////////////////////////////////////////////

    /**
     * @dev Shows how much APR fits if we widen packing
     */
    function test_reportWiderTypeLimits() public pure {
        console2.log("//// If we widen fields (Option A) ////");
        _logTypeLimit("uint96", type(uint96).max);
        _logTypeLimit("uint128", type(uint128).max);

        uint256 slope2Ps = SPEC_SLOPE2_APR / SECONDS_PER_YEAR;
        uint256 maxPs = SPEC_MAX_APR / SECONDS_PER_YEAR;

        console2.log("slope2 75% fits uint96:", slope2Ps <= type(uint96).max);
        console2.log("slope2 75% fits uint128:", slope2Ps <= type(uint128).max);
        console2.log("max 300% fits uint96:", maxPs <= type(uint96).max);
        console2.log("max 300% fits uint128:", maxPs <= type(uint128).max);

        // Option B: store APR-RAY directly
        console2.log("//// Option B store APR-RAY ////");
        console2.log("75e25 fits uint96:", SPEC_SLOPE2_APR <= type(uint96).max);
        console2.log("300e25 fits uint96:", SPEC_MAX_APR <= type(uint96).max);
        console2.log("300e25 fits uint128:", SPEC_MAX_APR <= type(uint128).max);
    }

    function _logTypeLimit(string memory name, uint256 maxVal) internal pure {
        uint256 maxAprRay = maxVal * SECONDS_PER_YEAR;
        // Cap display if insane
        uint256 maxAprBps = maxAprRay > type(uint256).max / 10_000
            ? type(uint256).max
            : (maxAprRay * 10_000) / RAY;
        console2.log(name, "max per-second:", maxVal);
        console2.log(name, "max APR bps (~):", maxAprBps);
    }

    ///////////////////////////////////////////////////////////////////////////
    //                      INVARIANT-STYLE PROPERTY (handler-lite)          //
    ///////////////////////////////////////////////////////////////////////////

    /**
     * @dev Property: for any valid packed IRM, getBorrowRate never reverts and
     * never exceeds max(base + slope1 + slope2, maxRate) style bound.
     */
    function testFuzz_getBorrowRate_bounded(
        uint64 base,
        uint64 slope1,
        uint64 slope2,
        uint64 kink,
        uint128 supply,
        uint128 borrow
    ) public {
        slope2 = uint64(bound(slope2, slope1, type(uint64).max));
        kink = uint64(bound(kink, 0, WAD));
        uint256 maxRate = uint256(base) + uint256(slope1) + uint256(slope2);
        if (maxRate == 0) maxRate = 1;

        InterestRateModel irm = new InterestRateModel(base, slope1, slope2, kink, maxRate);

        supply = uint128(bound(supply, 0, type(uint128).max));
        borrow = uint128(bound(borrow, 0, type(uint128).max));

        uint256 rate = irm.getBorrowRate(supply, borrow);
        assertLe(rate, maxRate);
    }
}
