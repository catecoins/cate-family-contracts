// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CateFamilyTestBase} from "../Base.t.sol";
import {CateFamilyCurveLaunchpad} from "../../src/CateFamilyCurveLaunchpad.sol";
import {CateFamilyCurveToken} from "../../src/CateFamilyCurveToken.sol";
import {CateFamilyLiquidityLocker} from "../../src/CateFamilyLiquidityLocker.sol";
import {IPancakeV3Factory, IPancakeV3Pool, INonfungiblePositionManager} from "../../src/interfaces/IPancakeV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "../../src/lib/TickMath.sol";

/// @notice Scaffolding for the bonding-curve suite. Deploys a CateFamilyCurveLaunchpad on
/// the BSC fork with WBNB and USDT allow-listed and the proposed defaults:
/// 1% curve fee, 5% graduation cut, 80/20 LP split, 40-block opening window,
/// 2% per-wallet cap.
abstract contract CurveTestBase is CateFamilyTestBase {
    CateFamilyCurveLaunchpad internal launchpad;
    CateFamilyLiquidityLocker internal curveLocker;

    uint256 internal constant OPEN_USD = 5_000 ether; // $5,000 in USDT wei
    uint256 internal constant GRAD_25K = 25_000 ether;
    uint256 internal constant GRAD_45K = 45_000 ether;
    uint256 internal constant GRAD_69K = 69_000 ether;
    /// @dev BNB-denominated caps for the native path (BNB ≈ $727 at audit time).
    uint256 internal constant OPEN_BNB = 6.88 ether;
    uint256 internal constant GRAD_BNB_45K = 61.9 ether;

    address internal attacker = makeAddr("curve-attacker");

    function setUp() public virtual override {
        super.setUp();
        CateFamilyCurveLaunchpad.Config memory cfg = CateFamilyCurveLaunchpad.Config({
            treasury: treasury,
            curveFeeBps: 100,
            graduationFeeBps: 500,
            protocolLpFeeBps: 2000,
            openingWindowBlocks: 40,
            openingWalletCapBps: 200
        });
        address[] memory quotes = new address[](2);
        quotes[0] = WBNB;
        quotes[1] = USDT;
        CateFamilyCurveLaunchpad.QuoteConfig[] memory qc = new CateFamilyCurveLaunchpad.QuoteConfig[](2);
        qc[0] = CateFamilyCurveLaunchpad.QuoteConfig({
            allowed: true, minOpeningCap: 1 ether, minGraduationCap: 5 ether, maxGraduationCap: 2_000 ether
        });
        qc[1] = CateFamilyCurveLaunchpad.QuoteConfig({
            allowed: true,
            minOpeningCap: 1_000 ether,
            minGraduationCap: 5_000 ether,
            maxGraduationCap: 1_000_000 ether
        });
        launchpad = new CateFamilyCurveLaunchpad(
            IPancakeV3Factory(PANCAKE_V3_FACTORY),
            INonfungiblePositionManager(POSITION_MANAGER),
            WBNB,
            owner,
            cfg,
            quotes,
            qc
        );
        curveLocker = launchpad.locker();
        vm.etch(attacker, "");
        vm.deal(attacker, 1_000 ether);
        vm.label(address(launchpad), "CateFamilyCurveLaunchpad");
    }

    // ------------------------------------------------------------- helpers

    function _skip(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + (secs * 4) / 3);
    }

    function _pastWindow() internal {
        vm.roll(vm.getBlockNumber() + 41);
    }

    function _params(address quote, uint256 openingCap, uint256 graduationCap, bytes32 salt)
        internal
        pure
        returns (CateFamilyCurveLaunchpad.CreateParams memory p)
    {
        p.name = "Curve Test";
        p.symbol = "CRV";
        p.metadataURI = "";
        p.quoteToken = quote;
        p.openingCap = openingCap;
        p.graduationCap = graduationCap;
        p.creatorFeeRecipient = address(0);
        p.firstBuyQuote = 0;
        p.firstBuyMinTokensOut = 0;
        p.firstBuyRecipient = address(0);
        p.salt = salt;
    }

    function _createUsdt(uint256 graduationCap, bytes32 salt) internal returns (address token) {
        vm.prank(creator);
        token = launchpad.create(_params(USDT, OPEN_USD, graduationCap, salt));
    }

    function _createBnb(bytes32 salt) internal returns (address token) {
        vm.prank(creator);
        token = launchpad.create(_params(WBNB, OPEN_BNB, GRAD_BNB_45K, salt));
    }

    /// @dev Buys with USDT; deals exactly `amount` to the buyer first.
    function _buyUsdt(address token, address buyer, uint256 amount) internal returns (uint256 out) {
        deal(USDT, buyer, amount);
        vm.startPrank(buyer, buyer); // an EOA: tx.origin == msg.sender inside the opening window
        IERC20(USDT).approve(address(launchpad), amount);
        out = launchpad.buy(token, amount, 0);
        vm.stopPrank();
    }

    function _buyBnb(address token, address buyer, uint256 amount) internal returns (uint256 out) {
        vm.deal(buyer, buyer.balance + amount);
        vm.prank(buyer, buyer);
        out = launchpad.buy{value: amount}(token, amount, 0);
    }

    function _sellAll(address token, address seller) internal returns (uint256 out) {
        uint256 bal = IERC20(token).balanceOf(seller);
        vm.startPrank(seller);
        IERC20(token).approve(address(launchpad), bal);
        out = launchpad.sell(token, bal, 0);
        vm.stopPrank();
    }

    /// @dev One oversized buy after the window sells the curve out; returns
    /// what the buyer was actually charged.
    function _sellOut(address token, address buyer) internal returns (uint256 charged) {
        _pastWindow();
        CateFamilyCurveLaunchpad.Curve memory c = launchpad.curves(token);
        uint256 budget = c.quoteToken == WBNB ? 10_000 ether : 10_000_000 ether;
        if (c.quoteToken == WBNB) {
            uint256 before = buyer.balance + budget;
            _buyBnb(token, buyer, budget);
            charged = before - buyer.balance;
        } else {
            _buyUsdt(token, buyer, budget);
            charged = budget - IERC20(USDT).balanceOf(buyer);
        }
    }

    function _positionAmounts(uint256 id, address pool) internal view returns (uint256 amount0, uint256 amount1) {
        (,,,,, int24 lower, int24 upper, uint128 liq,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(id);
        (uint160 sqrtP,,,,,,) = IPancakeV3Pool(pool).slot0();
        // Rough amounts from liquidity for assertions (Uniswap LiquidityAmounts maths).
        uint160 sqrtA = _sqrt(lower);
        uint160 sqrtB = _sqrt(upper);
        if (sqrtP <= sqrtA) {
            amount0 = _amt0(sqrtA, sqrtB, liq);
        } else if (sqrtP < sqrtB) {
            amount0 = _amt0(sqrtP, sqrtB, liq);
            amount1 = _amt1(sqrtA, sqrtP, liq);
        } else {
            amount1 = _amt1(sqrtA, sqrtB, liq);
        }
    }

    function _sqrt(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    function _amt0(uint160 sqrtA, uint160 sqrtB, uint128 liq) internal pure returns (uint256) {
        return Math.mulDiv(uint256(liq) << 96, sqrtB - sqrtA, sqrtB) / sqrtA;
    }

    function _amt1(uint160 sqrtA, uint160 sqrtB, uint128 liq) internal pure returns (uint256) {
        return uint256(liq) * (sqrtB - sqrtA) / (1 << 96);
    }
}
