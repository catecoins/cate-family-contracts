// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {CateFamilyTestBase} from "./Base.t.sol";
import {CateFamilyMultiPairFactory} from "../src/CateFamilyMultiPairFactory.sol";
import {CateFamilyLiquidityLocker} from "../src/CateFamilyLiquidityLocker.sol";
import {IPancakeV3Factory, IPancakeV3Pool, INonfungiblePositionManager} from "../src/interfaces/IPancakeV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TickMath} from "../src/lib/TickMath.sol";

/// @dev Refuses to move once armed. Used as ONE pair's quote asset, to find out
/// whether it can reach the other four.
contract BrickQuote is ERC20 {
    bool public armed;

    constructor() ERC20("Brick", "BRICK") {
        _mint(msg.sender, 1e27);
    }

    function arm() external {
        armed = true;
    }

    function unarm() external {
        armed = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (armed && from != address(0)) revert("BRICK: no");
        super._update(from, to, value);
    }
}

/// @notice Adversarial coverage for the five-pool launch.
///
/// The existing suite covers the input validation well. What it does not cover
/// is what happens once a launch is LIVE and one of its five quote assets turns
/// out to be hostile, or when the launched token sorts on the far side of a
/// quote asset — the orientation hazard that has already produced two real bugs
/// elsewhere in this codebase.
contract MultiPairAdversarialTest is CateFamilyTestBase {
    int24 internal constant START = -122000;

    function _pair(address quote, int24 tick, uint16 bps)
        internal
        pure
        returns (CateFamilyMultiPairFactory.PairConfig memory)
    {
        return CateFamilyMultiPairFactory.PairConfig({
            quoteToken: quote, fee: FEE_1PCT, initialTick: tick, supplyBps: bps
        });
    }

    function _params(bytes32 salt, CateFamilyMultiPairFactory.PairConfig[] memory pairs)
        internal
        pure
        returns (CateFamilyMultiPairFactory.LaunchParams memory p)
    {
        p.name = "Multi";
        p.symbol = "MULTI";
        p.metadataURI = "";
        p.totalSupply = DEFAULT_SUPPLY;
        p.salt = salt;
        p.maxLaunchFeeWei = 5 ether;
        p.pairs = pairs;
    }

    /// @dev The canonical (quote-per-token) tick a pool is really open at.
    function _canonicalTick(address pool, address token) internal view returns (int24) {
        (, int24 raw,,,,,) = IPancakeV3Pool(pool).slot0();
        return IPancakeV3Pool(pool).token0() == token ? raw : -raw;
    }

    // -------------------------------------------------- orientation, priced

    /// Both orientation mutations in `_openPairs`/`_createPool` currently
    /// revert, which is lucky rather than designed — a mint below spot needs
    /// quote the factory does not have. This asserts the PRICE instead, so a
    /// future mirroring bug that happens not to revert still fails here.
    function test_EveryPoolOpensAtTheRequestedCanonicalPrice() public {
        // USDT, CAKE, BTCB, ETH and WBNB span both sides of any token address,
        // so at least one pair is guaranteed to be in each orientation.
        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](5);
        pairs[0] = _pair(USDT, START, 2000);
        pairs[1] = _pair(CAKE, START, 2000);
        pairs[2] = _pair(BTCB, START - 40000, 2000);
        pairs[3] = _pair(USDC, START, 2000);
        pairs[4] = _pair(WBNB, START - 60000, 2000);

        // The token's address comes from CREATE2 over its bytecode, so any
        // change to the token contract moves it. Pick a salt whose predicted
        // address sorts between the lowest and highest quote asset, so both
        // orderings are present by construction rather than by luck.
        bytes32 salt;
        for (uint256 i = 1; i < 500; i++) {
            address predicted = multiPairFactory.predictTokenAddress(creator, bytes32(i), "Multi", "MULTI", DEFAULT_SUPPLY, "");
            if (predicted > CAKE && predicted < WBNB) {
                salt = bytes32(i);
                break;
            }
        }
        require(salt != bytes32(0), "no salt placed the token between the quotes");

        vm.prank(creator);
        (address token, address[] memory pools,) = multiPairFactory.launch(_params(salt, pairs));

        bool sawFirst;
        bool sawSecond;
        for (uint256 i = 0; i < pools.length; i++) {
            assertEq(_canonicalTick(pools[i], token), pairs[i].initialTick, "pool opened at the wrong price");
            if (token < pairs[i].quoteToken) sawFirst = true;
            else sawSecond = true;
        }
        assertTrue(sawFirst && sawSecond, "both orderings must actually occur, or this proves nothing");
    }

    /// The whole supply is placed, and whatever rounding is left over is burned
    /// rather than kept. Awkward basis points on purpose: 3333/3333/3334 does
    /// not divide a 1e27 supply cleanly.
    function test_AwkwardSplitsPlaceEveryTokenAndKeepNothing() public {
        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](3);
        pairs[0] = _pair(USDT, START, 3333);
        pairs[1] = _pair(CAKE, START, 3333);
        pairs[2] = _pair(BTCB, START - 40000, 3334);

        vm.prank(creator);
        (address token, address[] memory pools,) = multiPairFactory.launch(_params(bytes32(uint256(2)), pairs));

        assertEq(IERC20(token).balanceOf(address(multiPairFactory)), 0, "factory keeps nothing");

        uint256 inPools;
        for (uint256 i = 0; i < pools.length; i++) {
            inPools += IERC20(token).balanceOf(pools[i]);
        }
        uint256 burned = IERC20(token).balanceOf(DEAD);
        assertEq(inPools + burned, DEFAULT_SUPPLY, "supply is entirely in pools or burned");
        // Dust is real but must be negligible, not a silent skim.
        assertLt(burned, 1e18, "more than a token's worth went missing into dust");
    }

    // ------------------------------------------------ one hostile pair of five

    /// THE MONEY QUESTION for this factory: a creator picks five quote assets
    /// and one of them turns out to be hostile. The fees from the other four
    /// must remain collectable and claimable in full.
    ///
    /// The locker credits per (recipient, currency), so the blast radius should
    /// be exactly the hostile currency — but `collectAllFees` loops EVERY
    /// position for the token, so one reverting transfer inside that loop would
    /// take the whole collection down with it.
    function test_OneHostileQuoteCannotStrandTheOtherPoolsFees() public {
        BrickQuote brick = new BrickQuote();

        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](3);
        pairs[0] = _pair(USDT, START, 3400);
        pairs[1] = _pair(address(brick), START, 3300);
        pairs[2] = _pair(CAKE, START, 3300);

        vm.prank(creator);
        (address token, address[] memory pools,) = multiPairFactory.launch(_params(bytes32(uint256(3)), pairs));

        // Trade the two honest pools so real fees accrue.
        _buy(pools[0], token, USDT, trader, 20_000 ether);
        _buy(pools[2], token, CAKE, trader, 20_000 ether);

        brick.arm();

        // The hostile pool never traded, so its position has nothing to move —
        // the honest fees must come through regardless.
        CateFamilyLiquidityLocker mpLocker = multiPairFactory.locker();
        mpLocker.collectAllFees(token);

        vm.startPrank(creator);
        assertGt(mpLocker.claimFees(USDT, creator), 0, "USDT fees still claimable");
        assertGt(mpLocker.claimFees(CAKE, creator), 0, "CAKE fees still claimable");
        vm.stopPrank();
    }

    /// The sharper version, and the regression test for a real finding.
    ///
    /// The hostile pool HAS traded, so its position holds fees the collect loop
    /// tries to move. `collectAllFees` used to be ALL-OR-NOTHING: it looped
    /// every position for the token and one reverting quote transfer took the
    /// whole batch down, so the honest pools' fees became unreachable through
    /// the entry point the UI and the distributor both use.
    ///
    /// Nothing was ever lost — `collectFees(id)` per position still worked —
    /// but nothing told a creator that, and the obvious button stopped working.
    /// The locker now skips a failing position and emits
    /// `FeeCollectionSkipped` instead.
    function test_AHostilePoolWithRealFeesStillDoesNotBlockTheOthers() public {
        BrickQuote brick = new BrickQuote();
        brick.transfer(trader, 100_000 ether);

        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](2);
        pairs[0] = _pair(USDT, START, 5000);
        pairs[1] = _pair(address(brick), START, 5000);

        vm.prank(creator);
        (address token, address[] memory pools,) = multiPairFactory.launch(_params(bytes32(uint256(4)), pairs));

        _buy(pools[0], token, USDT, trader, 20_000 ether);

        // Trade the hostile pool too, so it accrues fees on both sides.
        vm.startPrank(trader);
        IERC20(address(brick)).approve(address(swapper), type(uint256).max);
        swapper.swap(pools[1], address(brick) < token, int256(20_000 ether), trader);
        vm.stopPrank();

        brick.arm();

        CateFamilyLiquidityLocker mpLocker = multiPairFactory.locker();
        uint256[] memory ids = mpLocker.positionsOf(token);

        // The batch completes, and says which position it could not collect
        // rather than swallowing it.
        vm.recordLogs();
        mpLocker.collectAllFees(token);

        uint256 skipped;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("FeeCollectionSkipped(uint256,address,address)")) skipped++;
        }
        assertEq(skipped, 1, "exactly the hostile position was skipped");
        assertEq(ids.length, 2, "and the other one was not");

        vm.prank(creator);
        assertGt(mpLocker.claimFees(USDT, creator), 0, "the honest pool's fees came through the batch");
    }

    /// Skipping must not LOSE the fees, only defer them. A quote asset that
    /// misbehaves and later recovers has to be collectable on the next call —
    /// otherwise "skip" would quietly mean "forfeit".
    function test_ASkippedPositionIsCollectableOnceTheCurrencyRecovers() public {
        BrickQuote brick = new BrickQuote();
        brick.transfer(trader, 100_000 ether);

        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](2);
        pairs[0] = _pair(USDT, START, 5000);
        pairs[1] = _pair(address(brick), START, 5000);

        vm.prank(creator);
        (address token, address[] memory pools,) = multiPairFactory.launch(_params(bytes32(uint256(10)), pairs));

        _buy(pools[0], token, USDT, trader, 20_000 ether);
        vm.startPrank(trader);
        IERC20(address(brick)).approve(address(swapper), type(uint256).max);
        swapper.swap(pools[1], address(brick) < token, int256(20_000 ether), trader);
        vm.stopPrank();

        CateFamilyLiquidityLocker mpLocker = multiPairFactory.locker();

        brick.arm();
        mpLocker.collectAllFees(token); // BRICK skipped
        assertEq(mpLocker.claimableFees(creator, address(brick)), 0, "nothing credited while it was broken");

        // The fees were never taken out of the position, so they are still
        // there to collect once transfers work again.
        brick.unarm();
        mpLocker.collectAllFees(token);
        assertGt(mpLocker.claimableFees(creator, address(brick)), 0, "deferred, not forfeited");
    }

    /// Collecting twice in a row must not credit twice. The skip path adds a
    /// second entry point into the same accounting, so this is worth pinning
    /// against the batch specifically, not just against `collectFees`.
    function test_CollectingTheBatchTwiceCreditsOnlyOnce() public {
        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](2);
        pairs[0] = _pair(USDT, START, 5000);
        pairs[1] = _pair(CAKE, START, 5000);

        vm.prank(creator);
        (address token, address[] memory pools,) = multiPairFactory.launch(_params(bytes32(uint256(11)), pairs));
        _buy(pools[0], token, USDT, trader, 20_000 ether);

        CateFamilyLiquidityLocker mpLocker = multiPairFactory.locker();
        mpLocker.collectAllFees(token);
        uint256 afterFirst = mpLocker.claimableFees(creator, USDT);
        assertGt(afterFirst, 0);

        mpLocker.collectAllFees(token);
        assertEq(mpLocker.claimableFees(creator, USDT), afterFirst, "a second sweep credited nothing extra");
    }

    /// The self-call entry point that makes try/catch possible must not be a
    /// way in for anyone else. It takes the caller as a PARAMETER, so an open
    /// version would let anyone collect a position while naming someone else as
    /// the caller in `FeesCollected` — forging the audit trail every indexer
    /// reads.
    ///
    /// Uses a REAL assigned position on purpose: against an unassigned id the
    /// call fails on `PositionNotAssigned` regardless, which would let a broken
    /// guard pass this test for the wrong reason.
    function test_TheBatchHelperIsSelfOnly() public {
        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](2);
        pairs[0] = _pair(USDT, START, 5000);
        pairs[1] = _pair(CAKE, START, 5000);

        vm.prank(creator);
        (address token, address[] memory pools,) = multiPairFactory.launch(_params(bytes32(uint256(12)), pairs));
        _buy(pools[0], token, USDT, trader, 20_000 ether);

        CateFamilyLiquidityLocker mpLocker = multiPairFactory.locker();
        uint256 realId = mpLocker.positionsOf(token)[0];

        vm.prank(attackerAddr());
        vm.expectRevert(CateFamilyLiquidityLocker.OnlySelf.selector);
        mpLocker.collectFeesFromBatch(realId, creator);
    }

    function attackerAddr() internal returns (address a) {
        a = makeAddr("batch-attacker");
        vm.etch(a, "");
    }

    // ------------------------------------------------------- front-running

    /// A pool for the pair can be created by anyone before the launch lands.
    /// Initializing it at a hostile price and letting the launch mint into it
    /// would hand the front-runner the whole supply at a price of their
    /// choosing — so a pre-existing pool at the wrong price must be refused.
    function test_RestoresAPoolPrePricedByAFrontRunner() public {
        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](1);
        pairs[0] = _pair(USDT, START, 10000);
        CateFamilyMultiPairFactory.LaunchParams memory p = _params(bytes32(uint256(5)), pairs);

        address predicted =
            multiPairFactory.predictTokenAddress(creator, p.salt, p.name, p.symbol, p.totalSupply, p.metadataURI);

        // The front-runner opens the pool first, at a wildly different price.
        bool tokenIsToken0 = predicted < USDT;
        (address token0, address token1) = tokenIsToken0 ? (predicted, USDT) : (USDT, predicted);
        int24 hostileCanonical = START + 60000;
        int24 hostilePoolTick = tokenIsToken0 ? hostileCanonical : -hostileCanonical;
        vm.prank(makeAddr("frontrunner"));
        INonfungiblePositionManager(POSITION_MANAGER)
            .createAndInitializePoolIfNecessary(token0, token1, FEE_1PCT, TickMath.getSqrtRatioAtTick(hostilePoolTick));

        // Empty pool, so the factory restores the price and launches into it.
        vm.prank(creator);
        (address token, address[] memory pools,) = multiPairFactory.launch(p);
        assertEq(token, predicted);
        (uint160 sqrtPrice,,,,,,) = IPancakeV3Pool(pools[0]).slot0();
        assertEq(sqrtPrice, TickMath.getSqrtRatioAtTick(tokenIsToken0 ? START : -START), "price restored exactly");
    }

    /// The benign half of the same rule: a pool someone opened at exactly the
    /// price the launch wanted is fine, and the launch proceeds into it. Without
    /// this, the guard above could be "reject any existing pool", which would
    /// make every launch grief-able for the cost of one pool creation.
    function test_AcceptsAPreExistingPoolAtTheCorrectPrice() public {
        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](1);
        pairs[0] = _pair(USDT, START, 10000);
        CateFamilyMultiPairFactory.LaunchParams memory p = _params(bytes32(uint256(6)), pairs);

        address predicted =
            multiPairFactory.predictTokenAddress(creator, p.salt, p.name, p.symbol, p.totalSupply, p.metadataURI);
        bool tokenIsToken0 = predicted < USDT;
        (address token0, address token1) = tokenIsToken0 ? (predicted, USDT) : (USDT, predicted);
        int24 poolTick = tokenIsToken0 ? START : -START;
        vm.prank(makeAddr("helpful-stranger"));
        INonfungiblePositionManager(POSITION_MANAGER)
            .createAndInitializePoolIfNecessary(token0, token1, FEE_1PCT, TickMath.getSqrtRatioAtTick(poolTick));

        vm.prank(creator);
        (address token, address[] memory pools,) = multiPairFactory.launch(p);
        assertEq(token, predicted, "prediction held");
        assertEq(_canonicalTick(pools[0], token), START, "opened where the creator asked");
    }

    // --------------------------------------------------------- fee isolation

    /// Two multi-pair launches sharing a quote asset must not be able to reach
    /// each other's fees. The locker credits per (recipient, currency), so two
    /// creators both owed USDT are the case where a mistake would show.
    function test_TwoLaunchesSharingAQuoteAssetKeepSeparateBooks() public {
        address creatorB = makeAddr("creator-b");
        vm.etch(creatorB, "");
        vm.deal(creatorB, 10 ether);

        CateFamilyMultiPairFactory.PairConfig[] memory pairsA = new CateFamilyMultiPairFactory.PairConfig[](2);
        pairsA[0] = _pair(USDT, START, 5000);
        pairsA[1] = _pair(CAKE, START, 5000);
        vm.prank(creator);
        (address tokenA, address[] memory poolsA,) = multiPairFactory.launch(_params(bytes32(uint256(7)), pairsA));

        CateFamilyMultiPairFactory.PairConfig[] memory pairsB = new CateFamilyMultiPairFactory.PairConfig[](2);
        pairsB[0] = _pair(USDT, START, 5000);
        pairsB[1] = _pair(CAKE, START, 5000);
        vm.prank(creatorB);
        (address tokenB, address[] memory poolsB,) = multiPairFactory.launch(_params(bytes32(uint256(8)), pairsB));

        // Only A trades.
        _buy(poolsA[0], tokenA, USDT, trader, 20_000 ether);

        CateFamilyLiquidityLocker mpLocker = multiPairFactory.locker();
        mpLocker.collectAllFees(tokenA);
        mpLocker.collectAllFees(tokenB);

        assertGt(mpLocker.claimableFees(creator, USDT), 0, "A's creator earned");
        assertEq(mpLocker.claimableFees(creatorB, USDT), 0, "B's creator earned nothing and can claim nothing");

        vm.prank(creatorB);
        vm.expectRevert(CateFamilyLiquidityLocker.NothingToClaim.selector);
        mpLocker.claimFees(USDT, creatorB);

        assertTrue(tokenA != tokenB, "distinct launches");
        assertTrue(poolsB.length == 2);
    }

    /// Two pairs may share a quote token at DIFFERENT fee tiers — the duplicate
    /// guard only rejects the same token AND tier. Both pools then pay into one
    /// claimable balance, which is correct but easy to get wrong.
    function test_SameQuoteAtTwoFeeTiersPoolsIntoOneBalance() public {
        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](2);
        pairs[0] = _pair(USDT, START, 5000);
        pairs[1] =
            CateFamilyMultiPairFactory.PairConfig({quoteToken: USDT, fee: 2500, initialTick: -122000, supplyBps: 5000});

        vm.prank(creator);
        (address token, address[] memory pools,) = multiPairFactory.launch(_params(bytes32(uint256(9)), pairs));
        assertTrue(pools[0] != pools[1], "two distinct pools for one quote asset");

        _buy(pools[0], token, USDT, trader, 10_000 ether);
        _buy(pools[1], token, USDT, trader, 10_000 ether);

        CateFamilyLiquidityLocker mpLocker = multiPairFactory.locker();
        mpLocker.collectAllFees(token);
        vm.prank(creator);
        assertGt(mpLocker.claimFees(USDT, creator), 0, "both tiers paid into the same balance");
    }

    // ------------------------------------------------------ the locker itself

    /// The multi-pair factory deploys its OWN locker. Neither factory may
    /// assign positions in the other's, or one generation's fees could be
    /// routed through the other's books.
    function test_TheTwoFactoriesDoNotShareALocker() public {
        // Resolved BEFORE pranking: `multiPairFactory.locker()` is an external
        // call, and vm.prank applies to the next one — inline it and the prank
        // is spent on the getter instead of on assignPosition.
        CateFamilyLiquidityLocker mpLocker = multiPairFactory.locker();
        assertTrue(address(mpLocker) != address(locker), "separate lockers");

        vm.prank(address(factory));
        vm.expectRevert(CateFamilyLiquidityLocker.OnlyCateFamilyFactory.selector);
        mpLocker.assignPosition(1, USDT, creator, 5000);
    }
}
