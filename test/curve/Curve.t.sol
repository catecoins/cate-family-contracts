// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurveTestBase} from "./CurveBase.t.sol";
import {CateFamilyCurveLaunchpad} from "../../src/CateFamilyCurveLaunchpad.sol";
import {CateFamilyCurveToken} from "../../src/CateFamilyCurveToken.sol";
import {CateFamilyFactory} from "../../src/CateFamilyFactory.sol";
import {CateFamilyDistributorFactory, CateFamilyHolderDistributor} from "../../src/CateFamilyDistributorFactory.sol";
import {IPancakeV3Pool, INonfungiblePositionManager} from "../../src/interfaces/IPancakeV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Core behaviour of the pump.fun-style curve: presets, trading, caps,
/// the transfer lock, sell-out, graduation, and the post-graduation plumbing.
contract CurveTest is CurveTestBase {
    // ------------------------------------------------------------- presets

    /// The $45k preset opens at $5k and raises $12,000 net when it sells out,
    /// matching the number the launch form quotes today.
    function test_Preset45k_OpensAt5kAndRaises12k() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(1)));
        CateFamilyCurveLaunchpad.Curve memory c = launchpad.curves(token);
        assertApproxEqRel(c.x0, 1_200_000_000 ether, 1e12, "x0 = 800M + 400M virtual");
        assertApproxEqRel(c.y0, 6_000 ether, 1e12, "y0 = $6,000 virtual");
        assertApproxEqRel(launchpad.price(token) * 1_000_000_000, OPEN_USD, 1e12, "opens at $5,000 cap");

        uint256 charged = _sellOut(token, trader);
        c = launchpad.curves(token);
        assertTrue(c.soldOut);
        assertEq(c.tokensRemaining, 0);
        assertEq(IERC20(token).balanceOf(trader), launchpad.CURVE_SUPPLY(), "trader bought the whole curve");
        assertApproxEqRel(c.quoteRaised, 12_000 ether, 1e14, "raised $12,000 net of fees");
        assertApproxEqRel(charged, uint256(12_000 ether) * 10_000 / 9_900, 1e14, "paid $12,121 including the 1% fee");
        assertApproxEqRel(launchpad.price(token) * 1_000_000_000, GRAD_45K, 1e14, "sells out at the $45k cap");
    }

    function test_Preset25kAnd69k_RaiseAsDesigned() public {
        address a = _createUsdt(GRAD_25K, bytes32(uint256(2)));
        _sellOut(a, trader);
        assertApproxEqRel(launchpad.curves(a).quoteRaised, 8_944 ether, 2e14, "$25k preset raises ~$8,944");

        address b = _createUsdt(GRAD_69K, bytes32(uint256(3)));
        _sellOut(b, trader);
        assertApproxEqRel(launchpad.curves(b).quoteRaised, 14_859 ether, 2e14, "$69k preset raises ~$14,859");
    }

    function test_CapsAreValidated() public {
        CateFamilyCurveLaunchpad.CreateParams memory p = _params(USDT, OPEN_USD, GRAD_45K, bytes32(uint256(9)));
        p.quoteToken = CAKE;
        vm.prank(creator);
        vm.expectRevert(CateFamilyCurveLaunchpad.QuoteNotAllowed.selector);
        launchpad.create(p);

        p = _params(USDT, OPEN_USD, OPEN_USD * 30, bytes32(uint256(9))); // above MAX_MULTIPLE
        vm.prank(creator);
        vm.expectRevert(CateFamilyCurveLaunchpad.CapOutOfBounds.selector);
        launchpad.create(p);

        p = _params(USDT, 500 ether, GRAD_45K, bytes32(uint256(9))); // below minOpeningCap
        vm.prank(creator);
        vm.expectRevert(CateFamilyCurveLaunchpad.CapOutOfBounds.selector);
        launchpad.create(p);
    }

    // -------------------------------------------------------------- trading

    function test_BuyThenSellRoundTripLosesOnlyTheFees() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(1)));
        _pastWindow();
        _buyUsdt(token, trader, 1_000 ether);
        uint256 out = _sellAll(token, trader);
        // 1% in, 1% out on a curve that is otherwise path-independent.
        assertApproxEqRel(out, uint256(1_000 ether) * 99 * 99 / 10_000, 1e13, "round trip returns ~98.01%");
        assertEq(IERC20(token).balanceOf(trader), 0);
        assertApproxEqRel(launchpad.protocolFees(USDT), 1_000 ether - out, 1e13, "the rest is protocol fees");
        CateFamilyCurveLaunchpad.Curve memory c = launchpad.curves(token);
        assertEq(c.tokensRemaining, launchpad.CURVE_SUPPLY(), "curve is back to full");
        assertEq(c.quoteRaised, 0, "and holds nothing for sellers");
    }

    function test_QuotesMatchExecution() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(1)));
        _pastWindow();
        (uint256 predicted,) = launchpad.quoteBuy(token, 777 ether);
        uint256 got = _buyUsdt(token, trader, 777 ether);
        assertEq(got, predicted);
        uint256 qs = launchpad.quoteSell(token, got);
        assertEq(_sellAll(token, trader), qs);
    }

    function test_SlippageFloorsAreEnforced() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(1)));
        _pastWindow();
        (uint256 predicted,) = launchpad.quoteBuy(token, 100 ether);
        deal(USDT, trader, 100 ether);
        vm.startPrank(trader);
        IERC20(USDT).approve(address(launchpad), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(CateFamilyCurveLaunchpad.SlippageExceeded.selector, predicted, predicted + 1));
        launchpad.buy(token, 100 ether, predicted + 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- opening window

    function test_OpeningWindowCapsEachWalletAndLiftsAfterward() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(1)));
        uint256 cap = launchpad.curves(token).walletCap;
        assertEq(cap, launchpad.CURVE_SUPPLY() * 2 / 100, "2% of the curve supply");

        // A buy that would push the wallet over the cap is refused...
        (uint256 tooMany,) = launchpad.quoteBuy(token, 200 ether);
        assertGt(tooMany, cap, "precondition: 200 USDT buys more than the cap at the open");
        deal(USDT, trader, 200 ether);
        vm.startPrank(trader, trader);
        IERC20(USDT).approve(address(launchpad), 200 ether);
        vm.expectRevert(abi.encodeWithSelector(CateFamilyCurveLaunchpad.WalletCapExceeded.selector, tooMany, cap));
        launchpad.buy(token, 200 ether, 0);
        vm.stopPrank();

        // ...and splitting it into smaller buys does not help: the cap is on the balance.
        _buyUsdt(token, trader, 40 ether);
        _buyUsdt(token, trader, 30 ether);
        (uint256 more,) = launchpad.quoteBuy(token, 30 ether);
        deal(USDT, trader, 30 ether);
        vm.startPrank(trader, trader);
        IERC20(USDT).approve(address(launchpad), 30 ether);
        vm.expectRevert(
            abi.encodeWithSelector(CateFamilyCurveLaunchpad.WalletCapExceeded.selector, IERC20(token).balanceOf(trader) + more, cap)
        );
        launchpad.buy(token, 30 ether, 0);
        vm.stopPrank();

        // Another wallet has its own cap.
        _buyUsdt(token, attacker, 60 ether);

        // After the window the cap is gone.
        _pastWindow();
        _buyUsdt(token, trader, 2_000 ether);
        assertGt(IERC20(token).balanceOf(trader), cap);
    }

    function test_CreatorFirstBuyMayTakeTheWholeCurveAndSkipsTheWindow() public {
        CateFamilyCurveLaunchpad.CreateParams memory p = _params(USDT, OPEN_USD, GRAD_45K, bytes32(uint256(1)));
        p.firstBuyQuote = 50_000 ether; // far more than the whole curve costs
        deal(USDT, creator, 50_000 ether);
        vm.startPrank(creator);
        IERC20(USDT).approve(address(launchpad), 50_000 ether);
        address token = launchpad.create(p);
        vm.stopPrank();

        uint256 held = IERC20(token).balanceOf(creator);
        assertEq(held, launchpad.CURVE_SUPPLY(), "the whole curve, inside the create transaction");
        assertGt(held, launchpad.curves(token).walletCap, "the creator's buy is not subject to the window cap");
        assertTrue(launchpad.curves(token).soldOut, "sold out inside create");
        uint256 left = IERC20(USDT).balanceOf(creator);
        assertGt(left, 0, "the quote the curve did not need was refunded");
        assertLt(left, 50_000 ether);

        // A partial first buy above the old 10% ceiling is just a buy.
        p.salt = bytes32(uint256(2));
        p.firstBuyQuote = 1_000 ether;
        vm.startPrank(creator);
        IERC20(USDT).approve(address(launchpad), 1_000 ether);
        address token2 = launchpad.create(p);
        vm.stopPrank();
        assertGt(IERC20(token2).balanceOf(creator), launchpad.CURVE_SUPPLY() / 10);
        assertFalse(launchpad.curves(token2).soldOut);
    }

    // ------------------------------------------------------------ transfer lock

    function test_TokensCannotMoveAnywhereButTheCurveBeforeGraduation() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(1)));
        _pastWindow();
        _buyUsdt(token, trader, 100 ether);
        uint256 bal = IERC20(token).balanceOf(trader);

        vm.startPrank(trader);
        vm.expectRevert(CateFamilyCurveToken.NotLaunched.selector);
        IERC20(token).transfer(attacker, bal);
        IERC20(token).approve(attacker, bal);
        vm.stopPrank();
        vm.prank(attacker);
        vm.expectRevert(CateFamilyCurveToken.NotLaunched.selector);
        IERC20(token).transferFrom(trader, attacker, bal);

        // Not even into a pool position.
        vm.startPrank(trader);
        IERC20(token).approve(POSITION_MANAGER, bal);
        vm.expectRevert();
        INonfungiblePositionManager(POSITION_MANAGER).mint(
            INonfungiblePositionManager.MintParams({
                token0: token < USDT ? token : USDT,
                token1: token < USDT ? USDT : token,
                fee: 10000,
                tickLower: -887200,
                tickUpper: 887200,
                amount0Desired: token < USDT ? bal : 0,
                amount1Desired: token < USDT ? 0 : bal,
                amount0Min: 0,
                amount1Min: 0,
                recipient: trader,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(CateFamilyCurveToken.OnlyCurve.selector);
        CateFamilyCurveToken(token).launch();
    }

    // ------------------------------------------------------------- sell-out

    function test_SellOutIsExactRefundsTheExcessAndClosesTheCurve() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(1)));
        _pastWindow();
        uint256 budget = 100_000 ether;
        deal(USDT, trader, budget);
        vm.startPrank(trader);
        IERC20(USDT).approve(address(launchpad), budget);
        launchpad.buy(token, budget, 0);
        vm.stopPrank();

        CateFamilyCurveLaunchpad.Curve memory c = launchpad.curves(token);
        assertEq(c.tokensRemaining, 0);
        assertTrue(c.soldOut);
        assertEq(IERC20(token).balanceOf(trader), launchpad.CURVE_SUPPLY());
        assertApproxEqRel(IERC20(USDT).balanceOf(trader), budget - 12_121 ether, 1e13, "excess refunded");
        assertEq(IERC20(USDT).balanceOf(address(launchpad)), c.quoteRaised + launchpad.protocolFees(USDT), "books balance");

        vm.prank(trader);
        vm.expectRevert(CateFamilyCurveLaunchpad.CurveClosed.selector);
        launchpad.buy(token, 1 ether, 0);
        vm.startPrank(trader);
        IERC20(token).approve(address(launchpad), 1 ether);
        vm.expectRevert(CateFamilyCurveLaunchpad.CurveClosed.selector);
        launchpad.sell(token, 1 ether, 0);
        vm.stopPrank();
    }

    // ----------------------------------------------------------- graduation

    function test_GraduationCreatesThePoolAtTheCurvePriceWithTwoLockedPositions() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(1)));
        _sellOut(token, trader);
        uint256 raised = launchpad.curves(token).quoteRaised;
        uint256 feesBefore = launchpad.protocolFees(USDT);

        vm.prank(attacker); // anyone
        (address pool, uint256[] memory ids) = launchpad.graduate(token);

        // Token is free, curve is closed.
        assertTrue(CateFamilyCurveToken(token).launched());
        CateFamilyCurveLaunchpad.Curve memory c = launchpad.curves(token);
        assertTrue(c.graduated);
        assertEq(c.pool, pool);
        vm.expectRevert(CateFamilyCurveLaunchpad.AlreadyGraduated.selector);
        launchpad.graduate(token);

        // Graduation cut: 5% of the raise to protocol fees.
        uint256 cut = raised * 500 / 10_000;
        assertEq(launchpad.protocolFees(USDT), feesBefore + cut, "5% graduation fee booked");
        assertApproxEqRel(cut, 600 ether, 1e14, "$600 on the $45k preset");

        // Pool price equals the curve's final price, exactly: same reserves, same maths.
        (uint160 sqrtP,,,,,,) = IPancakeV3Pool(pool).slot0();
        uint256 ratioX192 = token < USDT ? Math.mulDiv(c.y, 1 << 192, c.x) : Math.mulDiv(c.x, 1 << 192, c.y);
        assertEq(uint256(sqrtP), Math.sqrt(ratioX192), "pool opened at the curve's final price");

        // Two positions in the locker: two-sided at the price, and a standing bid.
        assertEq(ids.length, 2);
        assertEq(curveLocker.positionsOf(token).length, 2);
        assertEq(INonfungiblePositionManager(POSITION_MANAGER).ownerOf(ids[0]), address(curveLocker));
        assertEq(INonfungiblePositionManager(POSITION_MANAGER).ownerOf(ids[1]), address(curveLocker));
        (uint256 a0, uint256 a1) = _positionAmounts(ids[0], pool);
        (uint256 tokensInPool, uint256 quoteInPool) = token < USDT ? (a0, a1) : (a1, a0);
        assertApproxEqRel(tokensInPool, launchpad.POOL_SUPPLY(), 1e12, "200M tokens in the two-sided position");
        assertApproxEqRel(quoteInPool, 9_000 ether, 2e14, "$9,000 (20% of the cap) against them");
        (a0, a1) = _positionAmounts(ids[1], pool);
        (uint256 bidTokens, uint256 bidQuote) = token < USDT ? (a0, a1) : (a1, a0);
        assertEq(bidTokens, 0, "the standing bid holds quote only");
        assertApproxEqRel(bidQuote, raised - cut - 9_000 ether, 2e14, "and the rest of the net raise");
        (,, uint16 bps) = curveLocker.lockedPositions(ids[0]);
        assertEq(bps, 2000, "protocol LP share snapshotted at creation");

        // Nothing stranded.
        assertEq(IERC20(token).balanceOf(address(launchpad)), 0, "no tokens left in the launchpad");
        assertEq(IERC20(USDT).balanceOf(address(launchpad)), launchpad.protocolFees(USDT), "only fees left");
        assertEq(launchpad.curves(token).quoteRaised, 0);

        // Free trading on Pancake, in both directions, and the locker collects fees.
        uint256 dead = IERC20(token).balanceOf(DEAD);
        _buy(pool, token, USDT, attacker, 500 ether);
        _sell(pool, token, USDT, trader, 1_000_000 ether);
        curveLocker.collectAllFees(token);
        assertGt(curveLocker.claimableFees(creator, USDT), 0, "creator earns post-graduation fees");
        assertGt(curveLocker.claimableFees(curveLocker.PROTOCOL(), USDT), 0, "so does the protocol");
        assertGt(IERC20(token).balanceOf(DEAD), dead, "and the token side is burned");
    }

    function test_GraduationWithNativeBnb() public {
        address token = _createBnb(bytes32(uint256(5)));
        _pastWindow();
        uint256 before = trader.balance; // _buyBnb deals the amount first, so a full spend leaves this unchanged
        _buyBnb(token, trader, 2 ether);
        assertEq(trader.balance, before, "the whole 2 BNB was spent");
        uint256 out = _sellAll(token, trader);
        assertGt(out, 1.9 ether, "sell pays out native BNB");
        assertEq(trader.balance, before + out);

        _sellOut(token, trader);
        (address pool, uint256[] memory ids) = launchpad.graduate(token);
        assertEq(ids.length, 2);
        assertGt(IERC20(WBNB).balanceOf(pool), 0, "pool funded in WBNB");
        assertApproxEqRel(launchpad.curves(token).x0, 1_200_000_000 ether, 1e15, "6.88 -> 61.9 BNB is a ~9x");
        _buy(pool, token, WBNB, attacker, 0.5 ether);
        assertGt(IERC20(token).balanceOf(attacker), 0);
    }

    /// The mirrored orientation (token sorts after the quote) graduates identically.
    function test_GraduationWhenTheTokenSortsSecond() public {
        CateFamilyCurveLaunchpad.CreateParams memory p = _params(USDT, OPEN_USD, GRAD_45K, bytes32(0));
        for (uint256 i = 1; i < 512; i++) {
            p.salt = bytes32(i);
            if (launchpad.predictTokenAddress(creator, p.salt, p.name, p.symbol, p.metadataURI) > USDT) break;
        }
        vm.prank(creator);
        address token = launchpad.create(p);
        assertTrue(token > USDT, "token is token1");
        _sellOut(token, trader);
        (address pool, uint256[] memory ids) = launchpad.graduate(token);
        assertEq(ids.length, 2);
        (uint256 a0, uint256 a1) = _positionAmounts(ids[0], pool);
        assertApproxEqRel(a1, launchpad.POOL_SUPPLY(), 1e12, "tokens are token1 here");
        assertApproxEqRel(a0, 9_000 ether, 2e14);
        (a0, a1) = _positionAmounts(ids[1], pool);
        assertEq(a1, 0, "bid holds no tokens");
        assertGt(a0, 0);
        _buy(pool, token, USDT, attacker, 500 ether);
        assertGt(IERC20(token).balanceOf(attacker), 0);
    }

    function test_GraduateRequiresSellOut() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(1)));
        _pastWindow();
        _buyUsdt(token, trader, 1_000 ether);
        vm.expectRevert(CateFamilyCurveLaunchpad.CurveNotSoldOut.selector);
        launchpad.graduate(token);
    }

    // --------------------------------------------------------- post-graduation plumbing

    function test_HolderDistributorWorksOnAGraduatedCurve() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(1)));
        _sellOut(token, trader);
        (address pool, uint256[] memory ids) = launchpad.graduate(token);

        // A distributor registry pointed at the launchpad through the shared ABI.
        CateFamilyDistributorFactory df = new CateFamilyDistributorFactory(CateFamilyFactory(payable(address(launchpad))), keeper);
        address predicted = df.predict(token);
        vm.startPrank(creator);
        curveLocker.setCreatorFeeRecipient(ids[0], predicted);
        curveLocker.setCreatorFeeRecipient(ids[1], predicted);
        vm.stopPrank();
        CateFamilyHolderDistributor dist = CateFamilyHolderDistributor(df.create(token));
        assertEq(address(dist.locker()), address(curveLocker));
        dist.prepareOracle(64);
        for (uint256 i = 0; i < 8; i++) {
            _buy(pool, token, USDT, trader, 300 ether);
            _skip(60);
        }
        // Let the TWAP settle on the post-buy price before distributing.
        for (uint256 i = 0; i < 8; i++) {
            _skip(300);
            _buy(pool, token, USDT, trader, 1 ether);
        }
        vm.prank(keeper);
        (, uint256 burned) = dist.distribute(0);
        assertGt(burned, 0, "buy-back and burn ran against the graduated pool");
    }

    function test_ProtocolFeesGoToTheTreasury() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(1)));
        _sellOut(token, trader);
        launchpad.graduate(token);
        uint256 fees = launchpad.protocolFees(USDT);
        assertGt(fees, 0);
        launchpad.claimProtocolFees(USDT);
        assertEq(IERC20(USDT).balanceOf(treasury), fees);
        assertEq(launchpad.protocolFees(USDT), 0);
        vm.expectRevert(CateFamilyCurveLaunchpad.NothingToClaim.selector);
        launchpad.claimProtocolFees(USDT);
    }

    // ------------------------------------------------------------- governance

    function test_PauseStopsCreatesAndBuysButNeverSells() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(1)));
        _pastWindow();
        _buyUsdt(token, trader, 500 ether);
        vm.prank(owner);
        launchpad.setPaused(true);

        vm.prank(creator);
        vm.expectRevert(CateFamilyCurveLaunchpad.Paused.selector);
        launchpad.create(_params(USDT, OPEN_USD, GRAD_45K, bytes32(uint256(2))));
        deal(USDT, trader, 1 ether);
        vm.startPrank(trader);
        IERC20(USDT).approve(address(launchpad), 1 ether);
        vm.expectRevert(CateFamilyCurveLaunchpad.Paused.selector);
        launchpad.buy(token, 1 ether, 0);
        vm.stopPrank();

        uint256 out = _sellAll(token, trader);
        assertGt(out, 0, "sellers can always leave");
    }

    function test_ConfigAndQuoteChangesWaitTwoDays() public {
        CateFamilyCurveLaunchpad.Config memory next = CateFamilyCurveLaunchpad.Config({
            treasury: attacker, curveFeeBps: 300, graduationFeeBps: 1000, protocolLpFeeBps: 5000,
            openingWindowBlocks: 10, openingWalletCapBps: 100
        });
        vm.prank(owner);
        launchpad.scheduleConfig(next);
        (address t,,,,,) = launchpad.config();
        assertEq(t, treasury, "unchanged until applied");
        (, uint64 eta) = launchpad.pendingConfig();
        vm.expectRevert(abi.encodeWithSelector(CateFamilyCurveLaunchpad.ConfigNotReady.selector, eta));
        launchpad.applyConfig();
        vm.warp(eta);
        launchpad.applyConfig();
        (t,,,,,) = launchpad.config();
        assertEq(t, attacker);

        // Out-of-bounds is refused at schedule time.
        next.curveFeeBps = 301;
        vm.prank(owner);
        vm.expectRevert(CateFamilyCurveLaunchpad.ConfigOutOfBounds.selector);
        launchpad.scheduleConfig(next);

        // Quote allow-list follows the same delay.
        CateFamilyCurveLaunchpad.QuoteConfig memory q =
            CateFamilyCurveLaunchpad.QuoteConfig({allowed: true, minOpeningCap: 1 ether, minGraduationCap: 2 ether, maxGraduationCap: 1e30});
        vm.prank(owner);
        launchpad.scheduleQuoteConfig(CAKE, q);
        vm.prank(creator);
        vm.expectRevert(CateFamilyCurveLaunchpad.QuoteNotAllowed.selector);
        launchpad.create(_params(CAKE, 100 ether, 1_000 ether, bytes32(uint256(7))));
        vm.warp(vm.getBlockTimestamp() + launchpad.CONFIG_DELAY());
        launchpad.applyQuoteConfig(CAKE);
        vm.prank(creator);
        launchpad.create(_params(CAKE, 100 ether, 1_000 ether, bytes32(uint256(7))));

        vm.prank(owner);
        vm.expectRevert(CateFamilyCurveLaunchpad.RenounceDisabled.selector);
        launchpad.renounceOwnership();
    }
}
