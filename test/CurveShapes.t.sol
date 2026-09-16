// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CateFamilyTestBase} from "./Base.t.sol";
import {CateFamilyFactory} from "../src/CateFamilyFactory.sol";
import {CateFamilyGraduation} from "../src/CateFamilyGraduation.sol";
import {IPancakeV3Pool} from "../src/interfaces/IPancakeV3.sol";
import {TickMath} from "../src/lib/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Curve shapes outside the three presets, launched for real.
///
/// `script/LaunchCurve.s.sol` takes ticks computed by `lib/curve.ts` rather
/// than deriving them in Solidity. That is the right split — one tested
/// implementation of the arithmetic, not two — but it leaves a gap: nothing
/// checked that a given pair of ticks actually produces the market cap the
/// TypeScript promised, on a real pool, against real PancakeSwap.
///
/// This closes it for the $120,000 shape, by trading a launch all the way to
/// graduation and reading the cap off the pool.
contract CurveShapesTest is CateFamilyTestBase {
    /// $5,000 on a 1e9 supply, aligned to the 1% tier's 200 grid.
    int24 internal constant OPEN_TICK = -122000;
    /// $120,000 on the same supply. curveShape's output for the same inputs.
    int24 internal constant GRADUATION_TICK = -90200;
    int24 internal constant MAX_USABLE = 887200;

    /// What lib/curve.ts says these ticks mean, to the dollar. If the chain
    /// disagrees with these, one of the two implementations is wrong.
    uint256 internal constant EXPECTED_OPEN_USD = 5_033;
    uint256 internal constant EXPECTED_GRADUATION_USD = 121_020;
    uint256 internal constant EXPECTED_RAISE_USD = 19_744;

    function _params(bytes32 salt) internal pure returns (CateFamilyFactory.LaunchParams memory p) {
        p = _defaultParams(USDT, OPEN_TICK);
        p.salt = salt;
        p.positions = new CateFamilyFactory.LiquidityPosition[](2);
        p.positions[0] =
            CateFamilyFactory.LiquidityPosition({tickLower: OPEN_TICK, tickUpper: GRADUATION_TICK, bps: 8000});
        p.positions[1] =
            CateFamilyFactory.LiquidityPosition({tickLower: GRADUATION_TICK, tickUpper: MAX_USABLE, bps: 2000});
    }

    /// @dev Market cap in whole USDT, read from the pool's own price. USDT is
    /// 18 decimals on BSC and the launched token is too, so the sqrt price is a
    /// plain ratio and needs no decimal correction.
    function _marketCapUsd(address pool, address token, uint256 supply) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IPancakeV3Pool(pool).slot0();
        uint256 q96 = 2 ** 96;
        // price = (sqrt/2^96)^2, taken in two steps to stay inside uint256.
        uint256 numerator = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 priceX192Scaled = (numerator * 1e18) / (q96 * q96);
        uint256 price = IPancakeV3Pool(pool).token0() == token ? priceX192Scaled : (1e36 / priceX192Scaled); // mirrored pool: invert
        return (price * (supply / 1e18)) / 1e18;
    }

    /// @dev Market cap implied by a tick, independent of where the pool
    /// happens to be trading.
    function _marketCapAtTick(int24 tick, uint256 supply) internal pure returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        uint256 q96 = 2 ** 96;
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) / (q96 * q96);
        return (price * (supply / 1e18)) / 1e18;
    }

    /// The whole point: these ticks really do open at ~$5,033 and mark
    /// graduation at ~$121,021, on a real Pancake pool rather than in a
    /// spreadsheet.
    function test_TheOneTwentyKShapeOpensAndGraduatesWhereItShould() public {
        // A token sorting below USDT, so the pool reads in canonical
        // orientation and the assertions below are legible.
        bytes32 salt;
        for (uint256 i = 1; i < 512; i++) {
            CateFamilyFactory.LaunchParams memory probe = _defaultParams(USDT, OPEN_TICK);
            address predicted = factory.predictTokenAddress(
                creator, bytes32(i), probe.name, probe.symbol, probe.totalSupply, probe.metadataURI
            );
            if (predicted < USDT) {
                salt = bytes32(i);
                break;
            }
        }

        vm.prank(creator);
        (address token, address pool,) = factory.launch(_params(salt));

        uint256 openCap = _marketCapUsd(pool, token, DEFAULT_SUPPLY);
        assertApproxEqAbs(openCap, EXPECTED_OPEN_USD, 2, "opens at ~$5,033");

        // The graduation cap is the price AT the line, which is a property of
        // the tick and nothing else. Measuring it after trading would measure
        // the overshoot instead: past graduation only the thin upper range is
        // left, so a 5% overbuy carries the cap about 6.5% higher.
        assertApproxEqAbs(
            _marketCapAtTick(GRADUATION_TICK, DEFAULT_SUPPLY),
            EXPECTED_GRADUATION_USD,
            2,
            "the graduation line is ~$121,021"
        );

        // The raise is what the RANGE absorbs, which is net of the pool's own
        // fee. A buyer pays that on top: spending exactly the advertised
        // $19,744 lands 161 ticks short at the 1% tier, because a hundredth of
        // it never reaches the curve. 2% over covers the fee and the dollar of
        // truncation in the constant above — a real buyer aiming at graduation
        // would not target the exact wei either.
        _buy(pool, token, USDT, trader, (EXPECTED_RAISE_USD * 1e18 * 102) / 100);
        (, int24 tickNow,,,,,) = IPancakeV3Pool(pool).slot0();
        assertGe(tickNow, GRADUATION_TICK, "the grossed-up raise exhausts the curve");
        assertGt(_marketCapUsd(pool, token, DEFAULT_SUPPLY), EXPECTED_GRADUATION_USD, "and is past the line");
    }

    /// The raise is not a rounding of the presets: $120k needs meaningfully
    /// more buying than $69k, and meaningfully less than double.
    function test_TheRaiseSitsWhereTheSquareRootSaysItShould() public {
        bytes32 salt = bytes32(uint256(901));
        vm.prank(creator);
        (address token, address pool,) = factory.launch(_params(salt));

        // Comfortably under the raise must NOT graduate it.
        _buy(pool, token, USDT, trader, (EXPECTED_RAISE_USD * 1e18 * 90) / 100);
        (, int24 tick,,,,,) = IPancakeV3Pool(pool).slot0();
        int24 canonical = token < USDT ? tick : -tick;
        assertLt(canonical, GRADUATION_TICK, "90% of the raise leaves it on the curve");

        // And the rest finishes it.
        _buy(pool, token, USDT, trader, (EXPECTED_RAISE_USD * 1e18 * 20) / 100);
        (, tick,,,,,) = IPancakeV3Pool(pool).slot0();
        canonical = token < USDT ? tick : -tick;
        assertGe(canonical, GRADUATION_TICK, "the full raise graduates it");
    }

    /// And it stamps, so the shape is a real curve launch to the registry and
    /// not just two ranges that happen to look like one.
    function test_TheShapeGraduatesThroughTheRegistry() public {
        CateFamilyGraduation graduation =
            new CateFamilyGraduation(PANCAKE_V3_FACTORY, POSITION_MANAGER, address(locker));

        bytes32 salt = bytes32(uint256(902));
        vm.prank(creator);
        (address token, address pool,) = factory.launch(_params(salt));

        vm.expectRevert(CateFamilyGraduation.CurveNotExhausted.selector);
        graduation.markGraduated(token);

        _buy(pool, token, USDT, trader, EXPECTED_RAISE_USD * 1e18 * 2);
        graduation.markGraduated(token);
        assertTrue(graduation.hasGraduated(token), "recorded as graduated");
    }
}
