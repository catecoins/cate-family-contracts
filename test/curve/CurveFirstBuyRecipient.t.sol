// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurveTestBase} from "./CurveBase.t.sol";
import {CateFamilyCurveLaunchpad} from "../../src/CateFamilyCurveLaunchpad.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// A platform launching on a client's behalf: the platform key pays for the
/// first buy, the client receives the tokens and the fee stream, and the
/// tokens are counted against the client under the opening-window rules.
contract CurveFirstBuyRecipientTest is CurveTestBase {
    address internal client = makeAddr("client");

    function test_FirstBuyTokensGoToTheNamedRecipient() public {
        CateFamilyCurveLaunchpad.CreateParams memory p = _params(USDT, OPEN_USD, GRAD_45K, bytes32(uint256(0xF1)));
        p.firstBuyQuote = 300 ether;
        p.firstBuyRecipient = client;
        p.creatorFeeRecipient = client;
        deal(USDT, creator, 300 ether);
        vm.startPrank(creator);
        IERC20(USDT).approve(address(launchpad), 300 ether);
        address token = launchpad.create(p);
        vm.stopPrank();

        assertGt(IERC20(token).balanceOf(client), 0, "client holds the first buy");
        assertEq(IERC20(token).balanceOf(creator), 0, "the paying key holds none of it");
        CateFamilyCurveLaunchpad.Curve memory c = launchpad.curves(token);
        assertEq(c.creator, creator, "the sender is still the on-chain creator");
        assertEq(c.creatorFeeRecipient, client, "fees go to the client");
        assertEq(IERC20(USDT).balanceOf(creator), 0, "the payer paid");
    }

    function test_RefundOfAnOversizedFirstBuyGoesToThePayer() public {
        // More quote than the whole curve costs: the recipient gets the whole
        // curve, the payer gets the unused quote back, the curve is sold out.
        CateFamilyCurveLaunchpad.CreateParams memory p = _params(USDT, OPEN_USD, GRAD_45K, bytes32(uint256(0xF2)));
        p.firstBuyQuote = 50_000 ether;
        p.firstBuyRecipient = client;
        deal(USDT, creator, 50_000 ether);
        vm.startPrank(creator);
        IERC20(USDT).approve(address(launchpad), 50_000 ether);
        address token = launchpad.create(p);
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(client), launchpad.CURVE_SUPPLY(), "the recipient holds the whole curve");
        assertEq(IERC20(token).balanceOf(creator), 0, "the payer holds none");
        uint256 refund = IERC20(USDT).balanceOf(creator);
        assertGt(refund, 0, "the unused quote came back to the payer");
        assertEq(IERC20(USDT).balanceOf(client), 0, "and not to the recipient");
        assertTrue(launchpad.curves(token).soldOut);
    }

    function test_RecipientIsStillCappedInTheWindowAsAPublicBuyer() public {
        // The client got 10% of the curve at creation; inside the window their
        // own public buys are measured against what they already hold.
        CateFamilyCurveLaunchpad.CreateParams memory p = _params(USDT, OPEN_USD, GRAD_45K, bytes32(uint256(0xF3)));
        p.firstBuyQuote = 400 ether;
        p.firstBuyRecipient = client;
        deal(USDT, creator, 400 ether);
        vm.startPrank(creator);
        IERC20(USDT).approve(address(launchpad), 400 ether);
        address token = launchpad.create(p);
        vm.stopPrank();
        deal(USDT, client, 100 ether);
        vm.startPrank(client, client);
        IERC20(USDT).approve(address(launchpad), 100 ether);
        vm.expectRevert();
        launchpad.buy(token, 100 ether, 0);
        vm.stopPrank();
    }

    function test_PublicBuysAlwaysPayTheBuyer() public {
        address token = _createUsdt(GRAD_45K, bytes32(uint256(0xF4)));
        _pastWindow();
        _buyUsdt(token, trader, 100 ether);
        assertGt(IERC20(token).balanceOf(trader), 0);
    }
}
