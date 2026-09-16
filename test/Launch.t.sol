// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CateFamilyTestBase, DummyERC20} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CateFamilyFactory} from "../src/CateFamilyFactory.sol";
import {CateFamilyToken} from "../src/CateFamilyToken.sol";
import {TickMath} from "../src/lib/TickMath.sol";
import {IPancakeV3Pool, INonfungiblePositionManager} from "../src/interfaces/IPancakeV3.sol";

contract LaunchTest is CateFamilyTestBase {
    // ------------------------------------------------------------ TickMath
    // The ported TickMath must agree bit-for-bit with the library the live
    // Pancake pools use. Proven by initializing a REAL pool at a fuzzed tick
    // with our sqrt price and reading the tick back out of slot0.

    /// forge-config: default.fuzz.runs = 40
    function testFuzz_TickMathMatchesLivePancakePool(int24 rawTick) public {
        int24 maxUsable = (TickMath.MAX_TICK / TICK_SPACING_1PCT) * TICK_SPACING_1PCT;
        int24 tick = int24(bound(int256(rawTick), int256(-maxUsable) + 1, int256(maxUsable) - 1));
        tick = (tick / TICK_SPACING_1PCT) * TICK_SPACING_1PCT;

        // A virgin pair per run, initialized but never minted into, so the
        // assertion isolates TickMath from V3's per-tick liquidity ceiling.
        address token = address(new DummyERC20());
        bool tokenIsToken0 = token < WBNB;
        (address t0, address t1) = tokenIsToken0 ? (token, WBNB) : (WBNB, token);
        int24 poolTick = tokenIsToken0 ? tick : -tick;

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(poolTick);
        address pool = INonfungiblePositionManager(POSITION_MANAGER)
            .createAndInitializePoolIfNecessary(t0, t1, FEE_1PCT, sqrtPriceX96);

        (uint160 actualSqrtPriceX96, int24 actualTick,,,,,) = IPancakeV3Pool(pool).slot0();
        assertEq(actualSqrtPriceX96, sqrtPriceX96, "pool stored a different sqrt price");
        // Pancake derived this tick with ITS OWN TickMath. Equality proves the
        // ported library agrees with the deployed one across the tick range.
        assertEq(actualTick, poolTick, "pool tick disagrees with ported TickMath");
        assertEq(TickMath.getTickAtSqrtRatio(actualSqrtPriceX96), poolTick, "inverse is not consistent");
    }

    function test_TickMathBoundaryConstants() public pure {
        assertEq(TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK), TickMath.MIN_SQRT_RATIO, "MIN_SQRT_RATIO");
        assertEq(TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK), TickMath.MAX_SQRT_RATIO, "MAX_SQRT_RATIO");
        assertEq(TickMath.getSqrtRatioAtTick(0), 79228162514264337593543950336, "1.0 price is 2**96");
    }

    // -------------------------------------------------------------- launch

    function test_LaunchAgainstWBNB() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);

        address predicted = factory.predictTokenAddress(creator, p.salt, p.name, p.symbol, p.totalSupply, p.metadataURI);

        vm.prank(creator);
        (address token, address pool, uint256[] memory positionIds) = factory.launch(p);

        assertEq(token, predicted, "CREATE2 prediction must match the deployed token");
        assertEq(positionIds.length, 1, "one full-range position by default");

        CateFamilyToken t = CateFamilyToken(token);
        assertEq(t.name(), "CateFamily Test");
        assertEq(t.symbol(), "CAPTEST");
        assertEq(t.totalSupply(), DEFAULT_SUPPLY);
        assertEq(t.creator(), creator);
        assertEq(t.decimals(), 18);

        // Entire supply is pool liquidity or burned dust — the factory keeps nothing.
        assertEq(t.balanceOf(address(factory)), 0, "factory must retain no supply");
        assertGt(t.balanceOf(pool), DEFAULT_SUPPLY - 1e18, "virtually all supply sits in the pool");

        // The LP NFT is in the locker, and there is no code path that moves it out.
        assertEq(
            INonfungiblePositionManager(POSITION_MANAGER).ownerOf(positionIds[0]),
            address(locker),
            "LP NFT must be locked"
        );

        (address recTok, address recQuote, address recPool, address recCreator, uint24 recFee,) =
            factory.launches(token);
        assertEq(recTok, token);
        assertEq(recQuote, WBNB);
        assertEq(recPool, pool);
        assertEq(recCreator, creator);
        assertEq(recFee, FEE_1PCT);
        assertEq(factory.totalLaunches(), 1);
    }

    function test_LaunchAgainstUSDT() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(USDT, TICK_5K_USD_MCAP);
        vm.prank(creator);
        (address token, address pool,) = factory.launch(p);
        assertGt(IERC20(token).balanceOf(pool), DEFAULT_SUPPLY - 1e18);
        assertEq(IPancakeV3Pool(pool).fee(), FEE_1PCT);
    }

    function test_LaunchWithNativeFirstBuy() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.initialBuyQuoteAmount = 1 ether;
        p.initialBuyMinTokensOut = 1; // real slippage floors come from the UI quote

        uint256 balBefore = creator.balance;
        vm.prank(creator);
        (address token,,) = factory.launch{value: 1 ether}(p);

        assertGt(IERC20(token).balanceOf(creator), 0, "creator must receive first-buy tokens");
        assertLe(creator.balance, balBefore - 1 ether + 1, "BNB must actually be spent");
    }

    function test_LaunchWithERC20FirstBuy() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(USDT, TICK_5K_USD_MCAP);
        p.initialBuyQuoteAmount = 100 ether; // 100 USDT (18 decimals on BSC)
        p.initialBuyMinTokensOut = 1;

        deal(USDT, creator, 100 ether);
        vm.startPrank(creator);
        IERC20(USDT).approve(address(factory), type(uint256).max);
        (address token,,) = factory.launch(p);
        vm.stopPrank();

        assertGt(IERC20(token).balanceOf(creator), 0, "creator must receive first-buy tokens");
        assertEq(IERC20(USDT).balanceOf(address(factory)), 0, "factory must not retain quote dust");
    }

    function test_FirstBuyRefundsUnspentQuote() public {
        // Buy far more than the range can absorb; the pool consumes what it can
        // and the factory must hand the remainder straight back.
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        // Narrow first band holding a tenth of the supply: a 900 BNB buy sweeps
        // clean past its top and stops there (the first-buy cap is 10%).
        p.positions = new CateFamilyFactory.LiquidityPosition[](2);
        p.positions[0] = CateFamilyFactory.LiquidityPosition({
            tickLower: TICK_10_BNB_MCAP, tickUpper: TICK_10_BNB_MCAP + 2000, bps: 1000
        });
        p.positions[1] = CateFamilyFactory.LiquidityPosition({
            tickLower: TICK_10_BNB_MCAP + 2000, tickUpper: 887200, bps: 9000
        });
        p.initialBuyQuoteAmount = 900 ether;
        p.initialBuyMinTokensOut = 1;

        uint256 before = creator.balance;
        vm.prank(creator);
        factory.launch{value: 900 ether}(p);
        assertGt(creator.balance, before - 900 ether, "unspent BNB must be refunded");
        assertEq(address(factory).balance, 0, "factory must not sit on native dust");
    }

    // -------------------------------------------------------------- guards

    function test_RevertsWhenLaunchFeeExceedsConsent() public {
                _setLaunchFee(factory, 0.5 ether);

        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.maxLaunchFeeWei = 0.1 ether; // creator consented to less than the owner now charges

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(CateFamilyFactory.LaunchFeeAboveCap.selector, 0.5 ether, 0.1 ether));
        factory.launch{value: 0.5 ether}(p);
    }

    function test_LaunchFeeReachesTreasury() public {
                _setLaunchFee(factory, 0.25 ether);

        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        uint256 before = treasury.balance;
        vm.prank(creator);
        factory.launch{value: 0.25 ether}(p);
        assertEq(treasury.balance - before, 0.25 ether, "launch fee must reach the treasury");
    }

    // ------------------------------------ the launch fee, with a first buy
    //
    // `test_LaunchFeeReachesTreasury` above launches with NO first buy, so
    // `msg.value == launchFeeWei` exactly and the interesting branch of
    // `_collectLaunchFee` never runs. With the fee at zero on mainnet since
    // deployment, the combination below has never executed anywhere but here —
    // and it is what every creator who funds a first buy natively will hit the
    // moment the fee is switched on.

    /// The fee and the buy travel in ONE `msg.value`, and the factory has to
    /// split them: `nativeBuyWei = msg.value - fee_`. Get that wrong in either
    /// direction and the creator either overpays the treasury or buys with the
    /// fee money.
    function test_LaunchFeeAndNativeFirstBuyTravelTogether() public {
        uint256 fee = 0.005 ether;
                _setLaunchFee(factory, fee);

        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.initialBuyQuoteAmount = 1 ether;
        p.initialBuyMinTokensOut = 1;

        uint256 treasuryBefore = treasury.balance;
        vm.prank(creator);
        (address token,,) = factory.launch{value: fee + 1 ether}(p);

        assertEq(treasury.balance - treasuryBefore, fee, "treasury gets the fee and nothing more");
        assertGt(IERC20(token).balanceOf(creator), 0, "the buy still executed");
        assertEq(address(factory).balance, 0, "no native dust left behind");
    }

    /// The refund path and the fee must not be confused for one another. A buy
    /// that sweeps past its range returns the remainder to the CREATOR, while
    /// the fee stays with the treasury.
    function test_UnspentFirstBuyIsRefundedToTheCreatorNotTheTreasury() public {
        uint256 fee = 0.005 ether;
                _setLaunchFee(factory, fee);

        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        // Narrow first band with a tenth of the supply, so a 900 BNB buy
        // cannot possibly be consumed in full (and stays inside the 10% cap).
        p.positions = new CateFamilyFactory.LiquidityPosition[](2);
        p.positions[0] = CateFamilyFactory.LiquidityPosition({
            tickLower: TICK_10_BNB_MCAP, tickUpper: TICK_10_BNB_MCAP + 2000, bps: 1000
        });
        p.positions[1] = CateFamilyFactory.LiquidityPosition({
            tickLower: TICK_10_BNB_MCAP + 2000, tickUpper: 887200, bps: 9000
        });
        p.initialBuyQuoteAmount = 900 ether;
        p.initialBuyMinTokensOut = 1;

        uint256 treasuryBefore = treasury.balance;
        uint256 creatorBefore = creator.balance;

        vm.prank(creator);
        factory.launch{value: fee + 900 ether}(p);

        assertEq(treasury.balance - treasuryBefore, fee, "treasury took exactly the fee");
        // The creator is out the fee plus whatever the pool actually absorbed,
        // never the whole 900.
        assertGt(creator.balance, creatorBefore - fee - 900 ether, "the remainder came back");
        assertEq(address(factory).balance, 0, "nothing stranded");
    }

    /// The other legal shape: a non-WBNB quote, so the buy is pulled by
    /// allowance and `msg.value` carries the fee alone.
    function test_LaunchFeeWithAnErc20FirstBuy() public {
        uint256 fee = 0.005 ether;
                _setLaunchFee(factory, fee);

        CateFamilyFactory.LaunchParams memory p = _defaultParams(USDT, TICK_5K_USD_MCAP);
        p.initialBuyQuoteAmount = 100 ether;
        p.initialBuyMinTokensOut = 1;

        deal(USDT, creator, 100 ether);
        uint256 treasuryBefore = treasury.balance;

        vm.startPrank(creator);
        IERC20(USDT).approve(address(factory), type(uint256).max);
        (address token,,) = factory.launch{value: fee}(p);
        vm.stopPrank();

        assertEq(treasury.balance - treasuryBefore, fee, "fee paid natively even for an ERC20 buy");
        assertGt(IERC20(token).balanceOf(creator), 0, "the buy executed from the allowance");
        assertEq(IERC20(USDT).balanceOf(address(factory)), 0, "no quote dust retained");
    }

    /// Native surplus is legal ONLY as WBNB first-buy funding. Anything else —
    /// a rounding-error overpayment, a tip, a surplus against a USDT quote —
    /// is refused rather than pocketed, because there is no sweep function that
    /// could ever get it back out.
    function test_NativeSurplusThatIsNotAValidBuyIsRefused() public {
        uint256 fee = 0.005 ether;
                _setLaunchFee(factory, fee);

        // Surplus with a non-WBNB quote.
        CateFamilyFactory.LaunchParams memory p = _defaultParams(USDT, TICK_5K_USD_MCAP);
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.IncorrectNativeValue.selector);
        factory.launch{value: fee + 1 ether}(p);

        // Surplus against WBNB that does not equal the declared buy amount.
        CateFamilyFactory.LaunchParams memory q = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        q.salt = bytes32(uint256(77));
        q.initialBuyQuoteAmount = 1 ether;
        q.initialBuyMinTokensOut = 1;
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.IncorrectNativeValue.selector);
        factory.launch{value: fee + 1 ether + 1 wei}(q);

        // Underpaying the fee.
        CateFamilyFactory.LaunchParams memory r = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        r.salt = bytes32(uint256(78));
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.IncorrectNativeValue.selector);
        factory.launch{value: fee - 1}(r);
    }

    function test_RestoresAHostilePrePricedPoolAndLaunches() public {
        // Front-runner opens the pool first at a wildly different price. The
        // pool is necessarily empty (the token did not exist), so the factory
        // moves it back to the requested price for free and launches into it.
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        address predicted = factory.predictTokenAddress(creator, p.salt, p.name, p.symbol, p.totalSupply, p.metadataURI);

        (address token0, address token1) = predicted < WBNB ? (predicted, WBNB) : (WBNB, predicted);
        int24 hostileTick = predicted < WBNB ? int24(0) : int24(0);
        address hostilePool = INonfungiblePositionManager(POSITION_MANAGER)
            .createAndInitializePoolIfNecessary(token0, token1, FEE_1PCT, TickMath.getSqrtRatioAtTick(hostileTick));

        vm.prank(creator);
        (address token, address pool,) = factory.launch(p);
        assertEq(token, predicted);
        assertEq(pool, hostilePool, "launched into the pre-created pool");
        (uint160 sqrtPrice,,,,,,) = IPancakeV3Pool(pool).slot0();
        int24 wantTick = predicted < WBNB ? TICK_10_BNB_MCAP : -TICK_10_BNB_MCAP;
        assertEq(sqrtPrice, TickMath.getSqrtRatioAtTick(wantTick), "price restored exactly");
    }

    function test_PauseStopsNewLaunches() public {
        vm.prank(owner);
        factory.setPaused(true);
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.LaunchesPaused.selector);
        factory.launch(_defaultParams(WBNB, TICK_10_BNB_MCAP));
    }

    function test_RevertsOnUnsupportedFeeTier() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.fee = 3000; // Uniswap's 0.3% tier does not exist on Pancake V3
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.UnsupportedFeeTier.selector);
        factory.launch(p);
    }

    function test_RevertsOnMisalignedTick() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP + 1);
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.TickNotAligned.selector);
        factory.launch(p);
    }

    function test_RevertsOnNonContractQuoteToken() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(makeAddr("notAToken"), TICK_10_BNB_MCAP);
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidQuoteToken.selector);
        factory.launch(p);
    }

    function test_CustomSupplyCurveAcrossMultipleRanges() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.positions = new CateFamilyFactory.LiquidityPosition[](2);
        p.positions[0] = CateFamilyFactory.LiquidityPosition({
            tickLower: TICK_10_BNB_MCAP, tickUpper: TICK_10_BNB_MCAP + 40000, bps: 7000
        });
        p.positions[1] = CateFamilyFactory.LiquidityPosition({
            tickLower: TICK_10_BNB_MCAP + 40000, tickUpper: TICK_10_BNB_MCAP + 100000, bps: 3000
        });

        vm.prank(creator);
        (address token,, uint256[] memory ids) = factory.launch(p);
        assertEq(ids.length, 2, "one LP NFT per range");
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(INonfungiblePositionManager(POSITION_MANAGER).ownerOf(ids[i]), address(locker));
        }
    }

    /// @notice A starting market cap far too high for the supply squeezes the
    /// whole supply into a handful of ticks, and the liquidity that implies
    /// overflows uint128 inside Pancake's LiquidityAmounts (a bare `require`,
    /// hence empty revert data). This is a PancakeSwap ceiling, not a
    /// CateFamily rule, so the launch form has to clamp the market-cap input —
    /// the same constraint Brew surfaces as "Market cap and supply produce an
    /// out-of-range price."
    function test_ExtremeStartingPriceHitsPancakeLiquidityCeiling() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, 880000);
        vm.prank(creator);
        vm.expectRevert();
        factory.launch(p);
    }

    function test_RevertsWhenSupplyCurveBpsDoNotSumTo100Pct() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.positions = new CateFamilyFactory.LiquidityPosition[](1);
        p.positions[0] = CateFamilyFactory.LiquidityPosition({
            tickLower: TICK_10_BNB_MCAP, tickUpper: TICK_10_BNB_MCAP + 40000, bps: 9000
        });
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidBps.selector);
        factory.launch(p);
    }
}
