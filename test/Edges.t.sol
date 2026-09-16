// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CateFamilyTestBase, DummyERC20} from "./Base.t.sol";
import {CateFamilyFactory} from "../src/CateFamilyFactory.sol";
import {CateFamilyLiquidityLocker} from "../src/CateFamilyLiquidityLocker.sol";
import {IPancakeV3Pool} from "../src/interfaces/IPancakeV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A contract that launches but cannot be paid back. The initial-buy
/// refund is a raw `call` to `msg.sender`, so a launcher whose `receive`
/// reverts hits a path an EOA never can.
contract RefusingLauncher {
    CateFamilyFactory public immutable factory;

    constructor(CateFamilyFactory factory_) {
        factory = factory_;
    }

    function launch(CateFamilyFactory.LaunchParams memory p) external payable returns (address token) {
        (token,,) = factory.launch{value: msg.value}(p);
    }

    receive() external payable {
        revert("no refunds");
    }
}

/// @notice The boundaries of `_validate`, the shapes it lets through, and the
/// paths that only a contract caller can reach.
///
/// The suite already covers the happy paths and the obviously-wrong inputs. What
/// is left is the edge exactly ON each limit, and the inputs that are *legal but
/// strange* — overlapping ranges, gaps, ten positions — where the interesting
/// question is not "does it revert" but "does it do something sane".
contract EdgesTest is CateFamilyTestBase {
    int24 internal constant START = -122000;
    int24 internal constant SPACING = 200;

    function _p(bytes32 salt) internal pure returns (CateFamilyFactory.LaunchParams memory p) {
        p = _defaultParams(USDT, START);
        p.salt = salt;
    }

    /// @dev The pool's raw tick runs backwards when the launched token sorts
    /// second, so every assertion about price has to mirror it first. Same
    /// hazard `GraduationTest` is built around — and it bit these tests on
    /// their first run, which is why it is a helper rather than a comment.
    function _canonicalTick(address pool, address token) internal view returns (int24) {
        (, int24 raw,,,,,) = IPancakeV3Pool(pool).slot0();
        return IPancakeV3Pool(pool).token0() == token ? raw : -raw;
    }

    function _pos(int24 lower, int24 upper, uint16 bps)
        internal
        pure
        returns (CateFamilyFactory.LiquidityPosition memory)
    {
        return CateFamilyFactory.LiquidityPosition({tickLower: lower, tickUpper: upper, bps: bps});
    }

    // ------------------------------------------------ position-count edge

    /// Exactly MAX_POSITIONS. The bound is `> MAX_POSITIONS`, so ten must work
    /// — and it must work on a real fork, where the gas cost of ten mints plus
    /// ten `assignPosition` writes is the thing that actually decides it.
    function test_TenPositionsIsAllowed() public {
        CateFamilyFactory.LaunchParams memory p = _p(bytes32(uint256(1)));
        p.positions = new CateFamilyFactory.LiquidityPosition[](10);
        for (uint16 i = 0; i < 10; i++) {
            int24 lo = START + int24(uint24(i)) * 2000;
            p.positions[i] = _pos(lo, lo + 2000, 1000);
        }

        vm.prank(creator);
        (address token,, uint256[] memory ids) = factory.launch(p);
        assertEq(ids.length, 10, "all ten minted");
        assertEq(locker.positionsOf(token).length, 10, "all ten routed for fees");
        assertEq(IERC20(token).balanceOf(address(factory)), 0, "supply fully placed");
    }

    function test_ElevenPositionsIsRejected() public {
        CateFamilyFactory.LaunchParams memory p = _p(bytes32(uint256(2)));
        p.positions = new CateFamilyFactory.LiquidityPosition[](11);
        for (uint16 i = 0; i < 11; i++) {
            int24 lo = START + int24(uint24(i)) * 2000;
            p.positions[i] = _pos(lo, lo + 2000, i == 10 ? 1000 : 900);
        }

        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidPositions.selector);
        factory.launch(p);
    }

    // -------------------------------------------------- malformed ranges

    function test_ZeroWidthRangeIsRejected() public {
        CateFamilyFactory.LaunchParams memory p = _p(bytes32(uint256(3)));
        p.positions = new CateFamilyFactory.LiquidityPosition[](1);
        p.positions[0] = _pos(START, START, 10000);

        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidPositions.selector);
        factory.launch(p);
    }

    function test_InvertedRangeIsRejected() public {
        CateFamilyFactory.LaunchParams memory p = _p(bytes32(uint256(4)));
        p.positions = new CateFamilyFactory.LiquidityPosition[](1);
        p.positions[0] = _pos(START + 2000, START, 10000);

        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidPositions.selector);
        factory.launch(p);
    }

    /// A range starting BELOW the opening price would need quote tokens to
    /// mint, which the factory does not have — so this is rejected up front
    /// rather than failing deep inside the position manager with an opaque
    /// error. It is also what keeps every launch single-sided.
    function test_RangeBelowTheOpeningPriceIsRejected() public {
        CateFamilyFactory.LaunchParams memory p = _p(bytes32(uint256(5)));
        p.positions = new CateFamilyFactory.LiquidityPosition[](1);
        p.positions[0] = _pos(START - 2000, START + 2000, 10000);

        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidPositions.selector);
        factory.launch(p);
    }

    function test_ZeroBpsIsRejected() public {
        CateFamilyFactory.LaunchParams memory p = _p(bytes32(uint256(6)));
        p.positions = new CateFamilyFactory.LiquidityPosition[](2);
        p.positions[0] = _pos(START, START + 2000, 0);
        p.positions[1] = _pos(START + 2000, START + 4000, 10000);

        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidBps.selector);
        factory.launch(p);
    }

    // ------------------------------------------- legal but strange shapes

    /// Overlapping ranges are NOT rejected, and should not be: V3 layers them
    /// and the result is simply deeper liquidity where they cross. Pinning that
    /// the whole supply still lands and the pool still opens at the right price,
    /// since the alternative — silently dropping one — would be invisible.
    function test_OverlappingRangesAreAcceptedAndPlaceTheWholeSupply() public {
        CateFamilyFactory.LaunchParams memory p = _p(bytes32(uint256(7)));
        p.positions = new CateFamilyFactory.LiquidityPosition[](2);
        p.positions[0] = _pos(START, START + 6000, 5000);
        p.positions[1] = _pos(START + 2000, START + 8000, 5000);

        vm.prank(creator);
        (address token, address pool, uint256[] memory ids) = factory.launch(p);

        assertEq(ids.length, 2);
        assertEq(IERC20(token).balanceOf(address(factory)), 0, "nothing left behind");
        assertEq(_canonicalTick(pool, token), START, "opens at the requested price regardless");
    }

    /// A gap between ranges is legal too, and means the price crosses a band
    /// with no liquidity at all — a buy walks straight through it in one step.
    /// Strange, but the creator's own choice, and it must not strand supply.
    function test_GappedRangesAreAcceptedAndTradeThroughTheGap() public {
        CateFamilyFactory.LaunchParams memory p = _p(bytes32(uint256(8)));
        p.positions = new CateFamilyFactory.LiquidityPosition[](2);
        p.positions[0] = _pos(START, START + 2000, 5000);
        p.positions[1] = _pos(START + 20000, START + 22000, 5000);

        vm.prank(creator);
        (address token, address pool,) = factory.launch(p);
        assertEq(IERC20(token).balanceOf(address(factory)), 0, "nothing stranded in the gap");

        // Buy enough to clear the lower range; the price then crosses the empty
        // band in a single step, because there is nothing in it to trade against.
        _buy(pool, token, USDT, trader, 50_000 ether);
        assertGe(_canonicalTick(pool, token), START + 20000, "price jumped the empty band");
        assertGt(IERC20(token).balanceOf(trader), 0, "the buy still filled");
    }

    // ------------------------------------------------- parameter bounds

    function test_NameAndSymbolLengthBounds() public {
        string memory name64 = "0123456789012345678901234567890123456789012345678901234567890123";
        string memory name65 = string.concat(name64, "X");
        string memory sym32 = "01234567890123456789012345678901";
        string memory sym33 = string.concat(sym32, "X");

        CateFamilyFactory.LaunchParams memory p = _p(bytes32(uint256(9)));
        p.name = name64;
        p.symbol = sym32;
        vm.prank(creator);
        factory.launch(p); // exactly on both limits

        p = _p(bytes32(uint256(10)));
        p.name = name65;
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidName.selector);
        factory.launch(p);

        p = _p(bytes32(uint256(11)));
        p.name = "";
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidName.selector);
        factory.launch(p);

        p = _p(bytes32(uint256(12)));
        p.symbol = sym33;
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidSymbol.selector);
        factory.launch(p);

        p = _p(bytes32(uint256(13)));
        p.symbol = "";
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidSymbol.selector);
        factory.launch(p);
    }

    function test_TotalSupplyBounds() public {
        CateFamilyFactory.LaunchParams memory p = _p(bytes32(uint256(14)));
        p.totalSupply = factory.MIN_TOTAL_SUPPLY() - 1;
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidTotalSupply.selector);
        factory.launch(p);

        p = _p(bytes32(uint256(15)));
        p.totalSupply = factory.MAX_TOTAL_SUPPLY() + 1;
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidTotalSupply.selector);
        factory.launch(p);
    }

    function test_MetadataURILengthBound() public {
        bytes memory long = new bytes(2049);
        for (uint256 i = 0; i < 2049; i++) {
            long[i] = "a";
        }
        CateFamilyFactory.LaunchParams memory p = _p(bytes32(uint256(16)));
        p.metadataURI = string(long);
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.InvalidMetadataURI.selector);
        factory.launch(p);
    }

    /// The tick bounds are STRICT on both sides — a mirrored launch negates the
    /// tick, and initializing a pool at exactly ±MAX_TICK is rejected inside
    /// TickMath. Being one spacing inside must still work.
    function test_InitialTickBoundsAreStrict() public {
        int24 maxUsable = (887272 / SPACING) * SPACING;

        CateFamilyFactory.LaunchParams memory p = _p(bytes32(uint256(17)));
        p.initialTick = maxUsable;
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.TickOutOfRange.selector);
        factory.launch(p);

        p = _p(bytes32(uint256(18)));
        p.initialTick = -maxUsable;
        vm.prank(creator);
        vm.expectRevert(CateFamilyFactory.TickOutOfRange.selector);
        factory.launch(p);
    }

    // ------------------------------------------------------ CREATE2 salt

    /// The salt is namespaced by `msg.sender`, so two creators may pick the same
    /// one — but one creator may not reuse theirs. The failure is a bare CREATE2
    /// collision rather than a named error, which is worth pinning so nobody
    /// "fixes" it into something misleading.
    function test_SaltIsPerCreatorAndCannotBeReused() public {
        vm.prank(creator);
        factory.launch(_p(bytes32(uint256(19))));

        vm.prank(creator);
        vm.expectRevert();
        factory.launch(_p(bytes32(uint256(19))));

        // A different creator, the same salt: fine, and a different address.
        address other = makeAddr("other-creator");
        vm.etch(other, "");
        vm.prank(other);
        factory.launch(_p(bytes32(uint256(19))));
    }

    function test_PredictedAddressMatchesTheLaunch() public {
        CateFamilyFactory.LaunchParams memory p = _p(bytes32(uint256(20)));
        address predicted = factory.predictTokenAddress(creator, p.salt, p.name, p.symbol, p.totalSupply, p.metadataURI);

        vm.prank(creator);
        (address token,,) = factory.launch(p);
        assertEq(token, predicted, "prediction is what the launch form relies on");
    }

    // ----------------------------------------------------- stray transfers

    /// Donations are the classic way to break balance-based accounting. The
    /// factory hands out refunds from TRACKED arithmetic, and the locker credits
    /// fees from deltas taken around the collect — so a donation sitting there
    /// beforehand is inside both reads and cancels out.
    function test_DonationsDoNotBecomeAnybodysFees() public {
        vm.prank(creator);
        (address token, address pool,) = factory.launch(_p(bytes32(uint256(21))));
        _buy(pool, token, USDT, trader, 20_000 ether);

        // Donate to both, then collect.
        deal(USDT, address(this), 5_000 ether);
        IERC20(USDT).transfer(address(locker), 2_000 ether);
        IERC20(USDT).transfer(address(factory), 3_000 ether);

        uint256 creditBefore = locker.claimableFees(creator, USDT);
        locker.collectAllFees(token);
        uint256 earned = locker.claimableFees(creator, USDT) - creditBefore;

        assertGt(earned, 0, "real fees were credited");
        assertLt(earned, 2_000 ether, "the donation was not credited as fees");

        // The factory's donation is simply stuck — never refunded to anyone.
        assertEq(IERC20(USDT).balanceOf(address(factory)), 3_000 ether, "stray funds stay stray");
    }

    function test_CollectOnAnUnassignedPositionIsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(CateFamilyLiquidityLocker.PositionNotAssigned.selector, uint256(1)));
        locker.collectFees(1);
    }

    function test_ClaimToTheZeroAddressIsRejected() public {
        vm.expectRevert(CateFamilyLiquidityLocker.ZeroAddress.selector);
        locker.claimFees(USDT, address(0));
    }

    // ------------------------------------------------ contract launchers

    /// The refund is a raw `call` to `msg.sender`, so a contract that refuses
    /// BNB reverts the whole launch. That is the right outcome — completing and
    /// keeping the change would be worse — but it means a contract launcher
    /// must not over-fund a native first buy, and the error should say so.
    function test_ContractLauncherThatRefusesBnbCannotOverfundAFirstBuy() public {
        RefusingLauncher launcher = new RefusingLauncher(factory);
        vm.deal(address(launcher), 1_000 ether);

        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(uint256(22));
        p.positions = new CateFamilyFactory.LiquidityPosition[](2);
        p.positions[0] = _pos(TICK_10_BNB_MCAP, TICK_10_BNB_MCAP + 2000, 1000);
        p.positions[1] = _pos(TICK_10_BNB_MCAP + 2000, 887200, 9000);
        p.initialBuyQuoteAmount = 900 ether;
        p.initialBuyMinTokensOut = 1;

        vm.expectRevert(CateFamilyFactory.NativeTransferFailed.selector);
        launcher.launch{value: 900 ether}(p);
    }

    /// The same launcher succeeds when nothing has to come back — so the
    /// failure above is specifically the refund, not contracts in general.
    function test_ContractLauncherSucceedsWithNoRefundDue() public {
        RefusingLauncher launcher = new RefusingLauncher(factory);
        vm.deal(address(launcher), 1_000 ether);

        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(uint256(23));

        address token = launcher.launch{value: 0}(p);
        assertTrue(token != address(0), "a contract can launch perfectly well");
    }
}
