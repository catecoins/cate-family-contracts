// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CateFamilyTestBase} from "./Base.t.sol";
import {CateFamilyFactory} from "../src/CateFamilyFactory.sol";
import {CateFamilyGraduation} from "../src/CateFamilyGraduation.sol";
import {IPancakeV3Factory, IPancakeV3Pool, INonfungiblePositionManager} from "../src/interfaces/IPancakeV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Bonding-curve launches and the graduation stamp.
///
/// The whole risk in this contract is orientation. Pancake sorts a pool's
/// tokens by address, so when a launched token sorts SECOND the pool prices
/// token-per-quote and its tick runs backwards — the token getting more
/// expensive moves the pool tick DOWN. Reading a range back out without
/// mirroring it does not fail loudly: it marks every token graduated the
/// instant it launches, or never marks any.
///
/// So every behavioural test here runs TWICE, once with the launched token
/// sorting below the quote asset and once above, found by searching salts
/// rather than hoping. A version of this file that only tested one ordering
/// would pass just as happily with the comparison inverted.
contract GraduationTest is CateFamilyTestBase {
    CateFamilyGraduation internal graduation;

    /// $5,000 market cap on a 1e9 supply, aligned to the 1% tier's 200 grid.
    int24 internal constant CURVE_START = -122000;
    /// $45,000 — where the curve range ends and the token has graduated.
    int24 internal constant CURVE_GRADUATION = -100000;
    int24 internal constant MAX_USABLE = 887200;

    function setUp() public override {
        super.setUp();
        graduation = new CateFamilyGraduation(PANCAKE_V3_FACTORY, POSITION_MANAGER, address(locker));
        vm.label(address(graduation), "Graduation");
    }

    // ----------------------------------------------------------- helpers

    /// @dev Two ranges: 80% as the curve, 20% above it. The shape the launch
    /// form builds, and the one `scripts/verify-curve.mjs` checks.
    function _curveParams(address quoteToken, bytes32 salt)
        internal
        pure
        returns (CateFamilyFactory.LaunchParams memory p)
    {
        p = _defaultParams(quoteToken, CURVE_START);
        p.salt = salt;
        p.positions = new CateFamilyFactory.LiquidityPosition[](2);
        p.positions[0] =
            CateFamilyFactory.LiquidityPosition({tickLower: CURVE_START, tickUpper: CURVE_GRADUATION, bps: 8000});
        p.positions[1] =
            CateFamilyFactory.LiquidityPosition({tickLower: CURVE_GRADUATION, tickUpper: MAX_USABLE, bps: 2000});
    }

    /// @dev Finds a salt whose predicted token address falls on the requested
    /// side of `quoteToken`. Both orderings are reachable — the address is
    /// CREATE2-derived from the salt — but which salt gets you there is a
    /// property of the fork, so it is searched rather than hardcoded.
    function _saltFor(address quoteToken, bool wantTokenFirst) internal view returns (bytes32) {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(quoteToken, CURVE_START);
        for (uint256 i = 1; i < 512; i++) {
            bytes32 salt = bytes32(i);
            address predicted =
                factory.predictTokenAddress(creator, salt, p.name, p.symbol, p.totalSupply, p.metadataURI);
            if ((predicted < quoteToken) == wantTokenFirst) return salt;
        }
        revert("no salt found for that ordering");
    }

    function _launchCurve(address quoteToken, bool tokenFirst)
        internal
        returns (address token, address pool, uint256[] memory ids)
    {
        bytes32 salt = _saltFor(quoteToken, tokenFirst);
        vm.prank(creator);
        (token, pool, ids) = factory.launch(_curveParams(quoteToken, salt));
        assertEq(token < quoteToken, tokenFirst, "salt did not produce the intended ordering");
    }

    // ------------------------------------------------------------- shape

    function test_CurveLaunchMintsTwoLockedRanges() public {
        (address token, address pool, uint256[] memory ids) = _launchCurve(USDT, true);
        assertEq(ids.length, 2, "one locked position per range");
        assertEq(IERC20(token).balanceOf(address(factory)), 0, "factory keeps nothing");

        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(INonfungiblePositionManager(POSITION_MANAGER).ownerOf(ids[i]), address(locker), "locked");
        }

        (, int24 tick,,,,,) = IPancakeV3Pool(pool).slot0();
        assertEq(tick, CURVE_START, "pool opens at the curve's lower bound");
    }

    // ------------------------------------- the stamp, in both orderings

    function test_DoesNotGraduateBeforeTheCurveIsExhausted() public {
        _assertNoEarlyGraduation(true);
    }

    function test_DoesNotGraduateBeforeTheCurveIsExhausted_TokenSortsSecond() public {
        _assertNoEarlyGraduation(false);
    }

    function _assertNoEarlyGraduation(bool tokenFirst) internal {
        (address token, address pool,) = _launchCurve(USDT, tokenFirst);

        // Well short of the ~$12,097 the curve absorbs in full.
        _buy(pool, token, USDT, trader, 2_000 ether);

        assertFalse(graduation.hasGraduated(token), "not graduated yet");
        vm.expectRevert(CateFamilyGraduation.CurveNotExhausted.selector);
        graduation.markGraduated(token);
    }

    function test_GraduatesOnceTheCurveIsSoldThrough() public {
        _assertGraduates(true);
    }

    function test_GraduatesOnceTheCurveIsSoldThrough_TokenSortsSecond() public {
        _assertGraduates(false);
    }

    function _assertGraduates(bool tokenFirst) internal {
        (address token, address pool,) = _launchCurve(USDT, tokenFirst);

        // Comfortably past the curve's capacity, so the price ends up inside
        // the upper range whichever way the pool is oriented.
        _buy(pool, token, USDT, trader, 40_000 ether);

        (, int24 rawTick,,,,,) = IPancakeV3Pool(pool).slot0();
        int24 canonical = tokenFirst ? rawTick : -rawTick;
        assertGe(canonical, CURVE_GRADUATION, "price really is past the curve");

        uint64 stamped = graduation.markGraduated(token);
        assertEq(stamped, uint64(block.number), "stamped at the current block");
        assertTrue(graduation.hasGraduated(token), "graduated");
        assertEq(graduation.graduatedAtBlock(token), uint64(block.number));
    }

    function test_StampIsOneWayEvenIfThePriceFallsBack() public {
        (address token, address pool,) = _launchCurve(USDT, true);
        _buy(pool, token, USDT, trader, 40_000 ether);
        graduation.markGraduated(token);

        // Sell most of it back. The price drops below the graduation line
        // again — a live progress reading would fall with it, which is exactly
        // why the stamp exists.
        uint256 held = IERC20(token).balanceOf(trader);
        _sell(pool, token, USDT, trader, (held * 90) / 100);

        (, int24 rawTick,,,,,) = IPancakeV3Pool(pool).slot0();
        assertLt(rawTick, CURVE_GRADUATION, "price fell back below the line");
        assertTrue(graduation.hasGraduated(token), "the stamp does not come off");
    }

    function test_CannotStampTwice() public {
        (address token, address pool,) = _launchCurve(USDT, true);
        _buy(pool, token, USDT, trader, 40_000 ether);
        graduation.markGraduated(token);

        vm.expectRevert(CateFamilyGraduation.AlreadyGraduated.selector);
        graduation.markGraduated(token);
    }

    function test_AnyoneCanStamp() public {
        (address token, address pool,) = _launchCurve(USDT, true);
        _buy(pool, token, USDT, trader, 40_000 ether);

        vm.prank(makeAddr("passer-by"));
        graduation.markGraduated(token);
        assertTrue(graduation.hasGraduated(token));
    }

    // --------------------------------------------------------- rejections

    function test_RejectsAStandardLaunchWithNoCurve() public {
        vm.prank(creator);
        (address token, address pool,) = factory.launch(_defaultParams(USDT, CURVE_START));

        _buy(pool, token, USDT, trader, 40_000 ether);

        vm.expectRevert(CateFamilyGraduation.NotACurveLaunch.selector);
        graduation.markGraduated(token);
    }

    function test_RejectsATokenTheLockerDoesNotKnow() public {
        vm.expectRevert(CateFamilyGraduation.NotACurveLaunch.selector);
        graduation.markGraduated(makeAddr("stranger"));
    }

    /// @dev The graduation line is taken as the lowest canonical upper bound
    /// across every range, not as `ids[0]`, so reordering the array cannot
    /// silently move it. This launches the same two ranges in reverse order
    /// and asserts the stamp still lands in the same place.
    function test_RangeOrderInTheArrayDoesNotMoveTheLine() public {
        bytes32 salt = _saltFor(USDT, true);
        CateFamilyFactory.LaunchParams memory p = _defaultParams(USDT, CURVE_START);
        p.salt = salt;
        p.positions = new CateFamilyFactory.LiquidityPosition[](2);
        // Upper range first — the opposite of what the launch form builds.
        p.positions[0] =
            CateFamilyFactory.LiquidityPosition({tickLower: CURVE_GRADUATION, tickUpper: MAX_USABLE, bps: 2000});
        p.positions[1] =
            CateFamilyFactory.LiquidityPosition({tickLower: CURVE_START, tickUpper: CURVE_GRADUATION, bps: 8000});

        vm.prank(creator);
        (address token, address pool,) = factory.launch(p);

        _buy(pool, token, USDT, trader, 2_000 ether);
        vm.expectRevert(CateFamilyGraduation.CurveNotExhausted.selector);
        graduation.markGraduated(token);

        _buy(pool, token, USDT, trader, 40_000 ether);
        graduation.markGraduated(token);
        assertTrue(graduation.hasGraduated(token));
    }
}
