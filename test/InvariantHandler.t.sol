// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CateFamilyTestBase} from "./Base.t.sol";
import {CateFamilyFactory} from "../src/CateFamilyFactory.sol";
import {CateFamilyGraduation} from "../src/CateFamilyGraduation.sol";
import {CateFamilyLiquidityLocker} from "../src/CateFamilyLiquidityLocker.sol";
import {IPancakeV3Pool, INonfungiblePositionManager} from "../src/interfaces/IPancakeV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Drives a launched token through random sequences of real actions.
///
/// `Invariants.t.sol` already asserts properties, but it does so over sequences
/// the author chose. The value of this file is the sequences NOBODY chose:
/// claim-before-collect, two collects with no trade between them, a sell that
/// empties a holder, graduation stamped mid-stream. Bugs in fee accounting live
/// in orderings, and a hand-written test can only contain orderings someone
/// already thought of.
contract CurveHandler is Test {
    CateFamilyFactory public immutable factory;
    CateFamilyLiquidityLocker public immutable locker;
    CateFamilyGraduation public immutable graduation;

    address public immutable token;
    address public immutable pool;
    address public immutable quote;
    address public immutable creator;

    address[] public actors;
    /// Sum of every currency the handler has ever fed into the pool, so the
    /// solvency invariant can bound what the locker could possibly owe.
    uint256 public quoteIn;

    uint256 public buys;
    uint256 public sells;
    uint256 public collects;
    uint256 public claims;
    uint256 public stamps;

    constructor(
        CateFamilyFactory factory_,
        CateFamilyLiquidityLocker locker_,
        CateFamilyGraduation graduation_,
        address token_,
        address pool_,
        address quote_,
        address creator_,
        address[] memory actors_
    ) {
        factory = factory_;
        locker = locker_;
        graduation = graduation_;
        token = token_;
        pool = pool_;
        quote = quote_;
        creator = creator_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Trades are made through the pool directly rather than a router, so
    /// the callback pays from this contract and nothing depends on approvals
    /// the fuzzer would have to guess.
    function buy(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        amount = bound(amount, 1e16, 5_000 ether);
        deal(quote, address(this), IERC20(quote).balanceOf(address(this)) + amount);
        quoteIn += amount;

        bool zeroForOne = quote < token;
        try IPancakeV3Pool(pool)
            .swap(
                who,
                zeroForOne,
                int256(amount),
                zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341,
                abi.encode(true)
            ) {
            buys++;
        } catch {
            // The range can be swept clean; a failed swap is a legal outcome
            // and must not end the run.
        }
    }

    function sell(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        uint256 held = IERC20(token).balanceOf(who);
        if (held == 0) return;
        amount = bound(amount, 1, held);

        vm.prank(who);
        IERC20(token).transfer(address(this), amount);

        bool zeroForOne = token < quote;
        try IPancakeV3Pool(pool)
            .swap(
                who,
                zeroForOne,
                int256(amount),
                zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341,
                abi.encode(false)
            ) {
            sells++;
        } catch {
            // Hand it back so supply conservation still holds.
            IERC20(token).transfer(who, amount);
        }
    }

    function collect() external {
        try locker.collectAllFees(token) {
            collects++;
        } catch {}
    }

    /// @dev Claiming is the operation most likely to break solvency, and the
    /// fuzzer is free to attempt it as anyone, including addresses with no
    /// credit at all.
    function claim(uint256 seed) external {
        address who = _actor(seed);
        vm.prank(who);
        try locker.claimFees(quote, who) {
            claims++;
        } catch {}
    }

    function stamp() external {
        try graduation.markGraduated(token) {
            stamps++;
        } catch {}
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == pool, "only pool");
        bool buying = abi.decode(data, (bool));
        address payToken = buying ? quote : token;
        int256 owed = amount0Delta > 0 ? amount0Delta : amount1Delta;
        if (owed > 0) IERC20(payToken).transfer(pool, uint256(owed));
    }
}

