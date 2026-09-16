// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CateFamilyTestBase} from "./Base.t.sol";
import {CateFamilyFactory} from "../src/CateFamilyFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The parts of PancakeSwap's SmartRouter the app needs for multi-hop.
/// Declared here rather than added to src/interfaces, because no CateFamily
/// contract talks to the router — only the frontend does, and this test exists
/// to prove the calls it builds are the right ones.
interface ISmartRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
    function multicall(uint256 deadline, bytes[] calldata data) external payable returns (bytes[] memory);
    function unwrapWETH9(uint256 amountMinimum, address recipient) external payable;
}

/// @notice Buying a USDT-paired token with nothing but BNB.
///
/// The token page swaps with `exactInputSingle`, which is one hop by
/// construction — so a buyer holding only BNB cannot touch a USDT-paired
/// launch. These tests build exactly the calls the frontend will build, against
/// the real SmartRouter on a mainnet fork, because the two things most likely
/// to be wrong cannot be checked any other way: the packed path encoding, and
/// the recipient sentinel that decides where native proceeds land.
contract RouterPathTest is CateFamilyTestBase {
    ISmartRouter internal constant ROUTER = ISmartRouter(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);

    /// @dev The deepest WBNB/USDT tier on BSC. 0.01% and 0.05% are within a
    /// hair of each other; the app picks by liquidity at runtime.
    uint24 internal constant WBNB_USDT_FEE = 500;

    address internal buyer = makeAddr("bnb-only-buyer");

    function setUp() public override {
        super.setUp();
        vm.etch(buyer, "");
        // The whole premise: BNB and nothing else.
        vm.deal(buyer, 100 ether);
    }

    /// @dev `tokenIn ++ fee ++ tokenOut ++ fee ++ …`, the V3 path encoding.
    function _path2(address a, uint24 f1, address b, uint24 f2, address c) internal pure returns (bytes memory) {
        return abi.encodePacked(a, f1, b, f2, c);
    }

    function _launchUsdtToken(uint256 salt) internal returns (address token, address pool) {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(USDT, -122000);
        p.salt = bytes32(salt);
        vm.prank(creator);
        (token, pool,) = factory.launch(p);
        // Some depth, so a buy is priced sanely rather than sweeping the range.
        _buy(pool, token, USDT, trader, 5_000 ether);
    }

    // ------------------------------------------------- the premise itself

    /// Establishes the problem before the fix: the buyer holds no USDT, and the
    /// single-hop call the page makes today has nothing to spend.
    function test_ABnbOnlyBuyerHasNothingToSwapToday() public {
        (address token,) = _launchUsdtToken(1);

        assertEq(IERC20(USDT).balanceOf(buyer), 0, "no USDT, by construction");
        assertGt(buyer.balance, 0, "but plenty of BNB");
        assertEq(IERC20(token).balanceOf(buyer), 0, "and no way to get the token");
    }

    // ------------------------------------------------------ buying with BNB

    /// The fix, end to end: one call, native value, no approval anywhere.
    function test_BuyingWithNativeBnbThroughTwoHops() public {
        (address token,) = _launchUsdtToken(2);

        uint256 spend = 1 ether;
        bytes memory path = _path2(WBNB, WBNB_USDT_FEE, USDT, FEE_1PCT, token);

        vm.prank(buyer);
        uint256 out = ROUTER.exactInput{value: spend}(
            ISmartRouter.ExactInputParams({path: path, recipient: buyer, amountIn: spend, amountOutMinimum: 1})
        );

        assertGt(out, 0, "the router returned an amount");
        assertEq(IERC20(token).balanceOf(buyer), out, "and the buyer holds it");
        assertEq(IERC20(USDT).balanceOf(buyer), 0, "USDT was never held, only passed through");
        assertEq(buyer.balance, 100 ether - spend, "exactly the BNB they meant to spend");
    }

    /// No ERC20 approval is involved when paying natively — the router wraps
    /// `msg.value` itself. That is one signature instead of two, and it is why
    /// the buy path must NOT run its allowance check in this case.
    function test_NativeBuyNeedsNoApproval() public {
        (address token,) = _launchUsdtToken(3);

        assertEq(IERC20(WBNB).allowance(buyer, address(ROUTER)), 0, "no WBNB approval");
        assertEq(IERC20(USDT).allowance(buyer, address(ROUTER)), 0, "no USDT approval");

        bytes memory path = _path2(WBNB, WBNB_USDT_FEE, USDT, FEE_1PCT, token);
        vm.prank(buyer);
        ROUTER.exactInput{value: 1 ether}(
            ISmartRouter.ExactInputParams({path: path, recipient: buyer, amountIn: 1 ether, amountOutMinimum: 1})
        );

        assertGt(IERC20(token).balanceOf(buyer), 0, "bought with no approval at all");
    }

    /// The slippage floor is enforced across the WHOLE path, not per hop. A
    /// floor above what the route can deliver must revert rather than partially
    /// fill — which is what makes `minOut` worth computing properly.
    function test_TheFloorAppliesToTheWholeRoute() public {
        (address token,) = _launchUsdtToken(4);
        bytes memory path = _path2(WBNB, WBNB_USDT_FEE, USDT, FEE_1PCT, token);

        vm.prank(buyer);
        uint256 fair = ROUTER.exactInput{value: 0.1 ether}(
            ISmartRouter.ExactInputParams({path: path, recipient: buyer, amountIn: 0.1 ether, amountOutMinimum: 1})
        );

        vm.prank(buyer);
        vm.expectRevert();
        ROUTER.exactInput{value: 0.1 ether}(
            ISmartRouter.ExactInputParams({
                path: path,
                recipient: buyer,
                amountIn: 0.1 ether,
                amountOutMinimum: fair * 2 // unreachable
            })
        );
    }

    /// The frontend does not call `exactInput` bare — it wraps every swap in
    /// `multicall(deadline, …)`, because `exactInput` has no deadline field and
    /// that overload is the only place to put one.
    ///
    /// Worth its own test: multicall runs its calls by DELEGATECALL, so
    /// `msg.value` is visible to each of them. That is what makes a native buy
    /// work inside a multicall, and it is also why two value-spending calls in
    /// one multicall would double-count. One swap, one value, is the shape.
    function test_ANativeBuyWorksInsideAMulticall() public {
        (address token,) = _launchUsdtToken(7);

        uint256 spend = 1 ether;
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            ISmartRouter.exactInput,
            (ISmartRouter.ExactInputParams({
                    path: _path2(WBNB, WBNB_USDT_FEE, USDT, FEE_1PCT, token),
                    recipient: buyer,
                    amountIn: spend,
                    amountOutMinimum: 1
                }))
        );

        vm.prank(buyer);
        ROUTER.multicall{value: spend}(block.timestamp + 120, calls);

        assertGt(IERC20(token).balanceOf(buyer), 0, "bought through the multicall");
        assertEq(buyer.balance, 100 ether - spend, "and spent exactly the value sent");
    }

    /// A stale deadline must stop the trade. The app had no deadline anywhere
    /// before this, so a transaction stuck in the mempool could execute at any
    /// price, whenever it happened to be mined.
    function test_AnExpiredDeadlineRejectsTheSwap() public {
        (address token,) = _launchUsdtToken(8);

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            ISmartRouter.exactInput,
            (ISmartRouter.ExactInputParams({
                    path: _path2(WBNB, WBNB_USDT_FEE, USDT, FEE_1PCT, token),
                    recipient: buyer,
                    amountIn: 1 ether,
                    amountOutMinimum: 1
                }))
        );

        vm.prank(buyer);
        vm.expectRevert();
        ROUTER.multicall{value: 1 ether}(block.timestamp - 1, calls);
    }

    // ----------------------------------------------- selling back to BNB

    /// THE SENTINEL QUESTION, settled by running it.
    ///
    /// To return native BNB the router must keep the WBNB itself and then
    /// unwrap it, so `exactInput`'s recipient is not the user. SwapRouter02
    /// forks use an `ADDRESS_THIS` constant rather than the literal router
    /// address, and picking the wrong one sends the proceeds somewhere
    /// unrecoverable. This asserts which value actually works.
    function test_SellingToNativeBnbUsesTheAddressThisSentinel() public {
        (address token,) = _launchUsdtToken(5);

        // Buy in first, so the seller has something to sell and still holds
        // no USDT — the native balance change is then unambiguous.
        vm.prank(buyer);
        ROUTER.exactInput{value: 2 ether}(
            ISmartRouter.ExactInputParams({
                path: _path2(WBNB, WBNB_USDT_FEE, USDT, FEE_1PCT, token),
                recipient: buyer,
                amountIn: 2 ether,
                amountOutMinimum: 1
            })
        );
        uint256 held = IERC20(token).balanceOf(buyer);
        assertGt(held, 0, "seller has something to sell");

        bytes memory sellPath = _path2(token, FEE_1PCT, USDT, WBNB_USDT_FEE, WBNB);

        vm.startPrank(buyer);
        IERC20(token).approve(address(ROUTER), type(uint256).max);

        uint256 nativeBefore = buyer.balance;
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            ISmartRouter.exactInput,
            (ISmartRouter.ExactInputParams({
                    path: sellPath,
                    // address(2) == ADDRESS_THIS in SwapRouter02 and its forks.
                    recipient: address(2),
                    amountIn: held,
                    amountOutMinimum: 1
                }))
        );
        calls[1] = abi.encodeCall(ISmartRouter.unwrapWETH9, (1, buyer));
        ROUTER.multicall(block.timestamp + 300, calls);
        vm.stopPrank();

        assertGt(buyer.balance, nativeBefore, "native BNB reached the seller");
        assertEq(IERC20(token).balanceOf(buyer), 0, "and the tokens are gone");
        assertEq(IERC20(WBNB).balanceOf(buyer), 0, "as BNB, not left wrapped");
    }

    /// And the negative, so the test above is about the sentinel rather than
    /// about multicall working at all: naming the USER as the swap recipient
    /// hands them WBNB, leaving the router with nothing to unwrap. The whole
    /// call reverts — which is the good outcome, but only because `unwrapWETH9`
    /// happens to check. It is not a value to guess at.
    function test_NamingTheUserAsRecipientBreaksTheUnwrap() public {
        (address token,) = _launchUsdtToken(6);

        vm.prank(buyer);
        ROUTER.exactInput{value: 2 ether}(
            ISmartRouter.ExactInputParams({
                path: _path2(WBNB, WBNB_USDT_FEE, USDT, FEE_1PCT, token),
                recipient: buyer,
                amountIn: 2 ether,
                amountOutMinimum: 1
            })
        );
        uint256 held = IERC20(token).balanceOf(buyer);

        vm.startPrank(buyer);
        IERC20(token).approve(address(ROUTER), type(uint256).max);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            ISmartRouter.exactInput,
            (ISmartRouter.ExactInputParams({
                    path: _path2(token, FEE_1PCT, USDT, WBNB_USDT_FEE, WBNB),
                    recipient: buyer, // WRONG: the router keeps nothing to unwrap
                    amountIn: held,
                    amountOutMinimum: 1
                }))
        );
        calls[1] = abi.encodeCall(ISmartRouter.unwrapWETH9, (1, buyer));

        vm.expectRevert();
        ROUTER.multicall(block.timestamp + 300, calls);
        vm.stopPrank();
    }
}
