// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurveTestBase} from "./CurveBase.t.sol";
import {CateFamilyCurveLaunchpad} from "../../src/CateFamilyCurveLaunchpad.sol";
import {CateFamilyCurveToken} from "../../src/CateFamilyCurveToken.sol";
import {TickMath} from "../../src/lib/TickMath.sol";
import {IPancakeV3Pool, INonfungiblePositionManager} from "../../src/interfaces/IPancakeV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math as MathLib} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Re-enters the launchpad from inside a native payout (a sell, or the
/// refund of an oversized buy). Records the result instead of reverting so the
/// outer call completes and the books can be checked.
contract ReentrantTrader {
    CateFamilyCurveLaunchpad internal immutable pad;
    address internal token;
    bytes internal payload;
    bool public fired;
    bool public callOk;
    bytes public result;

    constructor(CateFamilyCurveLaunchpad pad_) {
        pad = pad_;
    }

    function arm(address token_, bytes calldata payload_) external {
        token = token_;
        payload = payload_;
        fired = false;
    }

    function buy(uint256 amount) external payable {
        pad.buy{value: amount}(token, amount, 0);
    }

    function sellAll() external {
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).approve(address(pad), bal);
        pad.sell(token, bal, 0);
    }

    receive() external payable {
        if (!fired && payload.length > 0) {
            fired = true;
            (callOk, result) = address(pad).call{value: 0}(payload);
        }
    }
}