contract CurveInvariantTest is StdInvariant, CateFamilyTestBase {
    CateFamilyGraduation internal graduation;
    CurveHandler internal handler;

    address internal launched;
    address internal launchPool;
    uint256 internal liquidityAtStart;

    int24 internal constant CURVE_START = -122000;
    int24 internal constant CURVE_GRADUATION = -100000;
    int24 internal constant MAX_USABLE = 887200;

    address[] internal actors;

    function setUp() public override {
        super.setUp();
        graduation = new CateFamilyGraduation(PANCAKE_V3_FACTORY, POSITION_MANAGER, address(locker));

        CateFamilyFactory.LaunchParams memory p = _defaultParams(USDT, CURVE_START);
        p.salt = bytes32(uint256(4242));
        p.positions = new CateFamilyFactory.LiquidityPosition[](2);
        p.positions[0] =
            CateFamilyFactory.LiquidityPosition({tickLower: CURVE_START, tickUpper: CURVE_GRADUATION, bps: 8000});
        p.positions[1] =
            CateFamilyFactory.LiquidityPosition({tickLower: CURVE_GRADUATION, tickUpper: MAX_USABLE, bps: 2000});

        vm.prank(creator);
        (launched, launchPool,) = factory.launch(p);

        for (uint256 i = 0; i < 3; i++) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            vm.etch(a, "");
            actors.push(a);
        }
        // The creator is an actor too: they are the one address with genuine
        // fee credit, so a solvency bug is most likely to surface through them.
        actors.push(creator);

        handler = new CurveHandler(factory, locker, graduation, launched, launchPool, USDT, creator, actors);
        vm.label(address(handler), "Handler");

        liquidityAtStart = uint256(IPancakeV3Pool(launchPool).liquidity());

        targetContract(address(handler));
    }

    // ------------------------------------------------------------ invariants

    /// Every token ever minted is somewhere. If this drifts, the factory or the
    /// locker is creating or destroying supply.
    function invariant_SupplyIsConserved() public view {
        uint256 total = IERC20(launched).totalSupply();
        uint256 accounted = IERC20(launched).balanceOf(launchPool) + IERC20(launched).balanceOf(DEAD)
            + IERC20(launched).balanceOf(address(locker)) + IERC20(launched).balanceOf(address(factory))
            + IERC20(launched).balanceOf(address(handler));
        // `creator` is one of the actors, so it is counted by the loop and
        // must NOT be added again above — doing so reported 1.057e27 of a 1e27
        // supply, which reads as minted tokens rather than as a test bug.
        for (uint256 i = 0; i < actors.length; i++) {
            accounted += IERC20(launched).balanceOf(actors[i]);
        }
        assertEq(accounted, total, "supply appeared or vanished");
    }

    /// The locker must always be able to pay what it says it owes, in the
    /// currency it owes it. This is the property a hostile quote token attacks;
    /// with an honest one it must hold unconditionally.
    function invariant_LockerIsSolventInTheQuoteCurrency() public view {
        uint256 owed;
        for (uint256 i = 0; i < actors.length; i++) {
            owed += locker.claimableFees(actors[i], USDT);
        }
        owed += locker.claimableFees(locker.PROTOCOL(), USDT);
        assertLe(owed, IERC20(USDT).balanceOf(address(locker)), "locker owes more USDT than it holds");
    }

    /// Locked means locked. Collecting fees must never withdraw principal, and
    /// there is no path that should ever reduce this.
    function invariant_LockedLiquidityNeverDecreases() public view {
        uint256[] memory ids = locker.positionsOf(launched);
        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(ids[i]);
            assertGt(liquidity, 0, "a locked position was drained");
            assertEq(INonfungiblePositionManager(POSITION_MANAGER).ownerOf(ids[i]), address(locker), "unlocked");
        }
    }

    /// The stamp is one-way by design — that is the whole reason it exists,
    /// since a live price reading falls back through the line on a sell-off.
    function invariant_GraduationNeverUnstamps() public view {
        if (handler.stamps() > 0) {
            assertTrue(graduation.hasGraduated(launched), "a recorded graduation came off");
        }
    }

    /// The launch fee is the only native value the factory should ever hold,
    /// and it forwards that immediately — so it must never sit on BNB.
    function invariant_FactoryHoldsNoNativeDust() public view {
        assertEq(address(factory).balance, 0, "factory is sitting on BNB");
    }

    /// @dev Checked ONCE at the end of the whole campaign, not as an invariant.
    ///
    /// As an invariant it fails immediately: Foundry evaluates invariants after
    /// every single call, and the first call of the first run is as likely to
    /// be `claim` as `buy`. But the check itself is worth keeping — a campaign
    /// where every swap silently reverted would report six green invariants
    /// while having exercised nothing, which is the usual way an invariant
    /// suite ends up worthless.
    ///
    /// One gotcha if this ever fails on its own: Foundry replays any sequence
    /// in `cache/invariant/failures/` before running a fresh campaign, and a
    /// replay is a handful of calls with no trades in it — so a STALE cached
    /// failure surfaces here as "the handler never traded" rather than as
    /// whatever actually broke. `rm -rf cache/invariant/failures` before
    /// believing it. (`cache/` is gitignored, so CI never sees this.)
    function afterInvariant() public view {
        assertGt(handler.buys() + handler.sells(), 0, "the handler never traded");
        assertGt(handler.collects(), 0, "fees were never collected");
    }
}
