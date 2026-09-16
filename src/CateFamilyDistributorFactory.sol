// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TickMath} from "./lib/TickMath.sol";
import {CateFamilyFactory} from "./CateFamilyFactory.sol";
import {CateFamilyToken} from "./CateFamilyToken.sol";
import {CateFamilyLiquidityLocker} from "./CateFamilyLiquidityLocker.sol";
import {IPancakeV3Pool, IPancakeV3SwapCallback} from "./interfaces/IPancakeV3.sol";

/// @title CateFamilyHolderDistributor
/// @notice Routes a launch's creator fee share to ALL holders, trustlessly.
///
/// CateFamily tokens are deliberately hook-free — that is what makes them tradeable
/// by every router and aggregator — so per-wallet dividend pushes are
/// impossible without breaking that guarantee. The vanilla-token way to pay
/// every holder pro-rata is buyback-and-burn: this contract claims the
/// creator's quote-fee credit from the locker, market-buys the launched
/// token through its own pool, and burns the proceeds. Every holder's share
/// of the supply grows in the same transaction, with no snapshots, no claims,
/// and no server.
///
/// A creator opts in by making this contract their fee recipient — at launch
/// (the launch form's "fees to holders" option) or later via
/// `setCreatorFeeRecipient`. Opting in is PERMANENT: nothing in this contract
/// can hand the recipient role back.
///
/// ## Who may trigger a distribution, and how often
///
/// The buy is a predictable market order, and whoever chooses its moment can
/// prepare the pool for it. The TWAP band below stops a same-block sandwich,
/// but a patient attacker can push the price up, hold it for one TWAP window
/// with dust trades, call `distribute` themselves and sell into the buy —
/// the audit measured roughly half of a distribution extracted that way. Two
/// controls answer it:
///
///   - the spend per call is capped at 1% of the pool's quote depth and calls
///     are at least an hour apart, so extracting anything meaningful means
///     holding a manipulated price, with capital exposed, for many hours;
///   - a keeper. The registry's governance can set a DEFAULT keeper for every
///     distributor, and each token's creator can override it with their own
///     or open their distributor to anyone with the `PERMISSIONLESS` sentinel.
///     While a keeper applies, only it or the creator can trigger, so an
///     attacker no longer controls the timing at all. A keeper cannot move
///     funds: it chooses the moment and a slippage floor, nothing else.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
contract CateFamilyHolderDistributor is IPancakeV3SwapCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice launch on cappuccino.family
    string public constant CAPPUCCINO = "launch on cappuccino.family";

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable token;
    address public immutable quoteToken;
    address public immutable pool;
    /// @dev True when the launched token sorts as token0 in its pool. Buying it
    /// then pushes the pool tick UP; when it sorts as token1, the tick moves
    /// DOWN. Every price check below is written in terms of this.
    bool public immutable tokenIsToken0;
    CateFamilyLiquidityLocker public immutable locker;

    // ------------------------------------------------- sandwich protection

    /// @notice Most of the pool's quote-side balance a single distribution may
    /// spend, in basis points.
    ///
    /// A distribution is a market buy that anyone can trigger, so its size is
    /// the thing an attacker gets to sandwich. Capping the spend relative to
    /// the pool's own depth bounds the price impact structurally: whatever is
    /// left over simply stays here and goes out on the next call. Without this
    /// a large fee balance could be pushed through a thin pool in one trade,
    /// which is precisely the trade worth sandwiching.
    ///
    /// One percent, down from five: the cost of holding a manipulated price
    /// scales with the pool's depth, the prize scales with this cap, and at
    /// five percent the prize won (audit finding M-04).
    /// @notice A distribution may spend at most the quote that would move the
    /// TWAP price by this many ticks through the pool's in-range liquidity
    /// (100 ticks ≈ 1%). Measured against active liquidity, not the pool's
    /// token balance, so a price push cannot enlarge its own prize and
    /// out-of-range or donated quote does not count as depth.
    int24 public constant MAX_IMPACT_TICKS = 100;

    /// @notice Minimum time between two distributions. Together with the spend
    /// cap this bounds what a manipulated price can extract per hour held.
    uint256 public constant MIN_DISTRIBUTION_INTERVAL = 1 hours;

    /// @notice How far the post-trade pool tick may sit past the TWAP tick.
    /// 1,000 ticks is roughly 10.5%. Wide enough that an honest buyback in a
    /// thin pool still succeeds, tight enough that a sandwich cannot walk the
    /// price far before the distribution reverts.
    int24 public constant MAX_TICK_DEVIATION = 300; // ≈ 3%

    /// @notice TWAP windows tried in order, longest first. A longer window is
    /// costlier to manipulate, so it is preferred whenever the pool's oracle
    /// has enough history for it.
    uint32 public constant TWAP_WINDOW_LONG = 1800; // 30 minutes
    uint32 public constant TWAP_WINDOW_MID = 900; // 15 minutes
    uint32 public constant TWAP_WINDOW_SHORT = 300; // 5 minutes

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice The registry that deployed this distributor; the only caller
    /// allowed to trigger on someone else's behalf (`distributeFor`).
    address public immutable distributorFactory;

    /// @notice Sentinel a creator sets as `keeper` to open their distributor to
    /// anyone even when the registry has a default keeper.
    address public constant PERMISSIONLESS = address(1);

    /// @notice Creator-set trigger authority. Zero (the default) defers to the
    /// registry's `defaultKeeper`; `PERMISSIONLESS` opens the trigger to all;
    /// any other address restricts it to that address and the creator.
    address public keeper;

    /// @notice Timestamp of the last distribution, for the interval check.
    uint64 public lastDistributionAt;

    bool private _inSwap;

    event DistributedToHolders(
        address indexed caller, uint256 quoteSpent, uint256 tokensBurned, int24 twapTick, uint32 twapWindow
    );
    event OraclePrepared(uint16 cardinality);
    event KeeperSet(address indexed previousKeeper, address indexed keeper);

    error UnknownLaunch();
    error NothingToDistribute();
    error SlippageExceeded(uint256 burned, uint256 minimum);
    error UnexpectedSwapCallback();
    error TwapUnavailable();
    error PriceOutsideTwapBand(int24 postTradeTick, int24 twapTick, int24 maxDeviation);
    error NotAuthorized();
    error DistributionTooSoon(uint64 nextAllowedAt);
    error OnlyDistributorFactory();

    constructor(CateFamilyFactory cappuccinoFactory_, address token_) {
        (, address quoteToken_, address pool_,,,) = cappuccinoFactory_.launches(token_);
        if (pool_ == address(0)) revert UnknownLaunch();
        token = token_;
        quoteToken = quoteToken_;
        pool = pool_;
        tokenIsToken0 = token_ < quoteToken_;
        locker = cappuccinoFactory_.locker();
        distributorFactory = msg.sender;
    }

    /// @notice The wallet that launched the token; may appoint a keeper.
    function creator() public view returns (address) {
        return CateFamilyToken(token).creator();
    }

    /// @notice Names the address allowed to trigger distributions, or
    /// `PERMISSIONLESS` to open it to anyone, or zero to defer to the
    /// registry's default. Creator only.
    function setKeeper(address keeper_) external {
        if (msg.sender != creator()) revert NotAuthorized();
        emit KeeperSet(keeper, keeper_);
        keeper = keeper_;
    }

    /// @notice The keeper that applies right now: the creator's, else the
    /// registry's default. Zero or `PERMISSIONLESS` means anyone may trigger.
    function effectiveKeeper() public view returns (address) {
        address k = keeper;
        if (k == address(0)) k = CateFamilyDistributorFactory(distributorFactory).defaultKeeper();
        return k;
    }

    /// @notice Collects this launch's accrued fees, claims the creator share
    /// held by this contract, buys the token through its own pool and burns
    /// the proceeds. Callable by anyone, any time.
    ///
    /// Because anyone can call this and the trade is a predictable market buy,
    /// it is the natural sandwich target. Three things bound that:
    ///
    ///   1. the spend is capped at what moves the TWAP price by MAX_IMPACT_TICKS through the pool's own
    ///      quote balance, so a distribution is always small relative to depth
    ///      and leftover fees simply roll into the next call;
    ///   2. the post-trade tick must land within MAX_TICK_DEVIATION of a TWAP
    ///      taken over at least five minutes, which an attacker cannot move
    ///      inside one block;
    ///   3. the caller's own `minTokensOut` still applies on top, so a caller
    ///      who has quoted off-chain can demand something tighter.
    ///
    /// @param minTokensOut Additional caller-supplied floor for the burned
    /// amount. Zero is allowed — the on-chain TWAP band is the real protection
    /// and cannot be waived by the caller.
    function distribute(uint256 minTokensOut)
        external
        nonReentrant
        returns (uint256 quoteSpent, uint256 tokensBurned)
    {
        return _distribute(msg.sender, minTokensOut);
    }

    /// @notice The registry's one-click path, carrying the real caller so the
    /// keeper check and the event see the person, not the registry.
    function distributeFor(address caller, uint256 minTokensOut)
        external
        nonReentrant
        returns (uint256 quoteSpent, uint256 tokensBurned)
    {
        if (msg.sender != distributorFactory) revert OnlyDistributorFactory();
        return _distribute(caller, minTokensOut);
    }

    function _distribute(address caller, uint256 minTokensOut)
        internal
        returns (uint256 quoteSpent, uint256 tokensBurned)
    {
        address keeper_ = effectiveKeeper();
        if (keeper_ != address(0) && keeper_ != PERMISSIONLESS && caller != keeper_ && caller != creator()) {
            revert NotAuthorized();
        }
        uint64 nextAllowedAt = lastDistributionAt + uint64(MIN_DISTRIBUTION_INTERVAL);
        if (lastDistributionAt != 0 && block.timestamp < nextAllowedAt) revert DistributionTooSoon(nextAllowedAt);
        lastDistributionAt = uint64(block.timestamp);

        locker.collectAllFees(token);
        if (locker.claimableFees(address(this), quoteToken) > 0) {
            locker.claimFees(quoteToken, address(this));
        }

        uint256 balance = IERC20(quoteToken).balanceOf(address(this));
        if (balance == 0) revert NothingToDistribute();

        // Establish the fair price BEFORE trading. A reverting oracle means the
        // pool has no usable history yet: call prepareOracle() and let it fill.
        (int24 twapTick, uint32 twapWindow) = _twapTick();

        uint256 spend = _cappedSpend(balance, twapTick);
        if (spend == 0) revert NothingToDistribute();

        bool zeroForOne = !tokenIsToken0; // selling quote for the launched token
        _inSwap = true;
        (int256 amount0, int256 amount1) = IPancakeV3Pool(pool).swap(
            DEAD,
            zeroForOne,
            int256(spend),
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            ''
        );
        _inSwap = false;

        tokensBurned = uint256(-(zeroForOne ? amount1 : amount0));
        quoteSpent = uint256(zeroForOne ? amount0 : amount1);

        _requireWithinTwapBand(twapTick);
        if (tokensBurned < minTokensOut) revert SlippageExceeded(tokensBurned, minTokensOut);

        emit DistributedToHolders(caller, quoteSpent, tokensBurned, twapTick, twapWindow);
    }

    /// @notice Grows the pool's oracle so a TWAP long enough to price a
    /// distribution becomes available. Permissionless and idempotent; a pool
    /// only ever grows its observation array, never shrinks it.
    /// @dev A freshly launched pool stores a single observation, which is
    /// overwritten by every trade, so `observe` over any real window reverts
    /// until the array has room. Growing it is deliberately NOT done at launch:
    /// it would tax every creator, including those who never route fees to
    /// holders.
    function prepareOracle(uint16 cardinality) external {
        IPancakeV3Pool(pool).increaseObservationCardinalityNext(cardinality);
        emit OraclePrepared(cardinality);
    }

    /// @notice Whether a distribution could be priced right now, and over what
    /// window. The launch surface uses this to tell a caller to prepare the
    /// oracle instead of letting the transaction revert in their wallet.
    function oracleReady() external view returns (bool ready, uint32 window) {
        (bool ok, , uint32 w) = _tryTwap();
        return (ok, w);
    }

    // ------------------------------------------------------------- internals

    /// @notice The most a distribution may spend right now: the quote needed
    /// to move the TWAP price by MAX_IMPACT_TICKS through the pool's current
    /// in-range liquidity. Zero when the pool has no liquidity in range or no
    /// usable TWAP.
    function spendCap() external view returns (uint256) {
        (bool ok, int24 twapTick,) = _tryTwap();
        if (!ok) return 0;
        return _impactCap(twapTick);
    }

    /// @dev Caps a distribution at what the pool can absorb around the fair
    /// price, so a large accumulated balance never becomes one enormous,
    /// highly sandwichable market buy.
    function _cappedSpend(uint256 balance, int24 twapTick) internal view returns (uint256) {
        uint256 cap = _impactCap(twapTick);
        return balance < cap ? balance : cap;
    }

    /// @dev Quote that moves the price from the TWAP tick by MAX_IMPACT_TICKS
    /// in the buying direction, given the liquidity active at the current tick
    /// (Uniswap V3 amount deltas over a constant-liquidity segment).
    function _impactCap(int24 twapTick) internal view returns (uint256) {
        uint128 liquidity = IPancakeV3Pool(pool).liquidity();
        if (liquidity == 0) return 0;
        uint160 sqrtTwap = TickMath.getSqrtRatioAtTick(twapTick);
        if (tokenIsToken0) {
            // Quote is token1: buying token0 pushes the price up.
            uint160 sqrtHi = TickMath.getSqrtRatioAtTick(twapTick + MAX_IMPACT_TICKS);
            return Math.mulDiv(liquidity, sqrtHi - sqrtTwap, 1 << 96);
        }
        // Quote is token0: buying token1 pushes the price down.
        uint160 sqrtLo = TickMath.getSqrtRatioAtTick(twapTick - MAX_IMPACT_TICKS);
        return Math.mulDiv(uint256(liquidity) << 96, sqrtTwap - sqrtLo, sqrtTwap) / sqrtLo;
    }

    function _twapTick() internal view returns (int24 tick, uint32 window) {
        (bool ok, int24 t, uint32 w) = _tryTwap();
        if (!ok) revert TwapUnavailable();
        return (t, w);
    }

    /// @dev Longest available window wins: 30 minutes if the oracle reaches
    /// that far back, otherwise 15, otherwise 5. Anything shorter than five
    /// minutes is not worth trusting, so it is refused rather than accepted.
    function _tryTwap() internal view returns (bool ok, int24 tick, uint32 window) {
        uint32[3] memory windows = [TWAP_WINDOW_LONG, TWAP_WINDOW_MID, TWAP_WINDOW_SHORT];
        for (uint256 i = 0; i < windows.length; i++) {
            uint32 w = windows[i];
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = w;
            secondsAgos[1] = 0;
            try IPancakeV3Pool(pool).observe(secondsAgos) returns (
                int56[] memory tickCumulatives, uint160[] memory
            ) {
                int56 delta = tickCumulatives[1] - tickCumulatives[0];
                int24 averageTick = int24(delta / int56(uint56(w)));
                // Solidity truncates toward zero; the arithmetic mean must
                // round down so the band is never accidentally widened.
                if (delta < 0 && (delta % int56(uint56(w)) != 0)) averageTick--;
                return (true, averageTick, w);
            } catch {
                continue;
            }
        }
        return (false, int24(0), uint32(0));
    }

    /// @dev The trade must not leave the pool priced far past its own average.
    /// Buying the launched token moves the tick up when it sorts as token0 and
    /// down when it sorts as token1, so only the adverse direction is checked —
    /// a distribution that happens to execute BETTER than the TWAP is fine.
    function _requireWithinTwapBand(int24 twapTick) internal view {
        (, int24 postTradeTick,,,,,) = IPancakeV3Pool(pool).slot0();
        if (tokenIsToken0) {
            if (postTradeTick > twapTick + MAX_TICK_DEVIATION) {
                revert PriceOutsideTwapBand(postTradeTick, twapTick, MAX_TICK_DEVIATION);
            }
        } else {
            if (postTradeTick < twapTick - MAX_TICK_DEVIATION) {
                revert PriceOutsideTwapBand(postTradeTick, twapTick, MAX_TICK_DEVIATION);
            }
        }
    }

    /// @inheritdoc IPancakeV3SwapCallback
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (!_inSwap || msg.sender != pool) revert UnexpectedSwapCallback();
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        if (owed > 0) IERC20(quoteToken).safeTransfer(pool, owed);
    }
}