/// @notice The attacks the audit ran against the V3 factories, re-aimed at the
/// curve, plus the ones a custodial curve adds: draining the quote it holds,
/// bypassing the transfer lock, poisoning the graduation pool, re-entering
/// from payouts, and breaking the reserve invariants.
contract CurveAdversarialTest is CurveTestBase {
    bytes4 internal GUARD = ReentrancyGuard.ReentrancyGuardReentrantCall.selector;

    function _selector(bytes memory data) internal pure returns (bytes4 s) {
        assembly {
            s := mload(add(data, 32))
        }
    }

    // ------------------------------------------------------ pool poisoning

    function _poisonPool(address token, int24 canonicalTick) internal returns (address pool) {
        bool t0 = token < USDT;
        (address a, address b) = t0 ? (token, USDT) : (USDT, token);
        vm.prank(attacker);
        pool = INonfungiblePositionManager(POSITION_MANAGER)
            .createAndInitializePoolIfNecessary(a, b, 10000, TickMath.getSqrtRatioAtTick(t0 ? canonicalTick : -canonicalTick));
    }

    /// The pool address is knowable from the moment the curve exists. An
    /// attacker pre-creates it at a hostile price, above or below; the
    /// graduation restores it for free (the token exists, so both directions work).
    function test_PreCreatedPoolAtAHostilePriceIsRestoredAtGraduation() public {
        for (uint256 i = 0; i < 2; i++) {
            address token = _createUsdt(GRAD_45K, bytes32(uint256(100 + i)));
            _sellOut(token, trader);
            CateFamilyCurveLaunchpad.Curve memory c = launchpad.curves(token);
            int24 finalTick = TickMath.getTickAtSqrtRatio(uint160(_sqrtRatio(c, token)));
            address poisoned = _poisonPool(token, i == 0 ? finalTick + 30_000 : finalTick - 30_000);

            (address pool, uint256[] memory ids) = launchpad.graduate(token);
            assertEq(pool, poisoned, "graduated into the pre-created pool");
            (uint160 sqrtP,,,,,,) = IPancakeV3Pool(pool).slot0();
            assertEq(uint256(sqrtP), _sqrtRatio(c, token), "at exactly the curve's final price");
            assertEq(ids.length, 2);
        }
    }

    /// Quote-only liquidity parked below the target price cannot block the
    /// restore or the graduation; it just sits under the market as a bid.
    function test_ParkedQuoteBidBelowTheTargetIsHarmless() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(102)));
        _sellOut(token, trader);
        CateFamilyCurveLaunchpad.Curve memory c = launchpad.curves(token);
        int24 finalTick = TickMath.getTickAtSqrtRatio(uint160(_sqrtRatio(c, token)));
        bool t0 = token < USDT;
        address pool = _poisonPool(token, finalTick - 30_000);
        int24 lo = ((finalTick - 60_000) / 200) * 200;
        int24 hi = ((finalTick - 40_000) / 200) * 200;
        deal(USDT, attacker, 5_000 ether);
        vm.startPrank(attacker);
        IERC20(USDT).approve(POSITION_MANAGER, type(uint256).max);
        INonfungiblePositionManager(POSITION_MANAGER).mint(
            INonfungiblePositionManager.MintParams({
                token0: t0 ? token : USDT,
                token1: t0 ? USDT : token,
                fee: 10000,
                tickLower: t0 ? lo : -hi,
                tickUpper: t0 ? hi : -lo,
                amount0Desired: t0 ? 0 : 5_000 ether,
                amount1Desired: t0 ? 5_000 ether : 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: attacker,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        (address graduatedPool,) = launchpad.graduate(token);
        assertEq(graduatedPool, pool);
        (uint160 sqrtP,,,,,,) = IPancakeV3Pool(pool).slot0();
        assertEq(uint256(sqrtP), _sqrtRatio(c, token));
    }

    /// Nobody can put the token into the pool before graduation, so no
    /// pre-existing pair can ever hold token liquidity: the four.meme class.
    function test_NoTokenLiquidityCanExistBeforeGraduation() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(103)));
        _pastWindow();
        _buyUsdt(token, attacker, 1_000 ether);
        uint256 bal = IERC20(token).balanceOf(attacker);
        address pool = _poisonPool(token, -100_000);
        vm.startPrank(attacker);
        vm.expectRevert(CateFamilyCurveToken.NotLaunched.selector);
        IERC20(token).transfer(pool, bal);
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
                recipient: attacker,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(pool), 0);
    }

    // ---------------------------------------------------------- reentrancy

    function test_SellPayoutCannotReenterBuyOrSell() public {
        address token = _createBnb(bytes32(uint256(104)));
        _pastWindow();
        ReentrantTrader bot = new ReentrantTrader(launchpad);
        vm.deal(address(bot), 10 ether);
        bot.arm(token, "");
        bot.buy(1 ether);

        // Re-enter buy from inside the sell's native payout.
        bot.arm(token, abi.encodeCall(CateFamilyCurveLaunchpad.buy, (token, 0, 0)));
        uint256 before = address(bot).balance;
        bot.sellAll();
        assertTrue(bot.fired());
        assertFalse(bot.callOk());
        assertEq(_selector(bot.result()), GUARD);
        assertGt(address(bot).balance, before, "the sell itself paid out");
        assertEq(IERC20(token).balanceOf(address(bot)), 0);
    }

    function test_OversizedBuyRefundCannotReenter() public {
        address token = _createBnb(bytes32(uint256(105)));
        _pastWindow();
        ReentrantTrader bot = new ReentrantTrader(launchpad);
        vm.deal(address(bot), 1_000 ether);
        bot.arm(token, abi.encodeCall(CateFamilyCurveLaunchpad.sell, (token, 1, 0)));
        bot.buy(500 ether); // far more than the curve can absorb: refund path
        assertTrue(bot.fired(), "refund arrived and re-entry was attempted");
        assertFalse(bot.callOk());
        assertEq(_selector(bot.result()), GUARD);
        assertTrue(launchpad.curves(token).soldOut);
        assertEq(IERC20(token).balanceOf(address(bot)), launchpad.CURVE_SUPPLY());
        assertEq(address(launchpad).balance, 0, "no native dust in the launchpad");
    }

    // ------------------------------------------------------- custody invariants

    /// Random buys and sells across several wallets: the curve never owes
    /// more quote than it holds, never sells more than 800M, and k never
    /// decreases in the protocol's disfavour.
    function testFuzz_ReservesStayConsistent(uint256 seed) public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(106)));
        _pastWindow();
        address[3] memory wallets = [trader, attacker, makeAddr("w3")];
        vm.etch(wallets[2], "");
        uint256 k0 = launchpad.curves(token).k;
        for (uint256 i = 0; i < 24; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address w = wallets[r % 3];
            CateFamilyCurveLaunchpad.Curve memory c = launchpad.curves(token);
            if (c.soldOut) break;
            if (r % 5 < 3 || IERC20(token).balanceOf(w) == 0) {
                _buyUsdt(token, w, 1 ether + (r >> 8) % 3_000 ether);
            } else {
                uint256 part = IERC20(token).balanceOf(w) * ((r >> 16) % 100 + 1) / 100;
                vm.startPrank(w);
                IERC20(token).approve(address(launchpad), part);
                launchpad.sell(token, part, 0);
                vm.stopPrank();
            }
            c = launchpad.curves(token);
            assertGe(c.x * c.y, k0, "k never drops");
            assertEq(
                IERC20(USDT).balanceOf(address(launchpad)),
                c.quoteRaised + launchpad.protocolFees(USDT),
                "quote held == owed to sellers + fees"
            );
            assertEq(
                IERC20(token).balanceOf(address(launchpad)) - launchpad.POOL_SUPPLY(),
                c.tokensRemaining,
                "tokens held == remaining + pool reserve"
            );
            assertLe(launchpad.CURVE_SUPPLY() - c.tokensRemaining, launchpad.CURVE_SUPPLY());
        }
    }

    /// Selling the entire curve back after buying it returns the raise minus
    /// fees: the contract can always pay every seller.
    function test_EverySellerCanAlwaysBePaid() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(107)));
        _pastWindow();
        _buyUsdt(token, trader, 3_000 ether);
        _buyUsdt(token, attacker, 4_000 ether);
        uint256 held = IERC20(USDT).balanceOf(address(launchpad));
        uint256 out1 = _sellAll(token, attacker);
        uint256 out2 = _sellAll(token, trader);
        assertLe(out1 + out2, held, "paid out no more than it held");
        CateFamilyCurveLaunchpad.Curve memory c = launchpad.curves(token);
        assertEq(c.quoteRaised, 0);
        assertEq(IERC20(USDT).balanceOf(address(launchpad)), launchpad.protocolFees(USDT), "only fees remain");
    }

    /// Stray quote sent straight to the launchpad is never treated as a
    /// seller's money and never paid out.
    function test_DonationsDoNotChangeAnyonesEntitlement() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(108)));
        _pastWindow();
        _buyUsdt(token, trader, 1_000 ether);
        deal(USDT, attacker, 50_000 ether);
        vm.prank(attacker);
        IERC20(USDT).transfer(address(launchpad), 50_000 ether);
        uint256 out = _sellAll(token, trader);
        assertLt(out, 1_000 ether, "seller got their own money back, not the donation");
        assertEq(launchpad.curves(token).quoteRaised, 0);
    }

    // ----------------------------------------------------------- graduation timing

    /// Between sell-out and graduation nothing trades, and anyone can finish
    /// the job: the sold-out state cannot be held hostage.
    function test_SoldOutCurveIsFrozenUntilAnyoneGraduatesIt() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(109)));
        _sellOut(token, trader);
        _skip(7 days);
        vm.prank(attacker);
        launchpad.graduate(token);
        assertTrue(CateFamilyCurveToken(token).launched());
    }

    /// The owner cannot touch a curve's quote, its tokens, or its graduation.
    function test_OwnerHasNoPowerOverCurveFunds() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(110)));
        _pastWindow();
        _buyUsdt(token, trader, 1_000 ether);
        vm.startPrank(owner);
        launchpad.setPaused(true);
        // No function moves curve balances; the only outflow is claimProtocolFees, to the treasury.
        vm.stopPrank();
        uint256 fees = launchpad.protocolFees(USDT);
        launchpad.claimProtocolFees(USDT);
        assertEq(IERC20(USDT).balanceOf(treasury), fees);
        assertEq(IERC20(USDT).balanceOf(address(launchpad)), launchpad.curves(token).quoteRaised, "sellers' money untouched");
        _sellAll(token, trader);
    }

    // --------------------------------------------------------------- helpers

    function _sqrtRatio(CateFamilyCurveLaunchpad.Curve memory c, address token) internal pure returns (uint256) {
        bool t0 = token < USDT;
        uint256 ratioX192 = t0 ? _mulDiv(c.y, 1 << 192, c.x) : _mulDiv(c.x, 1 << 192, c.y);
        return _sqrtU(ratioX192);
    }

    function _mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return MathLib.mulDiv(a, b, d);
    }

    function _sqrtU(uint256 v) internal pure returns (uint256) {
        return MathLib.sqrt(v);
    }
}
