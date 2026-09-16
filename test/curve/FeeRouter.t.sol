// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurveTestBase} from "./CurveBase.t.sol";
import {CateFamilyFeeRouter, ISmartRouter} from "../../src/CateFamilyFeeRouter.sol";
import {CateFamilyLiquidityLocker} from "../../src/CateFamilyLiquidityLocker.sol";
import {IWBNB} from "../../src/interfaces/IPancakeV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The site's post-graduation fee: 1% of the quote side of every trade
/// routed through the platform, split 70/30 creator/treasury, on top of
/// whatever PancakeSwap charges inside the pool.
contract FeeRouterTest is CurveTestBase {
    address internal constant SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    uint24 internal constant POOL_FEE = 10_000;

    CateFamilyFeeRouter internal router;
    address internal trader2 = makeAddr("router-trader");

    function setUp() public override {
        super.setUp();
        CateFamilyLiquidityLocker[] memory lockers = new CateFamilyLiquidityLocker[](1);
        lockers[0] = curveLocker;
        router = new CateFamilyFeeRouter(
            ISmartRouter(SMART_ROUTER),
            IWBNB(WBNB),
            owner,
            CateFamilyFeeRouter.Config({treasury: treasury, feeBps: 100, creatorShareBps: 7000}),
            lockers
        );
        vm.deal(trader2, 100 ether);
        vm.label(address(router), "FeeRouter");
    }

    function _graduatedBnb() internal returns (address token) {
        token = _createBnb(keccak256("router-bnb"));
        _sellOut(token, trader);
        launchpad.graduate(token);
    }

    function _graduatedUsdt() internal returns (address token) {
        token = _createUsdt(GRAD_25K, keccak256("router-usdt"));
        _sellOut(token, trader);
        launchpad.graduate(token);
    }

    function _path(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, POOL_FEE, b);
    }

    function test_BuyWithNativeChargesOnePercentSplitSeventyThirty() public {
        address token = _graduatedBnb();
        uint256 creatorBefore = creator.balance;
        uint256 treasuryBefore = treasury.balance;

        vm.prank(trader2);
        uint256 out = router.buy{value: 1 ether}(token, _path(WBNB, token), 1 ether, 0, block.timestamp + 60);

        assertGt(out, 0, "tokens out");
        assertEq(IERC20(token).balanceOf(trader2), out, "tokens delivered to the buyer");
        assertEq(creator.balance - creatorBefore, 0.007 ether, "creator gets 70% of 1%");
        assertEq(treasury.balance - treasuryBefore, 0.003 ether, "treasury gets 30% of 1%");
        assertEq(address(router).balance, 0, "router keeps nothing");
        assertEq(IERC20(WBNB).balanceOf(address(router)), 0, "router keeps no WBNB");
    }

    function test_SellUnwrapsToNativeAndChargesOnTheWayOut() public {
        address token = _graduatedBnb();
        vm.prank(trader2);
        uint256 got = router.buy{value: 1 ether}(token, _path(WBNB, token), 1 ether, 0, block.timestamp + 60);

        uint256 creatorBefore = creator.balance;
        uint256 treasuryBefore = treasury.balance;
        uint256 traderBefore = trader2.balance;

        vm.startPrank(trader2);
        IERC20(token).approve(address(router), got);
        uint256 net = router.sell(token, _path(token, WBNB), got, 0, block.timestamp + 60, true);
        vm.stopPrank();

        uint256 creatorFee = creator.balance - creatorBefore;
        uint256 protocolFee = treasury.balance - treasuryBefore;
        uint256 gross = net + creatorFee + protocolFee;
        assertEq(trader2.balance - traderBefore, net, "seller paid in native BNB");
        assertEq(creatorFee + protocolFee, gross / 100, "1% of the gross quote");
        assertEq(creatorFee, (gross / 100) * 7000 / 10_000, "70% of the fee to the creator");
        assertEq(IERC20(token).balanceOf(address(router)), 0, "router keeps no tokens");
        assertEq(address(router).balance, 0, "router keeps no BNB");
    }

    function test_BuyAndSellInUsdtPayFeesInUsdt() public {
        address token = _graduatedUsdt();
        deal(USDT, trader2, 1_000 ether);
        uint256 creatorBefore = IERC20(USDT).balanceOf(creator);

        vm.startPrank(trader2);
        IERC20(USDT).approve(address(router), 1_000 ether);
        uint256 got = router.buy(token, _path(USDT, token), 1_000 ether, 0, block.timestamp + 60);
        assertEq(IERC20(USDT).balanceOf(creator) - creatorBefore, 7 ether, "7 USDT of a 1,000 USDT buy");
        assertEq(IERC20(USDT).balanceOf(treasury), 3 ether, "3 USDT to the treasury");

        IERC20(token).approve(address(router), got);
        uint256 usdtBefore = IERC20(USDT).balanceOf(trader2);
        uint256 net = router.sell(token, _path(token, USDT), got, 0, block.timestamp + 60, false);
        vm.stopPrank();
        assertEq(IERC20(USDT).balanceOf(trader2) - usdtBefore, net, "net USDT to the seller");
        assertEq(IERC20(USDT).balanceOf(address(router)), 0, "router keeps nothing");
    }

    function test_SlippageIsCheckedOnTheNetAmount() public {
        address token = _graduatedBnb();
        vm.prank(trader2);
        uint256 got = router.buy{value: 1 ether}(token, _path(WBNB, token), 1 ether, 0, block.timestamp + 60);
        vm.startPrank(trader2);
        IERC20(token).approve(address(router), got);
        vm.expectRevert();
        router.sell(token, _path(token, WBNB), got, type(uint256).max, block.timestamp + 60, true);
        vm.stopPrank();
    }

    function test_UnknownTokenAndBadPathRevert() public {
        address token = _graduatedBnb();
        vm.startPrank(trader2);
        vm.expectRevert(abi.encodeWithSelector(CateFamilyFeeRouter.UnknownToken.selector, USDT));
        router.buy{value: 1 ether}(USDT, _path(WBNB, USDT), 1 ether, 0, block.timestamp + 60);
        // Path must end at the token being bought.
        vm.expectRevert(CateFamilyFeeRouter.BadPath.selector);
        router.buy{value: 1 ether}(token, _path(WBNB, USDT), 1 ether, 0, block.timestamp + 60);
        // Native value must match amountIn.
        vm.expectRevert(CateFamilyFeeRouter.WrongValue.selector);
        router.buy{value: 0.5 ether}(token, _path(WBNB, token), 1 ether, 0, block.timestamp + 60);
        vm.expectRevert(CateFamilyFeeRouter.DeadlinePassed.selector);
        router.buy{value: 1 ether}(token, _path(WBNB, token), 1 ether, 0, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_ConfigWaitsFortyEightHoursAndIsCapped() public {
        CateFamilyFeeRouter.Config memory next =
            CateFamilyFeeRouter.Config({treasury: treasury, feeBps: 200, creatorShareBps: 5000});
        vm.prank(owner);
        router.scheduleConfig(next);
        vm.expectRevert();
        router.applyConfig();
        _skip(48 hours + 1);
        router.applyConfig();
        (, uint16 feeBps, uint16 share) = router.config();
        assertEq(feeBps, 200);
        assertEq(share, 5000);

        vm.prank(owner);
        vm.expectRevert(CateFamilyFeeRouter.ConfigOutOfBounds.selector);
        router.scheduleConfig(CateFamilyFeeRouter.Config({treasury: treasury, feeBps: 301, creatorShareBps: 7000}));

        vm.prank(trader2);
        vm.expectRevert();
        router.scheduleConfig(next);
    }

    function test_PausedRefusesRouting() public {
        address token = _graduatedBnb();
        vm.prank(owner);
        router.setPaused(true);
        vm.prank(trader2);
        vm.expectRevert(CateFamilyFeeRouter.Paused.selector);
        router.buy{value: 1 ether}(token, _path(WBNB, token), 1 ether, 0, block.timestamp + 60);
    }

    function test_CreatorRecipientIsTheLockerRecord() public {
        address token = _graduatedBnb();
        assertEq(router.creatorRecipientOf(token), creator);
        assertEq(router.creatorRecipientOf(USDT), address(0));
    }
}
