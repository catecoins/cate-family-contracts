// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TickMath} from "./lib/TickMath.sol";
import {CateFamilyToken} from "./CateFamilyToken.sol";
import {CateFamilyLiquidityLocker} from "./CateFamilyLiquidityLocker.sol";
import {
    IPancakeV3Factory,
    IPancakeV3Pool,
    IPancakeV3SwapCallback,
    INonfungiblePositionManager,
    IWBNB
} from "./interfaces/IPancakeV3.sol";

/// @title CateFamilyFactory
/// @notice Launches creator tokens straight onto PancakeSwap V3 with one-sided
/// liquidity, paired against ANY standard BEP20 quote token.
///
/// A single `launch` transaction:
///   1. deploys a fixed-supply, hook-free CateFamilyToken via CREATE2;
///   2. creates and initializes the Pancake V3 pool for token/quote at the
///      creator's chosen starting tick (starting market cap);
///   3. mints the entire supply as single-sided V3 liquidity across one or
///      more tick ranges above the starting price — no quote capital needed;
///   4. locks every LP NFT forever in the CateFamilyLiquidityLocker, which streams
///      swap fees to the creator and the protocol treasury;
///   5. optionally executes the creator's first buy atomically (native BNB
///      when the quote is WBNB, or any quote BEP20 via allowance).
///
/// Because the pool lives on the canonical PancakeSwap V3 factory and the
/// token has no transfer hooks, the token is immediately tradeable through
/// the PancakeSwap Universal Router, smart router, and every aggregator that
/// routes Pancake V3 liquidity.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
contract CateFamilyFactory is Ownable2Step, ReentrancyGuard, IPancakeV3SwapCallback {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    /// @param tickLower/tickUpper Range in canonical orientation, where price
    /// is quote-per-token and rises with the tick. The factory mirrors ticks
    /// automatically when the pool sorts the token as token1.
    /// @param bps Share of total supply placed in this range, in basis points.
    struct LiquidityPosition {
        int24 tickLower;
        int24 tickUpper;
        uint16 bps;
    }

    struct LaunchParams {
        string name;
        string symbol;
        string metadataURI;
        uint256 totalSupply;
        /// @dev Any standard BEP20 to pair against (WBNB, USDT, CAKE, ...).
        address quoteToken;
        /// @dev Pancake V3 fee tier: 100, 500, 2500 or 10000.
        uint24 fee;
        /// @dev Starting tick (canonical orientation); sets the launch price/market cap.
        int24 initialTick;
        /// @dev Supply curve. Empty means one full range [initialTick, maxUsableTick].
        LiquidityPosition[] positions;
        /// @dev Receiver of the creator share of LP fees; zero defaults to the caller.
        address creatorFeeRecipient;
        /// @dev Optional atomic first buy, denominated in the quote token.
        uint256 initialBuyQuoteAmount;
        /// @dev Slippage floor for the first buy, in launched-token units.
        uint256 initialBuyMinTokensOut;
        /// @dev Receiver of the first buy; zero defaults to the caller.
        address initialBuyRecipient;
        /// @dev Caller-chosen CREATE2 entropy (vanity mining, address prediction).
        bytes32 salt;
        /// @dev The highest launch fee the caller consents to. The launch
        /// reverts if the owner-set fee exceeds this, so a fee change can
        /// never reinterpret value the caller earmarked for the initial buy.
        uint256 maxLaunchFeeWei;
    }

    struct LaunchRecord {
        address token;
        address quoteToken;
        address pool;
        address creator;
        uint24 fee;
        uint64 launchedAtBlock;
    }

    // ------------------------------------------------------------- constants

    uint256 public constant MIN_TOTAL_SUPPLY = 1e18;
    uint256 public constant MAX_TOTAL_SUPPLY = 1e30;
    uint256 public constant MAX_POSITIONS = 10;
    uint256 public constant MAX_LAUNCH_FEE = 5 ether;
    uint16 public constant MAX_PROTOCOL_LP_FEE_BPS = 5000;
    /// @notice How far above the opening tick the creator's atomic first buy
    /// may push the price. 2,000 ticks is a ~22% price move, which on both
    /// shipped shapes (the 80/20 curve and the full range) corresponds to
    /// roughly 10% of total supply. Anything the buy cannot fill within that
    /// limit is refunded, so a creator cannot take the curve at birth (audit
    /// finding M-01). This does not, and cannot, stop a third party buying in
    /// the next transaction; that is a pool property.
    int24 public constant MAX_INITIAL_BUY_TICKS = 2000;
    /// @notice Most of the supply a price restore may sell through parked
    /// quote bids above the opening price (second audit, M-05).
    uint256 public constant MAX_RESTORE_BPS = 1000;
    /// @notice Most of the supply the creator's atomic first buy may take,
    /// whatever the liquidity shape. The tick limit is the partial-fill
    /// mechanism; this is the promise (second audit, L-06).
    uint256 public constant MAX_INITIAL_BUY_BPS = 1000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ------------------------------------------------------------ immutables

    IPancakeV3Factory public immutable pancakeV3Factory;
    INonfungiblePositionManager public immutable positionManager;
    address public immutable wbnb;
    CateFamilyLiquidityLocker public immutable locker;

    // ---------------------------------------------------------------- config

    /// @notice Receives launch fees and the protocol share of LP fees.
    address public treasury;
    /// @notice Flat BNB fee charged per launch.
    uint256 public launchFeeWei;
    /// @notice Protocol share of LP swap fees (bps), snapshotted per launch.
    uint16 public protocolLpFeeBps;
    /// @notice Circuit breaker for new launches; never affects live pools.
    bool public paused;

    /// @notice Delay between scheduling and applying a configuration change.
    uint256 public constant CONFIG_DELAY = 48 hours;
    /// @notice A scheduled change not applied within this long after its delay
    /// lapses: notice cannot be banked and applied at a moment of choice.
    uint256 public constant CONFIG_EXPIRY = 7 days;

    struct PendingConfig {
        address treasury;
        uint256 launchFeeWei;
        uint16 protocolLpFeeBps;
        uint64 eta;
    }

    /// @notice The configuration waiting to be applied, if any (eta == 0: none).
    PendingConfig public pendingConfig;

    /// @notice Launch record per token; also the on-chain registry for indexers.
    mapping(address token => LaunchRecord) public launches;
    uint256 public totalLaunches;

    /// @dev Pool allowed to invoke the swap callback during an initial buy or
    /// a price restore.
    address private _activeSwapPool;
    /// @dev True only while `_restorePrice` runs; the callback then refuses to
    /// pay anything, so a restore that would consume input reverts instead.
    bool private _restoring;
    /// @dev The launched token a restore may pay with; never the quote.
    address private _activeSwapToken;

    // ---------------------------------------------------------------- events

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        address indexed quoteToken,
        address pool,
        uint24 fee,
        int24 initialTick,
        uint256 totalSupply,
        uint256[] lockedPositionIds,
        string name,
        string symbol,
        string metadataURI
    );
    event InitialBuyExecuted(address indexed token, address indexed recipient, uint256 quoteSpent, uint256 tokensOut);
    /// @notice The price restore had to sell launched tokens through bids
    /// parked above the opening price; the quote received went to the creator.
    event PriceRestoredBySale(address indexed token, address indexed pool, uint256 tokensSold, uint256 quoteReceived);
    event TreasuryUpdated(address indexed treasury);
    event LaunchFeeUpdated(uint256 launchFeeWei);
    event ProtocolLpFeeUpdated(uint16 protocolLpFeeBps);
    event PausedSet(bool paused);
    event ConfigScheduled(address treasury, uint256 launchFeeWei, uint16 protocolLpFeeBps, uint64 eta);
    event ConfigCancelled();

    // ---------------------------------------------------------------- errors

    error LaunchesPaused();
    error ZeroAddress();
    error InvalidName();
    error InvalidSymbol();
    error InvalidMetadataURI();
    error InvalidTotalSupply();
    error InvalidQuoteToken();
    error UnsupportedFeeTier();
    error TickNotAligned();
    error TickOutOfRange();
    error InvalidPositions();
    error InvalidBps();
    error IncorrectNativeValue();
    error SlippageExceeded(uint256 received, uint256 minimum);
    error InitialBuyTooLarge(uint256 tokensOut, uint256 max);
    error UnexpectedSwapCallback();
    error ConfigOutOfBounds();
    error NativeTransferFailed();
    error PoolPriceMismatch();
    error LaunchFeeAboveCap(uint256 currentFee, uint256 consentedMax);
    error NoPendingConfig();
    error ConfigNotReady(uint64 eta);
    error ConfigExpired(uint64 eta);
    error RenounceDisabled();

    constructor(
        IPancakeV3Factory pancakeV3Factory_,
        INonfungiblePositionManager positionManager_,
        address wbnb_,
        address owner_,
        address treasury_,
        uint256 launchFeeWei_,
        uint16 protocolLpFeeBps_
    ) Ownable(owner_) {
        if (address(pancakeV3Factory_) == address(0) || address(positionManager_) == address(0) || wbnb_ == address(0))
        {
            revert ZeroAddress();
        }
        if (treasury_ == address(0)) revert ZeroAddress();
        if (launchFeeWei_ > MAX_LAUNCH_FEE || protocolLpFeeBps_ > MAX_PROTOCOL_LP_FEE_BPS) revert ConfigOutOfBounds();
        pancakeV3Factory = pancakeV3Factory_;
        positionManager = positionManager_;
        wbnb = wbnb_;
        treasury = treasury_;
        launchFeeWei = launchFeeWei_;
        protocolLpFeeBps = protocolLpFeeBps_;
        locker = new CateFamilyLiquidityLocker(positionManager_, address(this));
    }

    // ---------------------------------------------------------------- launch

    /// @notice Launches a token. See contract docs for the full lifecycle.
    /// Native value rules: send exactly `launchFeeWei` (initial buy pulled from
    /// quote-token allowance), or `launchFeeWei + initialBuyQuoteAmount` when
    /// the quote is WBNB and the first buy is paid in native BNB.
    function launch(LaunchParams calldata params)
        external
        payable
        nonReentrant
        returns (address token, address pool, uint256[] memory positionIds)
    {
        if (paused) revert LaunchesPaused();
        int24 tickSpacing = _validate(params);
        uint256 nativeBuyWei = _collectLaunchFee(params);

        token = _deployToken(params);
        bool tokenIsToken0 = token < params.quoteToken;

        uint256 tokensSold;
        (pool, tokensSold) = _createPool(token, params, tokenIsToken0);
        positionIds = _mintLockedPositions(token, pool, params, tokenIsToken0, tickSpacing, params.totalSupply - tokensSold);

        launches[token] = LaunchRecord({
            token: token,
            quoteToken: params.quoteToken,
            pool: pool,
            creator: msg.sender,
            fee: params.fee,
            launchedAtBlock: uint64(block.number)
        });
        totalLaunches += 1;

        _emitLaunch(token, pool, params, positionIds);

        if (params.initialBuyQuoteAmount > 0) {
            _executeInitialBuy(token, pool, params, tokenIsToken0, nativeBuyWei);
        }
    }

    /// @notice Predicts the CREATE2 address a launch will deploy its token at,
    /// so creators can pre-verify or vanity-mine `salt` off-chain.
    function predictTokenAddress(
        address creator,
        bytes32 salt,
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        string calldata metadataURI
    ) external view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(CateFamilyToken).creationCode,
                abi.encode(name, symbol, totalSupply, address(this), metadataURI, creator)
            )
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), keccak256(abi.encode(creator, salt)), initCodeHash
                        )
                    )
                )
            )
        );
    }

    // ------------------------------------------------------------- internals

    /// @dev Split out purely to keep `launch` inside the stack limit; the
    /// strings are copied to memory first because calldata slices cost two
    /// stack slots each, which is exactly what pushed the event over.
    function _emitLaunch(address token, address pool, LaunchParams calldata params, uint256[] memory positionIds)
        internal
    {
        string memory name = params.name;
        string memory symbol = params.symbol;
        string memory metadataURI = params.metadataURI;
        emit TokenLaunched(
            token,
            msg.sender,
            params.quoteToken,
            pool,
            params.fee,
            params.initialTick,
            params.totalSupply,
            positionIds,
            name,
            symbol,
            metadataURI
        );
    }

    function _validate(LaunchParams calldata params) internal view returns (int24 tickSpacing) {
        if (bytes(params.name).length == 0 || bytes(params.name).length > 64) revert InvalidName();
        if (bytes(params.symbol).length == 0 || bytes(params.symbol).length > 32) revert InvalidSymbol();
        if (bytes(params.metadataURI).length > 2048) revert InvalidMetadataURI();
        if (params.totalSupply < MIN_TOTAL_SUPPLY || params.totalSupply > MAX_TOTAL_SUPPLY) revert InvalidTotalSupply();
        if (params.quoteToken == address(0) || params.quoteToken.code.length == 0) revert InvalidQuoteToken();

        tickSpacing = pancakeV3Factory.feeAmountTickSpacing(params.fee);
        if (tickSpacing <= 0) revert UnsupportedFeeTier();

        int24 maxUsableTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        if (params.initialTick % tickSpacing != 0) revert TickNotAligned();
        // Both bounds strict: a mirrored launch negates the tick, and pool
        // initialization at exactly ±MAX_TICK is rejected by TickMath.
        if (params.initialTick <= -maxUsableTick || params.initialTick >= maxUsableTick) revert TickOutOfRange();

        uint256 count = params.positions.length;
        if (count > MAX_POSITIONS) revert InvalidPositions();
        uint256 bpsSum = 0;
        for (uint256 i = 0; i < count; i++) {
            LiquidityPosition calldata p = params.positions[i];
            if (p.tickLower % tickSpacing != 0 || p.tickUpper % tickSpacing != 0) revert TickNotAligned();
            if (p.tickLower < params.initialTick || p.tickUpper <= p.tickLower || p.tickUpper > maxUsableTick) {
                revert InvalidPositions();
            }
            if (p.bps == 0) revert InvalidBps();
            bpsSum += p.bps;
        }
        if (count > 0 && bpsSum != BPS_DENOMINATOR) revert InvalidBps();
    }

    function _collectLaunchFee(LaunchParams calldata params) internal returns (uint256 nativeBuyWei) {
        uint256 fee_ = launchFeeWei;
        if (fee_ > params.maxLaunchFeeWei) revert LaunchFeeAboveCap(fee_, params.maxLaunchFeeWei);
        if (msg.value < fee_) revert IncorrectNativeValue();
        nativeBuyWei = msg.value - fee_;
        if (
            nativeBuyWei != 0
                && (params.quoteToken != wbnb || nativeBuyWei != params.initialBuyQuoteAmount)
        ) {
            revert IncorrectNativeValue();
        }
        if (fee_ > 0) {
            (bool ok,) = treasury.call{value: fee_}("");
            if (!ok) revert NativeTransferFailed();
        }
    }

    function _deployToken(LaunchParams calldata params) internal returns (address) {
        CateFamilyToken token = new CateFamilyToken{salt: keccak256(abi.encode(msg.sender, params.salt))}(
            params.name, params.symbol, params.totalSupply, address(this), params.metadataURI, msg.sender
        );
        return address(token);
    }

    function _createPool(address token, LaunchParams calldata params, bool tokenIsToken0)
        internal
        returns (address pool, uint256 tokensSold)
    {
        (address token0, address token1) =
            tokenIsToken0 ? (token, params.quoteToken) : (params.quoteToken, token);
        int24 poolTick = tokenIsToken0 ? params.initialTick : -params.initialTick;
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(poolTick);
        pool = positionManager.createAndInitializePoolIfNecessary(token0, token1, params.fee, sqrtPriceX96);
        // A mempool front-runner could pre-create this pool at a hostile price
        // (createAndInitializePoolIfNecessary never re-initializes) and park
        // quote bids in the way. The restore below sells through them with
        // the supply this factory holds (audit findings M-02 / M-05).
        (uint160 actualSqrtPriceX96,,,,,,) = IPancakeV3Pool(pool).slot0();
        if (actualSqrtPriceX96 != sqrtPriceX96) {
            uint256 quoteReceived;
            (tokensSold, quoteReceived) = _restorePrice(
                pool, token, tokenIsToken0, params.totalSupply, actualSqrtPriceX96, sqrtPriceX96
            );
            if (tokensSold > 0) {
                // Whoever parked the bid bought above the opening price; the
                // proceeds belong to the creator whose launch was targeted.
                _payQuote(params.quoteToken, msg.sender, quoteReceived);
                emit PriceRestoredBySale(token, pool, tokensSold, quoteReceived);
            }
        }
    }

    /// @dev Moves a pre-created, mispriced pool to `target`.
    ///
    /// The token did not exist before this transaction, so any liquidity in
    /// such a pool is quote-only and sits on one side of the price. Moving
    /// towards the token's side crosses nothing and is free; moving the other
    /// way may cross parked quote bids, all of them priced above the opening
    /// price. The restore therefore pays only in the launched token — at most
    /// MAX_RESTORE_BPS of the supply — and never in quote. A dust bid costs
    /// its owner their dust; a bid deep enough to absorb the cap has bought
    /// tokens above the opening price from the creator. Reverts with
    /// `PoolPriceMismatch` if the price still did not land exactly on target.
    function _restorePrice(
        address pool,
        address token,
        bool tokenIsToken0,
        uint256 totalSupply,
        uint160 current,
        uint160 target
    ) internal returns (uint256 tokensSold, uint256 quoteReceived) {
        bool zeroForOne = current > target; // selling token0 moves the price down
        bool payingInToken = zeroForOne == tokenIsToken0;
        _activeSwapPool = pool;
        _restoring = true;
        _activeSwapToken = payingInToken ? token : address(0);
        (int256 amount0, int256 amount1) = IPancakeV3Pool(pool).swap(
            address(this),
            zeroForOne,
            payingInToken ? int256((totalSupply * MAX_RESTORE_BPS) / BPS_DENOMINATOR) : int256(1),
            target,
            ""
        );
        _restoring = false;
        _activeSwapPool = address(0);
        _activeSwapToken = address(0);
        (uint160 actual,,,,,,) = IPancakeV3Pool(pool).slot0();
        if (actual != target) revert PoolPriceMismatch();
        (int256 tokenDelta, int256 quoteDelta) = tokenIsToken0 ? (amount0, amount1) : (amount1, amount0);
        if (quoteDelta > 0) revert PoolPriceMismatch(); // never pays quote
        if (tokenDelta > 0) tokensSold = uint256(tokenDelta);
        if (quoteDelta < 0) quoteReceived = uint256(-quoteDelta);
    }

    /// @dev Pays `amount` of `quote` to `to`, unwrapping WBNB to native BNB.
    function _payQuote(address quote, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (quote == wbnb) {
            IWBNB(wbnb).withdraw(amount);
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(quote).safeTransfer(to, amount);
        }
    }

    function _mintLockedPositions(
        address token,
        address pool,
        LaunchParams calldata params,
        bool tokenIsToken0,
        int24 tickSpacing,
        uint256 supply
    ) internal returns (uint256[] memory positionIds) {
        pool; // pool creation already happened; kept for call-site clarity
        IERC20(token).forceApprove(address(positionManager), supply);

        uint256 count = params.positions.length == 0 ? 1 : params.positions.length;
        positionIds = new uint256[](count);
        uint256 remaining = supply;
        address creatorRecipient =
            params.creatorFeeRecipient == address(0) ? msg.sender : params.creatorFeeRecipient;
        uint16 protocolBps = protocolLpFeeBps;

        for (uint256 i = 0; i < count; i++) {
            (int24 lower, int24 upper, uint256 amount) = _positionSlice(params, tickSpacing, i, count, remaining, supply);
            remaining -= amount;
            (int24 mintLower, int24 mintUpper) = tokenIsToken0 ? (lower, upper) : (-upper, -lower);

            (uint256 tokenId,,,) = positionManager.mint(
                INonfungiblePositionManager.MintParams({
                    token0: tokenIsToken0 ? token : params.quoteToken,
                    token1: tokenIsToken0 ? params.quoteToken : token,
                    fee: params.fee,
                    tickLower: mintLower,
                    tickUpper: mintUpper,
                    amount0Desired: tokenIsToken0 ? amount : 0,
                    amount1Desired: tokenIsToken0 ? 0 : amount,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(locker),
                    deadline: block.timestamp
                })
            );
            positionIds[i] = tokenId;
            locker.assignPosition(tokenId, token, creatorRecipient, protocolBps);
        }

        IERC20(token).forceApprove(address(positionManager), 0);
        // Rounding leaves a few wei of the supply unplaced; burn them so the
        // entire supply is either pool liquidity or holder balances.
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) IERC20(token).safeTransfer(DEAD, dust);
    }

    function _positionSlice(
        LaunchParams calldata params,
        int24 tickSpacing,
        uint256 i,
        uint256 count,
        uint256 remaining,
        uint256 supply
    ) internal pure returns (int24 lower, int24 upper, uint256 amount) {
        if (params.positions.length == 0) {
            lower = params.initialTick;
            upper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
            amount = remaining;
        } else {
            LiquidityPosition calldata p = params.positions[i];
            lower = p.tickLower;
            upper = p.tickUpper;
            amount = i == count - 1 ? remaining : (supply * p.bps) / BPS_DENOMINATOR;
        }
    }

    function _executeInitialBuy(
        address token,
        address pool,
        LaunchParams calldata params,
        bool tokenIsToken0,
        uint256 nativeBuyWei
    ) internal {
        uint256 amountIn = params.initialBuyQuoteAmount;
        bool fundedNatively = nativeBuyWei > 0;
        if (fundedNatively) {
            IWBNB(wbnb).deposit{value: nativeBuyWei}();
        } else {
            IERC20(params.quoteToken).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        address recipient = params.initialBuyRecipient == address(0) ? msg.sender : params.initialBuyRecipient;
        bool zeroForOne = !tokenIsToken0; // selling quote for token
        _activeSwapPool = pool;
        (int256 amount0, int256 amount1) = IPancakeV3Pool(pool).swap(
            recipient,
            zeroForOne,
            int256(amountIn),
            _initialBuyPriceLimit(params.initialTick, tokenIsToken0),
            abi.encode(params.quoteToken)
        );
        _activeSwapPool = address(0);

        uint256 tokensOut = uint256(-(zeroForOne ? amount1 : amount0));
        uint256 quoteSpent = uint256(zeroForOne ? amount0 : amount1);
        if (tokensOut < params.initialBuyMinTokensOut) {
            revert SlippageExceeded(tokensOut, params.initialBuyMinTokensOut);
        }
        uint256 maxTokens = (params.totalSupply * MAX_INITIAL_BUY_BPS) / BPS_DENOMINATOR;
        if (tokensOut > maxTokens) revert InitialBuyTooLarge(tokensOut, maxTokens);

        // Refund whatever the pool did not consume: the buy hit the first-buy
        // price limit, or swept past the top of the liquidity range. Tracked
        // arithmetic, not balanceOf: stray donations to the factory are never
        // handed out.
        uint256 leftover = amountIn - quoteSpent;
        if (leftover > 0) {
            if (fundedNatively) {
                IWBNB(wbnb).withdraw(leftover);
                (bool ok,) = msg.sender.call{value: leftover}("");
                if (!ok) revert NativeTransferFailed();
            } else {
                IERC20(params.quoteToken).safeTransfer(msg.sender, leftover);
            }
        }

        emit InitialBuyExecuted(token, recipient, quoteSpent, tokensOut);
    }

    /// @dev The first buy stops MAX_INITIAL_BUY_TICKS above the open; whatever
    /// it cannot fill by then is refunded by the caller.
    function _initialBuyPriceLimit(int24 initialTick, bool tokenIsToken0) internal pure returns (uint160) {
        int24 limitTick = initialTick + MAX_INITIAL_BUY_TICKS;
        if (limitTick > TickMath.MAX_TICK - 1) limitTick = TickMath.MAX_TICK - 1;
        return TickMath.getSqrtRatioAtTick(tokenIsToken0 ? limitTick : -limitTick);
    }

    /// @inheritdoc IPancakeV3SwapCallback
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        address pool = _activeSwapPool;
        if (pool == address(0) || msg.sender != pool) revert UnexpectedSwapCallback();
        if (_restoring) {
            // A price restore pays only in the launched token (see _restorePrice).
            address token = _activeSwapToken;
            if (amount0Delta > 0) {
                if (token == address(0) || IPancakeV3Pool(pool).token0() != token) revert PoolPriceMismatch();
                IERC20(token).safeTransfer(pool, uint256(amount0Delta));
            }
            if (amount1Delta > 0) {
                if (token == address(0) || IPancakeV3Pool(pool).token1() != token) revert PoolPriceMismatch();
                IERC20(token).safeTransfer(pool, uint256(amount1Delta));
            }
            return;
        }
        address quoteToken = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        if (owed > 0) IERC20(quoteToken).safeTransfer(pool, owed);
    }

    /// @dev Accepts BNB only while unwrapping WBNB for initial-buy refunds.
    receive() external payable {
        if (msg.sender != wbnb) revert IncorrectNativeValue();
    }

    // ----------------------------------------------------------------- admin
    //
    // Every economic parameter change is scheduled, waits CONFIG_DELAY, and is
    // then applied by anyone. The owner key can therefore never redirect
    // fees or change a price the moment it acts: a change is public for two
    // days first, creators can collect what has accrued to the current
    // treasury, and an unexpected schedule is the alarm. Pausing new launches
    // stays immediate because it moves no value. Ownership itself is
    // two-step and cannot be renounced (audit finding H-01).

    /// @notice Schedules a full configuration; takes effect after CONFIG_DELAY.
    /// Pass the current value for anything that should not change.
    function scheduleConfig(address treasury_, uint256 launchFeeWei_, uint16 protocolLpFeeBps_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (launchFeeWei_ > MAX_LAUNCH_FEE || protocolLpFeeBps_ > MAX_PROTOCOL_LP_FEE_BPS) revert ConfigOutOfBounds();
        uint64 eta = uint64(block.timestamp + CONFIG_DELAY);
        pendingConfig = PendingConfig({
            treasury: treasury_, launchFeeWei: launchFeeWei_, protocolLpFeeBps: protocolLpFeeBps_, eta: eta
        });
        emit ConfigScheduled(treasury_, launchFeeWei_, protocolLpFeeBps_, eta);
    }

    /// @notice Applies the scheduled configuration once its delay has passed.
    /// Callable by anyone, so a change the owner scheduled cannot be held
    /// hostage by the owner going quiet either.
    function applyConfig() external {
        PendingConfig memory p = pendingConfig;
        if (p.eta == 0) revert NoPendingConfig();
        if (block.timestamp < p.eta) revert ConfigNotReady(p.eta);
        if (block.timestamp > p.eta + CONFIG_EXPIRY) revert ConfigExpired(p.eta);
        delete pendingConfig;
        treasury = p.treasury;
        launchFeeWei = p.launchFeeWei;
        protocolLpFeeBps = p.protocolLpFeeBps;
        emit TreasuryUpdated(p.treasury);
        emit LaunchFeeUpdated(p.launchFeeWei);
        emit ProtocolLpFeeUpdated(p.protocolLpFeeBps);
    }

    /// @notice Withdraws a scheduled configuration before it applies.
    function cancelConfig() external onlyOwner {
        if (pendingConfig.eta == 0) revert NoPendingConfig();
        delete pendingConfig;
        emit ConfigCancelled();
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @dev Renouncing would freeze the fee configuration forever; refuse.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
