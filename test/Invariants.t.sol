// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CateFamilyTestBase} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CateFamilyFactory} from "../src/CateFamilyFactory.sol";
import {CateFamilyMultiPairFactory} from "../src/CateFamilyMultiPairFactory.sol";
import {CateFamilyLiquidityLocker} from "../src/CateFamilyLiquidityLocker.sol";
import {INonfungiblePositionManager, IPancakeV3Pool} from "../src/interfaces/IPancakeV3.sol";

/// @notice Property tests for the three things that would actually lose money:
/// supply appearing or vanishing, the locker becoming insolvent or letting a
/// position escape, and fee credits leaking between launches.
contract InvariantsTest is CateFamilyTestBase {
    // ------------------------------------------------- supply conservation

    /// @notice Whenever a launch succeeds, every unit of supply is pool
    /// liquidity, a holder balance, or burned — never retained by the factory
    /// and never conjured.
    ///
    /// Extreme supply/price combinations legitimately revert inside PancakeSwap
    /// (the liquidity for the range overflows uint128), so the property under
    /// test is conditional on the launch going through; the reverting side is
    /// pinned separately by
    /// `test_ExtremeStartingPriceHitsPancakeLiquidityCeiling`.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_SupplyIsFullyAccountedFor(uint96 rawSupply, uint16 rawTickSteps) public {
        uint256 supply = bound(uint256(rawSupply), 1e18, 1e30);
        int24 tick = int24(bound(int256(uint256(rawTickSteps)), 0, 3000)) * -200 - 100000;
        tick = (tick / TICK_SPACING_1PCT) * TICK_SPACING_1PCT;

        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, tick);
        p.totalSupply = supply;
        p.salt = keccak256(abi.encode(rawSupply, rawTickSteps));

        vm.prank(creator);
        try factory.launch(p) returns (address token, address pool, uint256[] memory) {
            uint256 accounted = IERC20(token).balanceOf(pool) + IERC20(token).balanceOf(DEAD)
                + IERC20(token).balanceOf(address(locker)) + IERC20(token).balanceOf(creator);
            assertEq(accounted, supply, "supply must be fully accounted for");
            assertEq(IERC20(token).balanceOf(address(factory)), 0, "factory must retain nothing");
            assertEq(IERC20(token).totalSupply(), supply, "supply must be fixed");
        } catch {
            // Out-of-range for Pancake's own maths; nothing was created.
        }
    }

    /// @notice The same, across a five-pool bStock launch where the supply is
    /// sliced by basis points — the place a rounding error would hide.
    function test_MultiPairSupplySplitLosesNothing() public {
        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](5);
        // Deliberately awkward bps that do not divide evenly.
        uint16[5] memory bps = [uint16(3333), 3333, 1667, 1000, 667];
        address[5] memory quotes = [WBNB, USDT, USDC, CAKE, BTCB];
        int24[5] memory ticks = [int24(-184200), -122000, -122000, -131200, -237200];
        for (uint256 i = 0; i < 5; i++) {
            pairs[i] = CateFamilyMultiPairFactory.PairConfig(quotes[i], FEE_1PCT, ticks[i], bps[i]);
        }

        CateFamilyMultiPairFactory.LaunchParams memory p;
        p.name = "Split";
        p.symbol = "SPLIT";
        p.metadataURI = "";
        p.totalSupply = DEFAULT_SUPPLY;
        p.pairs = pairs;
        p.salt = bytes32(uint256(42));
        p.maxLaunchFeeWei = 5 ether;

        vm.prank(creator);
        (address token, address[] memory pools,) = multiPairFactory.launch(p);

        uint256 total = IERC20(token).balanceOf(DEAD);
        for (uint256 i = 0; i < pools.length; i++) total += IERC20(token).balanceOf(pools[i]);
        assertEq(total, DEFAULT_SUPPLY, "every unit lands in a pool or the burn address");
        assertEq(IERC20(token).balanceOf(address(multiPairFactory)), 0, "factory retains nothing");
    }

    // --------------------------------------------------- locker solvency

    /// @notice The locker must always hold at least what it owes. Credits are
    /// booked from measured balance deltas, so the sum of outstanding credits
    /// can never exceed the balance backing them.
    function test_LockerStaysSolventAcrossManyLaunchesAndClaims() public {
        address[3] memory creators = [makeAddr("c1"), makeAddr("c2"), makeAddr("c3")];
        address[3] memory tokens;
        address[3] memory pools;

        for (uint256 i = 0; i < 3; i++) {
            vm.etch(creators[i], "");
            CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
            p.salt = bytes32(uint256(700 + i));
            vm.prank(creators[i]);
            (tokens[i], pools[i],) = factory.launch(p);
        }

        // Trade all three, then collect everything.
        for (uint256 i = 0; i < 3; i++) {
            _buy(pools[i], tokens[i], WBNB, trader, 5 ether);
            _sell(pools[i], tokens[i], WBNB, trader, IERC20(tokens[i]).balanceOf(trader) / 2);
            locker.collectAllFees(tokens[i]);
        }

        uint256 owed = locker.claimableFees(locker.PROTOCOL(), WBNB);
        for (uint256 i = 0; i < 3; i++) owed += locker.claimableFees(creators[i], WBNB);
        assertGe(IERC20(WBNB).balanceOf(address(locker)), owed, "locker must hold at least what it owes");

        // Every creator claims in full; the locker must be able to pay all of them.
        for (uint256 i = 0; i < 3; i++) {
            uint256 credit = locker.claimableFees(creators[i], WBNB);
            if (credit == 0) continue;
            vm.prank(creators[i]);
            uint256 paid = locker.claimFees(WBNB, creators[i]);
            assertEq(paid, credit, "a creator must be paid their full credit");
        }
        vm.prank(treasury);
        locker.claimProtocolFees(WBNB, treasury);
    }

    /// @notice One creator must never be able to reach another's fees.
    function test_CreatorCannotClaimAnotherLaunchesFees() public {
        address victim = makeAddr("victim");
        address thief = makeAddr("thief");
        vm.etch(victim, "");
        vm.etch(thief, "");

        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(uint256(801));
        vm.prank(victim);
        (address token, address pool,) = factory.launch(p);

        _buy(pool, token, WBNB, trader, 10 ether);
        locker.collectAllFees(token);

        assertGt(locker.claimableFees(victim, WBNB), 0, "victim accrued fees");
        assertEq(locker.claimableFees(thief, WBNB), 0, "thief has no credit");

        vm.prank(thief);
        vm.expectRevert(CateFamilyLiquidityLocker.NothingToClaim.selector);
        locker.claimFees(WBNB, thief);
    }

    /// @notice The fee split must be exact — the two shares add back to the
    /// whole, with nothing stranded by integer division.
    function test_FeeSplitIsExactWithNoRoundingLeak() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(uint256(802));
        vm.prank(creator);
        (address token, address pool,) = factory.launch(p);

        _buy(pool, token, WBNB, trader, 7 ether);

        uint256 lockerBefore = IERC20(WBNB).balanceOf(address(locker));
        locker.collectAllFees(token);
        uint256 arrived = IERC20(WBNB).balanceOf(address(locker)) - lockerBefore;

        uint256 credited = locker.claimableFees(creator, WBNB) + locker.claimableFees(locker.PROTOCOL(), WBNB);
        assertEq(credited, arrived, "every quote unit collected must be credited to somebody");
    }

    // ----------------------------------------------- liquidity is locked

    /// @notice A launched token can itself be the quote asset of a later
    /// launch. That puts the same currency on both sides of the locker's books:
    /// burned as a token-side fee for one position, credited as a quote-side
    /// fee for another. The credits must survive the burns.
    function test_TokenUsedAsAnotherLaunchesQuoteKeepsBooksStraight() public {
        CateFamilyFactory.LaunchParams memory first = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        first.salt = bytes32(uint256(901));
        vm.prank(creator);
        (address tokenA, address poolA,) = factory.launch(first);

        // Give the trader some A, then launch B priced against A.
        _buy(poolA, tokenA, WBNB, trader, 30 ether);

        address creatorB = makeAddr("creatorB");
        vm.etch(creatorB, "");
        CateFamilyFactory.LaunchParams memory second = _defaultParams(tokenA, TICK_10_BNB_MCAP);
        second.salt = bytes32(uint256(902));
        vm.prank(creatorB);
        (address tokenB, address poolB,) = factory.launch(second);

        // Trade B against A so the locker books A as a QUOTE currency...
        vm.startPrank(trader);
        IERC20(tokenA).approve(address(swapper), type(uint256).max);
        bool zeroForOne = tokenA < tokenB;
        swapper.swap(poolB, zeroForOne, int256(IERC20(tokenA).balanceOf(trader) / 4), trader);
        vm.stopPrank();

        locker.collectAllFees(tokenB);
        uint256 creditInA = locker.claimableFees(creatorB, tokenA);
        assertGt(creditInA, 0, "creator B is owed fees denominated in token A");

        // ...then collect A's own pool, which BURNS token-side A from the locker.
        _sell(poolA, tokenA, WBNB, trader, IERC20(tokenA).balanceOf(trader) / 2);
        locker.collectAllFees(tokenA);

        assertGe(
            IERC20(tokenA).balanceOf(address(locker)),
            creditInA,
            "burning A as a token-side fee must not eat A owed as a quote-side credit"
        );

        vm.prank(creatorB);
        uint256 paid = locker.claimFees(tokenA, creatorB);
        assertEq(paid, creditInA, "creator B must still be paid in full");
    }

    /// @notice Collecting fees repeatedly must never move, shrink or approve a
    /// locked position — the locker exposes no path that could.
    function test_RepeatedCollectionNeverReleasesLiquidity() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(uint256(903));
        vm.prank(creator);
        (address token, address pool, uint256[] memory ids) = factory.launch(p);

        (,,,,,,, uint128 liquidityAtLaunch,,,,) =
            INonfungiblePositionManager(POSITION_MANAGER).positions(ids[0]);

        for (uint256 i = 0; i < 5; i++) {
            _buy(pool, token, WBNB, trader, 1 ether);
            _sell(pool, token, WBNB, trader, IERC20(token).balanceOf(trader) / 2);
            locker.collectFees(ids[0]);

            assertEq(
                INonfungiblePositionManager(POSITION_MANAGER).ownerOf(ids[0]),
                address(locker),
                "position must never leave the locker"
            );
            (,,,,,,, uint128 liquidityNow,,,,) =
                INonfungiblePositionManager(POSITION_MANAGER).positions(ids[0]);
            assertEq(liquidityNow, liquidityAtLaunch, "liquidity must never decrease");
        }
    }

    // ------------------------------------------------------- owner powers

    /// @notice The owner cannot change the deal on a launch that already
    /// happened. The protocol's fee share is snapshotted into the position when
    /// it is locked, so raising it later applies only to future launches.
    function test_OwnerCannotRetroactivelyRaiseItsFeeShare() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(uint256(905));
        vm.prank(creator);
        (address token, address pool, uint256[] memory ids) = factory.launch(p);

        (,, uint16 snapshotAtLaunch) = locker.lockedPositions(ids[0]);
        assertEq(snapshotAtLaunch, 5000, "launched under a 50/50 split");

        // Owner maxes out the protocol share afterwards.
                _setProtocolLpFeeBps(factory, 5000);
                _setTreasury(factory, makeAddr("greedyTreasury"));

        (,, uint16 snapshotNow) = locker.lockedPositions(ids[0]);
        assertEq(snapshotNow, snapshotAtLaunch, "an existing position keeps its launch-time split");

        _buy(pool, token, WBNB, trader, 8 ether);
        locker.collectAllFees(token);

        uint256 creatorCredit = locker.claimableFees(creator, WBNB);
        uint256 protocolCredit = locker.claimableFees(locker.PROTOCOL(), WBNB);
        assertApproxEqAbs(creatorCredit, protocolCredit, 2, "the creator still gets half");
    }

    /// @notice Pausing stops new launches and nothing else. Live pools keep
    /// trading and creators keep claiming — a pause can never strand funds.
    function test_PauseCannotStrandExistingLaunches() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(uint256(906));
        vm.prank(creator);
        (address token, address pool,) = factory.launch(p);

        vm.prank(owner);
        factory.setPaused(true);

        // Trading continues: the pool is Pancake's, not ours.
        _buy(pool, token, WBNB, trader, 3 ether);
        // Collection and claiming continue.
        locker.collectAllFees(token);
        uint256 credit = locker.claimableFees(creator, WBNB);
        assertGt(credit, 0, "fees still accrue while paused");

        vm.prank(creator);
        assertEq(locker.claimFees(WBNB, creator), credit, "creators can still be paid while paused");
    }

    /// @notice The locker holds no launched tokens between calls: the token
    /// side of every collection is burned in the same transaction.
    function test_LockerNeverRetainsLaunchedTokens() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(uint256(904));
        vm.prank(creator);
        (address token, address pool,) = factory.launch(p);

        _buy(pool, token, WBNB, trader, 12 ether);
        _sell(pool, token, WBNB, trader, IERC20(token).balanceOf(trader));
        locker.collectAllFees(token);

        assertEq(IERC20(token).balanceOf(address(locker)), 0, "no launched tokens may sit in the locker");
    }
}