/// @title CateFamilyDistributorFactory
/// @notice Deterministic, permissionless registry of per-token distributors.
/// Each launched token gets its own CREATE2 distributor so fee credits are
/// isolated per launch; the address is predictable before the token launches,
/// which lets the launch form route creator fees to holders from block one.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
contract CateFamilyDistributorFactory {
    /// @notice launch on cappuccino.family
    string public constant CAPPUCCINO = "launch on cappuccino.family";

    CateFamilyFactory public immutable cappuccinoFactory;

    mapping(address token => address distributor) public distributorOf;

    /// @notice Trigger authority applied to every distributor whose creator
    /// has not set their own. Set by the launch factory's owner (the same
    /// governance key as the fee configuration). Zero means permissionless.
    address public defaultKeeper;
    /// @notice A scheduled default-keeper change: same 48h delay and 7-day
    /// expiry as every other economic parameter (second audit, L-03).
    address public pendingDefaultKeeper;
    uint64 public pendingDefaultKeeperEta;
    uint256 public constant CONFIG_DELAY = 48 hours;
    uint256 public constant CONFIG_EXPIRY = 7 days;

    event DistributorCreated(address indexed token, address indexed distributor);
    event DefaultKeeperSet(address indexed previousKeeper, address indexed keeper);
    event DefaultKeeperScheduled(address indexed keeper, uint64 eta);
    event DefaultKeeperCancelled();

    error OnlyFactoryOwner();
    error KeeperRequired();
    error NoPendingConfig();
    error ConfigNotReady(uint64 eta);
    error ConfigExpired(uint64 eta);

    /// @param defaultKeeper_ The platform keeper every distributor starts
    /// with. Required: a registry with no keeper is permissionless for every
    /// launch whose creator never chose otherwise, which reopens the timing
    /// attack the keeper exists to close (audit finding M-04). Opening the
    /// trigger to everyone is an explicit choice: pass PERMISSIONLESS.
    constructor(CateFamilyFactory cappuccinoFactory_, address defaultKeeper_) {
        if (defaultKeeper_ == address(0)) revert KeeperRequired();
        cappuccinoFactory = cappuccinoFactory_;
        defaultKeeper = defaultKeeper_;
        emit DefaultKeeperSet(address(0), defaultKeeper_);
    }

    /// @notice Schedules a new platform-wide default keeper. Factory owner
    /// only; applies after CONFIG_DELAY. Never zero: use PERMISSIONLESS to open
    /// the trigger deliberately.
    function scheduleDefaultKeeper(address keeper) external {
        if (msg.sender != cappuccinoFactory.owner()) revert OnlyFactoryOwner();
        if (keeper == address(0)) revert KeeperRequired();
        uint64 eta = uint64(block.timestamp + CONFIG_DELAY);
        pendingDefaultKeeper = keeper;
        pendingDefaultKeeperEta = eta;
        emit DefaultKeeperScheduled(keeper, eta);
    }

    /// @notice Applies the scheduled default keeper once due. Callable by anyone.
    function applyDefaultKeeper() external {
        uint64 eta = pendingDefaultKeeperEta;
        if (eta == 0) revert NoPendingConfig();
        if (block.timestamp < eta) revert ConfigNotReady(eta);
        if (block.timestamp > eta + CONFIG_EXPIRY) revert ConfigExpired(eta);
        address keeper = pendingDefaultKeeper;
        delete pendingDefaultKeeper;
        delete pendingDefaultKeeperEta;
        emit DefaultKeeperSet(defaultKeeper, keeper);
        defaultKeeper = keeper;
    }

    /// @notice Drops a scheduled default keeper. Factory owner only.
    function cancelDefaultKeeper() external {
        if (msg.sender != cappuccinoFactory.owner()) revert OnlyFactoryOwner();
        if (pendingDefaultKeeperEta == 0) revert NoPendingConfig();
        delete pendingDefaultKeeper;
        delete pendingDefaultKeeperEta;
        emit DefaultKeeperCancelled();
    }

    /// @notice Deploys (once) the distributor for a launched token.
    function create(address token) public returns (address distributor) {
        distributor = distributorOf[token];
        if (distributor != address(0)) return distributor;
        distributor = address(
            new CateFamilyHolderDistributor{salt: bytes32(uint256(uint160(token)))}(cappuccinoFactory, token)
        );
        distributorOf[token] = distributor;
        emit DistributorCreated(token, distributor);
    }

    /// @notice One-click path: deploy if needed, then distribute.
    function distribute(address token, uint256 minTokensOut)
        external
        returns (uint256 quoteSpent, uint256 tokensBurned)
    {
        return CateFamilyHolderDistributor(create(token)).distributeFor(msg.sender, minTokensOut);
    }

    /// @notice The distributor address a token will get — valid even before
    /// the token launches, so it can be the launch's creatorFeeRecipient.
    function predict(address token) external view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(CateFamilyHolderDistributor).creationCode, abi.encode(cappuccinoFactory, token))
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), bytes32(uint256(uint160(token))), initCodeHash
                        )
                    )
                )
            )
        );
    }
}
