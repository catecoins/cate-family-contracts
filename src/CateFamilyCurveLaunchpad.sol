// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "./lib/TickMath.sol";
import {CateFamilyCurveToken} from "./CateFamilyCurveToken.sol";
import {CateFamilyLiquidityLocker} from "./CateFamilyLiquidityLocker.sol";
import {
    IPancakeV3Factory,
    IPancakeV3Pool,
    IPancakeV3SwapCallback,
    INonfungiblePositionManager,
    IWBNB
} from "./interfaces/IPancakeV3.sol";

/// @title CateFamilyCurveLaunchpad
/// @notice pump.fun-style bonding curves on BNB Chain, graduating into locked
/// PancakeSwap V3 liquidity.
///
/// One contract holds every curve. A launch mints a fixed 1,000,000,000-token
/// supply: 800,000,000 are sold on a constant-product curve held here, and
/// 200,000,000 are reserved for the pool. Buyers pay the quote asset (BNB or
/// an allow-listed BEP20); sellers get it back, minus a fee, at any time
/// before the curve sells out. Until graduation the token cannot move
/// anywhere but to and from this contract.
///
/// When the last curve token is sold, anyone may call `graduate`: a Pancake
/// V3 pool is created at the curve's final price, a graduation fee is taken
/// from the raise, and the reserved tokens plus the raise are minted as
/// locked liquidity into this contract's own CateFamilyLiquidityLocker — a
/// two-sided position at the final price, and a quote-only standing bid from
/// the opening price up to it for whatever quote the two-sided position
/// could not absorb. Fees from both positions flow to the creator and the
/// protocol exactly as for every other launch. The token's transfer
/// restriction lifts inside the same transaction.
///
/// Every preset opens at the same market cap; the graduation cap sets how
/// steep the curve is. Both are chosen per launch, in quote units, inside
/// bounds the allow-list sets for that quote asset.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
contract CateFamilyCurveLaunchpad is Ownable2Step, ReentrancyGuard, IPancakeV3SwapCallback {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    struct Config {
        /// @dev Receives protocol fees (curve trade fees, graduation fees, the
        /// protocol share of locked-liquidity fees).
        address treasury;
        /// @dev Fee on the quote side of every curve buy and sell, bps.
        uint16 curveFeeBps;
        /// @dev Cut of the raise taken at graduation, bps.
        uint16 graduationFeeBps;
        /// @dev Protocol share of the locked positions' swap fees after graduation, bps.
        uint16 protocolLpFeeBps;
        /// @dev Length of the opening window after creation, in blocks. Zero
        /// turns the window off: no per-wallet cap and contracts may buy at
        /// once (the production default since 15 September 2026).
        uint32 openingWindowBlocks;
        /// @dev Most of the curve supply one wallet may hold during the window, bps.
        uint16 openingWalletCapBps;
    }

    struct PendingConfig {
        Config config;
        uint64 eta;
    }

    struct QuoteConfig {
        bool allowed;
        /// @dev Bounds in quote-asset units for the caps a launch may choose.
        uint256 minOpeningCap;
        uint256 minGraduationCap;
        uint256 maxGraduationCap;
    }

    struct PendingQuoteConfig {
        QuoteConfig config;
        uint64 eta;
    }

    struct CreateParams {
        string name;
        string symbol;
        string metadataURI;
        address quoteToken;
        /// @dev Market cap at the first token sold, in quote units (e.g. $5,000 in USDT wei).
        uint256 openingCap;
        /// @dev Market cap when the curve sells out, in quote units.
        uint256 graduationCap;
        /// @dev Receiver of the creator share of post-graduation LP fees; zero = caller.
        address creatorFeeRecipient;
        /// @dev Optional creator-only first buy, in quote units; capped.
        uint256 firstBuyQuote;
        uint256 firstBuyMinTokensOut;
        /// @dev Who receives the first buy's tokens; zero = caller. Lets a
        /// platform launch on a client's behalf and hand the client the
        /// tokens directly, since they cannot be transferred before graduation.
        address firstBuyRecipient;
        bytes32 salt;
    }

    struct Curve {
        address quoteToken;
        address creator;
        address creatorFeeRecipient;
        /// @dev Virtual reserves and their constant product.
        uint256 x;
        uint256 y;
        uint256 k;
        uint256 x0;
        uint256 y0;
        /// @dev Real state: curve tokens not yet sold, quote held for sellers.
        uint256 tokensRemaining;
        uint256 quoteRaised;
        /// @dev Per-launch snapshots.
        uint16 curveFeeBps;
        uint16 graduationFeeBps;
        uint16 protocolLpFeeBps;
        uint256 walletCap;
        uint64 openingWindowEnd;
        uint64 createdAtBlock;
        uint64 graduatedAtBlock;
        bool soldOut;
        bool graduated;
        address pool;
    }

    // ------------------------------------------------------------- constants

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant POOL_SUPPLY = TOTAL_SUPPLY - CURVE_SUPPLY;
    /// @notice Most of the curve supply the creator's first buy may take: all
    /// of it. A first buy that takes the whole curve sells it out inside the
    /// create transaction, and it graduates on the next one like any other
    /// sold-out curve. (15 September 2026: no cap on any buy, the creator's
    /// included; the check below stays as the documented ceiling.)
    uint256 public constant MAX_CREATOR_BUY_BPS = 10_000;
    /// @notice Graduation cap must be between these multiples of the opening cap.
    uint256 public constant MIN_MULTIPLE = 2;
    uint256 public constant MAX_MULTIPLE = 25;
    uint16 public constant MAX_CURVE_FEE_BPS = 300;
    uint16 public constant MAX_GRADUATION_FEE_BPS = 1000;
    uint16 public constant MAX_PROTOCOL_LP_FEE_BPS = 5000;
    uint16 public constant MAX_WALLET_CAP_BPS = 10_000;
    /// @notice Pancake fee tier of the graduated pool (1%, spacing 200).
    uint24 public constant POOL_FEE = 10000;
    int24 internal constant POOL_TICK_SPACING = 200;
    uint256 public constant CONFIG_DELAY = 48 hours;
    /// @notice A scheduled change not applied within this long after its delay
    /// lapses: notice cannot be banked and applied at a moment of choice.
    uint256 public constant CONFIG_EXPIRY = 7 days;
    /// @notice If a sold-out curve has not graduated after this long, sells
    /// reopen at the curve's price so nobody's money can be held hostage by a
    /// graduation that cannot complete (see `exitOpen`).
    uint256 public constant GRADUATION_GRACE = 24 hours;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ------------------------------------------------------------ immutables

    IPancakeV3Factory public immutable pancakeV3Factory;
    INonfungiblePositionManager public immutable positionManager;
    address public immutable wbnb;
    CateFamilyLiquidityLocker public immutable locker;

    // ---------------------------------------------------------------- state

    Config public config;
    PendingConfig public pendingConfig;
    mapping(address quote => QuoteConfig) public quoteConfig;
    mapping(address quote => PendingQuoteConfig) public pendingQuoteConfig;
    /// @notice Pauses creates and buys only. Sells and graduation never pause.
    bool public paused;

    mapping(address token => Curve) internal _curves;
    uint256 public totalLaunches;
    /// @notice Protocol fees accrued per quote asset, claimable to the treasury.
    mapping(address quote => uint256) public protocolFees;

    address private _activeSwapPool;
    /// @dev The launched token the price-restore swap may pay with; never the quote.
    address private _activeSwapToken;
    /// @notice When each curve sold out (timestamp), for the graduation grace period.
    mapping(address token => uint64) public soldOutAt;

    // ---------------------------------------------------------------- events

    event CurveCreated(
        address indexed token,
        address indexed creator,
        address indexed quoteToken,
        uint256 openingCap,
        uint256 graduationCap,
        uint256 x0,
        uint256 y0,
        uint64 openingWindowEnd,
        string name,
        string symbol,
        string metadataURI
    );
    event CurveBuy(address indexed token, address indexed buyer, uint256 quoteIn, uint256 fee, uint256 tokensOut);
    event CurveSell(address indexed token, address indexed seller, uint256 tokensIn, uint256 fee, uint256 quoteOut);
    event CurveSoldOut(address indexed token, uint256 quoteRaised);
    /// @notice A sell after the graduation grace period put tokens back on a
    /// sold-out curve; it is open again and can sell out (and graduate) later.
    event CurveReopened(address indexed token);
    /// @notice The restore had to sell launched tokens through parked bids
    /// above the graduation price; the quote received went into the pool.
    event PriceRestoredBySale(address indexed token, uint256 tokensSold, uint256 quoteReceived);
    event Graduated(
        address indexed token,
        address indexed pool,
        uint256[] positionIds,
        uint256 tokensInPool,
        uint256 quoteInPool,
        uint256 graduationFee
    );
    event ProtocolFeesClaimed(address indexed quote, address indexed treasury, uint256 amount);
    event ConfigScheduled(Config config, uint64 eta);
    event ConfigApplied(Config config);
    event ConfigCancelled();
    event QuoteConfigScheduled(address indexed quote, QuoteConfig config, uint64 eta);
    event QuoteConfigApplied(address indexed quote, QuoteConfig config);
    event PausedSet(bool paused);

    // ---------------------------------------------------------------- errors

    error Paused();
    error ZeroAddress();
    error InvalidName();
    error InvalidSymbol();
    error InvalidMetadataURI();
    error QuoteNotAllowed();
    error CapOutOfBounds();
    error UnknownCurve();
    error CurveClosed();
    error CurveNotSoldOut();
    error AlreadyGraduated();
    error IncorrectNativeValue();
    error ZeroAmount();
    error SlippageExceeded(uint256 received, uint256 minimum);
    error WalletCapExceeded(uint256 wouldHold, uint256 cap);
    error ContractsWaitForTheWindow();
    error CreatorBuyTooLarge(uint256 tokensOut, uint256 max);
    error ConfigOutOfBounds();
    error NoPendingConfig();
    error ConfigNotReady(uint64 eta);
    error ConfigExpired(uint64 eta);
    error RenounceDisabled();
    error UnexpectedSwapCallback();
    error PoolPriceMismatch();
    error NativeTransferFailed();
    error NothingToClaim();

    constructor(
        IPancakeV3Factory pancakeV3Factory_,
        INonfungiblePositionManager positionManager_,
        address wbnb_,
        address owner_,
        Config memory initial,
        address[] memory quotes,
        QuoteConfig[] memory quoteConfigs
    ) Ownable(owner_) {
        if (address(pancakeV3Factory_) == address(0) || address(positionManager_) == address(0) || wbnb_ == address(0))
        {
            revert ZeroAddress();
        }
        _validateConfig(initial);
        pancakeV3Factory = pancakeV3Factory_;
        positionManager = positionManager_;
        wbnb = wbnb_;
        config = initial;
        locker = new CateFamilyLiquidityLocker(positionManager_, address(this));
        if (quotes.length != quoteConfigs.length) revert ConfigOutOfBounds();
        for (uint256 i = 0; i < quotes.length; i++) {
            if (quotes[i] == address(0)) revert ZeroAddress();
            quoteConfig[quotes[i]] = quoteConfigs[i];
            emit QuoteConfigApplied(quotes[i], quoteConfigs[i]);
        }
    }

    // ---------------------------------------------------------------- views

    function curves(address token) external view returns (Curve memory) {
        return _curves[token];
    }

    /// @notice Live treasury, read by the locker (ICateFamilyFeeConfig) and
    /// by fee splitters at collection time.
    function treasury() external view returns (address) {
        return config.treasury;
    }

    /// @notice Shaped like CateFamilyFactory.launches so the holder distributor
    /// and fee splitter work unchanged after graduation.
    function launches(address token)
        external
        view
        returns (address token_, address quoteToken, address pool, address creator, uint24 fee, uint64 launchedAtBlock)
    {
        Curve storage c = _curves[token];
        return (c.creator == address(0) ? address(0) : token, c.quoteToken, c.pool, c.creator, POOL_FEE, c.graduatedAtBlock);
    }

    /// @notice Tokens received for `quoteIn` of quote (fee included), and the
    /// quote actually charged if the curve sells out first.
    function quoteBuy(address token, uint256 quoteIn) external view returns (uint256 tokensOut, uint256 quoteCharged) {
        Curve storage c = _curves[token];
        if (c.creator == address(0)) revert UnknownCurve();
        (tokensOut, quoteCharged,) = _buyAmounts(c, quoteIn);
    }

    /// @notice Quote received for `tokensIn`, after the fee.
    function quoteSell(address token, uint256 tokensIn) external view returns (uint256 quoteOut) {
        Curve storage c = _curves[token];
        if (c.creator == address(0)) revert UnknownCurve();
        (quoteOut,,) = _sellAmounts(c, tokensIn);
    }

    /// @notice True when a sold-out curve has waited out GRADUATION_GRACE
    /// without graduating: sells are accepted again at the curve's price.
    function exitOpen(address token) public view returns (bool) {
        Curve storage c = _curves[token];
        return c.soldOut && !c.graduated && soldOutAt[token] != 0
            && block.timestamp > uint256(soldOutAt[token]) + GRADUATION_GRACE;
    }

    /// @notice Current price in quote per token, 1e18-scaled.
    function price(address token) external view returns (uint256) {
        Curve storage c = _curves[token];
        return Math.mulDiv(c.y, WAD, c.x);
    }

    // --------------------------------------------------------------- create

    function create(CreateParams calldata p) external payable nonReentrant returns (address token) {
        if (paused) revert Paused();
        _validateCreate(p);

        token = address(
            new CateFamilyCurveToken{salt: keccak256(abi.encode(msg.sender, p.salt))}(
                p.name, p.symbol, TOTAL_SUPPLY, address(this), p.metadataURI, msg.sender
            )
        );

        Curve storage c = _curves[token];
        c.quoteToken = p.quoteToken;
        c.creator = msg.sender;
        c.creatorFeeRecipient = p.creatorFeeRecipient == address(0) ? msg.sender : p.creatorFeeRecipient;
        (c.x0, c.y0) = _reserves(p.openingCap, p.graduationCap);
        c.x = c.x0;
        c.y = c.y0;
        c.k = c.x0 * c.y0;
        // The final reserves are fixed now; make sure the pool price they imply
        // is one Pancake can hold, so graduation can never be the first to fail.
        _sqrtPrice(c.x0 - CURVE_SUPPLY, Math.ceilDiv(c.k, c.x0 - CURVE_SUPPLY), token < p.quoteToken);
        c.tokensRemaining = CURVE_SUPPLY;
        Config memory cfg = config;
        c.curveFeeBps = cfg.curveFeeBps;
        c.graduationFeeBps = cfg.graduationFeeBps;
        c.protocolLpFeeBps = cfg.protocolLpFeeBps;
        c.walletCap = (CURVE_SUPPLY * cfg.openingWalletCapBps) / BPS;
        c.openingWindowEnd = uint64(block.number + cfg.openingWindowBlocks);
        c.createdAtBlock = uint64(block.number);
        totalLaunches += 1;

        emit CurveCreated(
            token, msg.sender, p.quoteToken, p.openingCap, p.graduationCap, c.x0, c.y0, c.openingWindowEnd, p.name, p.symbol, p.metadataURI
        );

        if (p.firstBuyQuote > 0) {
            address recipient = p.firstBuyRecipient == address(0) ? msg.sender : p.firstBuyRecipient;
            uint256 tokensOut = _buy(token, c, msg.sender, recipient, p.firstBuyQuote, p.firstBuyMinTokensOut, true);
            uint256 max = (CURVE_SUPPLY * MAX_CREATOR_BUY_BPS) / BPS;
            if (tokensOut > max) revert CreatorBuyTooLarge(tokensOut, max);
        } else if (msg.value != 0) {
            revert IncorrectNativeValue();
        }
    }

    function predictTokenAddress(
        address creator,
        bytes32 salt,
        string calldata name,
        string calldata symbol,
        string calldata metadataURI
    ) external view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(CateFamilyCurveToken).creationCode,
                abi.encode(name, symbol, TOTAL_SUPPLY, address(this), metadataURI, creator)
            )
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), keccak256(abi.encode(creator, salt)), initCodeHash)
                    )
                )
            )
        );
    }

    // ------------------------------------------------------------ buy / sell

    /// @notice Buys with `quoteIn` of the curve's quote asset. Send native
    /// value equal to `quoteIn` when the quote is WBNB; otherwise approve.
    /// Anything the curve cannot fill (it sells out) is refunded.
    function buy(address token, uint256 quoteIn, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (paused) revert Paused();
        Curve storage c = _curves[token];
        if (c.creator == address(0)) revert UnknownCurve();
        tokensOut = _buy(token, c, msg.sender, msg.sender, quoteIn, minTokensOut, false);
    }

    /// @notice Sells `tokensIn` back to the curve. Always available before the
    /// curve sells out, even while the launchpad is paused.
    function sell(address token, uint256 tokensIn, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        Curve storage c = _curves[token];
        if (c.creator == address(0)) revert UnknownCurve();
        if (c.graduated) revert CurveClosed();
        // A sold-out curve is closed only while graduation is still expected.
        // Once the grace period has passed without one, sellers may leave at
        // the curve's price; the first sell puts tokens back and reopens it.
        if (c.soldOut && !exitOpen(token)) revert CurveClosed();
        if (tokensIn == 0) revert ZeroAmount();

        uint256 fee;
        uint256 newY;
        (quoteOut, fee, newY) = _sellAmounts(c, tokensIn);
        if (quoteOut < minQuoteOut) revert SlippageExceeded(quoteOut, minQuoteOut);

        // Effects.
        c.x += tokensIn;
        c.y = newY;
        c.tokensRemaining += tokensIn;
        c.quoteRaised -= quoteOut + fee;
        protocolFees[c.quoteToken] += fee;
        if (c.soldOut) {
            c.soldOut = false;
            soldOutAt[token] = 0;
            emit CurveReopened(token);
        }

        // Interactions: pull the tokens (to == curve is always allowed), pay out.
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        _payQuote(c.quoteToken, msg.sender, quoteOut);
        emit CurveSell(token, msg.sender, tokensIn, fee, quoteOut);
    }

    /// @dev `payer` provides the quote and gets any refund; `recipient` gets
    /// the tokens. They differ only for a creator's first buy made on someone
    /// else's behalf; a public buy is always to the payer.
    function _buy(
        address token,
        Curve storage c,
        address payer,
        address recipient,
        uint256 quoteIn,
        uint256 minTokensOut,
        bool creatorBuy
    ) internal returns (uint256 tokensOut) {
        if (c.soldOut) revert CurveClosed();
        if (quoteIn == 0) revert ZeroAmount();

        // Collect the quote first so a fee-on-transfer asset only short-changes itself.
        uint256 credited = _collectQuote(c.quoteToken, payer, quoteIn);

        uint256 charged;
        uint256 net;
        (tokensOut, charged, net) = _buyAmounts(c, credited);
        if (tokensOut < minTokensOut) revert SlippageExceeded(tokensOut, minTokensOut);
        if (!creatorBuy && block.number < c.openingWindowEnd) {
            // The per-wallet cap is worthless against one transaction that
            // spawns fresh contract wallets; during the window only externally
            // owned accounts may buy, so a sniper needs a funded key per slot.
            if (payer != tx.origin) revert ContractsWaitForTheWindow();
            uint256 wouldHold = IERC20(token).balanceOf(recipient) + tokensOut;
            if (wouldHold > c.walletCap) revert WalletCapExceeded(wouldHold, c.walletCap);
        }

        // Effects.
        uint256 fee = charged - net;
        c.x -= tokensOut;
        c.y += net;
        c.tokensRemaining -= tokensOut;
        c.quoteRaised += net;
        protocolFees[c.quoteToken] += fee;
        if (c.tokensRemaining == 0) {
            c.soldOut = true;
            soldOutAt[token] = uint64(block.timestamp);
            emit CurveSoldOut(token, c.quoteRaised);
        }
        emit CurveBuy(token, recipient, charged, fee, tokensOut);

        // Interactions.
        IERC20(token).safeTransfer(recipient, tokensOut);
        if (credited > charged) _payQuote(c.quoteToken, payer, credited - charged);
    }

    /// @dev Tokens out for `quoteIn` including fee; if the curve would sell
    /// out, the fill is capped at what remains and `charged` is what that
    /// costs (fee included), the rest being refundable.
    function _buyAmounts(Curve storage c, uint256 quoteIn)
        internal
        view
        returns (uint256 tokensOut, uint256 charged, uint256 net)
    {
        uint256 feeBps = c.curveFeeBps;
        net = quoteIn - (quoteIn * feeBps) / BPS;
        uint256 newX = Math.ceilDiv(c.k, c.y + net);
        tokensOut = c.x > newX ? c.x - newX : 0;
        charged = quoteIn;
        if (tokensOut >= c.tokensRemaining) {
            tokensOut = c.tokensRemaining;
            uint256 needed = Math.ceilDiv(c.k, c.x - tokensOut) - c.y;
            // Gross up so the fee is charged on what was actually used.
            charged = Math.ceilDiv(needed * BPS, BPS - feeBps);
            if (charged > quoteIn) charged = quoteIn;
            net = needed;
        }
    }

    function _sellAmounts(Curve storage c, uint256 tokensIn)
        internal
        view
        returns (uint256 quoteOut, uint256 fee, uint256 newY)
    {
        newY = Math.ceilDiv(c.k, c.x + tokensIn);
        uint256 gross = c.y > newY ? c.y - newY : 0;
        fee = (gross * c.curveFeeBps) / BPS;
        quoteOut = gross - fee;
    }

    // ------------------------------------------------------------- graduate

    /// @notice Moves a sold-out curve onto PancakeSwap. Callable by anyone.
    function graduate(address token) external nonReentrant returns (address pool, uint256[] memory positionIds) {
        Curve storage c = _curves[token];
        if (c.creator == address(0)) revert UnknownCurve();
        if (!c.soldOut) revert CurveNotSoldOut();
        if (c.graduated) revert AlreadyGraduated();

        // Effects first: nothing below can re-enter into a second graduation.
        c.graduated = true;
        c.graduatedAtBlock = uint64(block.number);
        CateFamilyCurveToken(token).launch();

        uint256 raised = c.quoteRaised;
        uint256 graduationFee = (raised * c.graduationFeeBps) / BPS;
        uint256 quoteForPool = raised - graduationFee;
        protocolFees[c.quoteToken] += graduationFee;
        c.quoteRaised = 0;

        bool tokenIsToken0 = token < c.quoteToken;
        uint160 sqrtPriceX96 = _finalSqrtPrice(c, tokenIsToken0);
        uint256 tokensForPool = POOL_SUPPLY;
        {
            uint256 tokensSold;
            uint256 quoteReceived;
            (pool, tokensSold, quoteReceived) = _createPool(token, c.quoteToken, tokenIsToken0, sqrtPriceX96);
            if (tokensSold > 0) {
                // Bids parked above the graduation price were filled from the
                // pool reserve; what they paid is pool liquidity now.
                tokensForPool -= tokensSold;
                quoteForPool += quoteReceived;
                emit PriceRestoredBySale(token, tokensSold, quoteReceived);
            }
        }
        c.pool = pool;

        positionIds = _mintGraduationLiquidity(token, c, tokenIsToken0, sqrtPriceX96, tokensForPool, quoteForPool);

        emit Graduated(token, pool, positionIds, tokensForPool, quoteForPool, graduationFee);
    }

    /// @dev sqrt(price) in Q64.96 for the pool's own orientation, from the
    /// curve's final virtual reserves so pool and curve agree exactly.
    function _finalSqrtPrice(Curve storage c, bool tokenIsToken0) internal view returns (uint160) {
        return _sqrtPrice(c.x, c.y, tokenIsToken0);
    }

    /// @dev quote per token = y / x (canonical); the pool prices token1 per token0.
    function _sqrtPrice(uint256 x, uint256 y, bool tokenIsToken0) internal pure returns (uint160) {
        uint256 ratioX192 = tokenIsToken0 ? Math.mulDiv(y, 1 << 192, x) : Math.mulDiv(x, 1 << 192, y);
        uint256 s = Math.sqrt(ratioX192);
        if (s <= TickMath.MIN_SQRT_RATIO || s >= TickMath.MAX_SQRT_RATIO) revert CapOutOfBounds();
        return uint160(s);
    }

    function _createPool(address token, address quote, bool tokenIsToken0, uint160 sqrtPriceX96)
        internal
        returns (address pool, uint256 tokensSold, uint256 quoteReceived)
    {
        (address token0, address token1) = tokenIsToken0 ? (token, quote) : (quote, token);
        pool = positionManager.createAndInitializePoolIfNecessary(token0, token1, POOL_FEE, sqrtPriceX96);
        (uint160 actual,,,,,,) = IPancakeV3Pool(pool).slot0();
        if (actual != sqrtPriceX96) (tokensSold, quoteReceived) = _restorePrice(pool, token, tokenIsToken0, actual, sqrtPriceX96);
    }

    /// @dev Moves a pre-created, mispriced pool to the curve's final price.
    ///
    /// Nobody can hold the launched token before graduation, so any liquidity
    /// that exists in such a pool is quote-only and sits on one side of the
    /// current price. Moving the price TOWARDS the launched token's side
    /// (making the token cheaper) crosses nothing and is free; moving it the
    /// other way may have to cross parked quote bids, every one of which is
    /// priced ABOVE the graduation price. The restore therefore pays only in
    /// the launched token — up to the whole pool reserve — and never in
    /// quote: an obstructing bid buys tokens above the graduation price and
    /// its quote becomes pool liquidity. If even the whole reserve cannot
    /// reach the target the graduation reverts, and the grace-period exit
    /// (`exitOpen`) lets buyers leave at the curve's price meanwhile.
    function _restorePrice(address pool, address token, bool tokenIsToken0, uint160 current, uint160 target)
        internal
        returns (uint256 tokensSold, uint256 quoteReceived)
    {
        // Selling token0 moves the price down; selling token1 moves it up.
        bool zeroForOne = current > target;
        bool payingInToken = zeroForOne == tokenIsToken0;
        _activeSwapPool = pool;
        _activeSwapToken = payingInToken ? token : address(0);
        (int256 amount0, int256 amount1) = IPancakeV3Pool(pool).swap(
            address(this), zeroForOne, payingInToken ? int256(POOL_SUPPLY) : int256(1), target, ""
        );
        _activeSwapPool = address(0);
        _activeSwapToken = address(0);
        (uint160 actual,,,,,,) = IPancakeV3Pool(pool).slot0();
        if (actual != target) revert PoolPriceMismatch();
        (int256 tokenDelta, int256 quoteDelta) = tokenIsToken0 ? (amount0, amount1) : (amount1, amount0);
        if (quoteDelta > 0) revert PoolPriceMismatch(); // never pays quote
        if (tokenDelta > 0) tokensSold = uint256(tokenDelta);
        if (quoteDelta < 0) quoteReceived = uint256(-quoteDelta);
    }

    /// @inheritdoc IPancakeV3SwapCallback
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        address pool = _activeSwapPool;
        if (pool == address(0) || msg.sender != pool) revert UnexpectedSwapCallback();
        address token = _activeSwapToken;
        if (amount0Delta > 0) {
            if (token == address(0) || IPancakeV3Pool(pool).token0() != token) revert PoolPriceMismatch();
            IERC20(token).safeTransfer(pool, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            if (token == address(0) || IPancakeV3Pool(pool).token1() != token) revert PoolPriceMismatch();
            IERC20(token).safeTransfer(pool, uint256(amount1Delta));
        }
    }

    function _mintGraduationLiquidity(
        address token,
        Curve storage c,
        bool tokenIsToken0,
        uint160 sqrtPriceX96,
        uint256 tokensForPool,
        uint256 quoteForPool
    ) internal returns (uint256[] memory positionIds) {
        address quote = c.quoteToken;
        IERC20(token).forceApprove(address(positionManager), tokensForPool);
        IERC20(quote).forceApprove(address(positionManager), quoteForPool);

        uint256[] memory ids = new uint256[](2);
        uint256 count;
        uint256 tokensUsed;
        uint256 quoteLeft = quoteForPool;

        // 1. Two-sided position at the final price, full range. Skipped only
        //    if the restore had to sell the whole reserve (then everything the
        //    pool holds is quote, and the bid below carries it).
        if (tokensForPool > 0) {
            int24 maxUsable = (TickMath.MAX_TICK / POOL_TICK_SPACING) * POOL_TICK_SPACING;
            uint256 quoteUsed;
            (ids[count], tokensUsed, quoteUsed) =
                _mint(token, quote, tokenIsToken0, -maxUsable, maxUsable, tokensForPool, quoteForPool);
            locker.assignPosition(ids[count], token, c.creatorFeeRecipient, c.protocolLpFeeBps);
            quoteLeft -= quoteUsed;
            count++;
        }

        // 2. Standing bid from the opening price up to the final price with
        //    whatever quote the two-sided position could not absorb. The bid
        //    must never be what stops a graduation: if the position manager
        //    will not mint it, the quote is credited to fees instead.
        if (quoteLeft > 0) {
            (int24 lower, int24 upper) = _bidRange(c, sqrtPriceX96, tokenIsToken0);
            (bool ok, uint256 id, uint256 bidQuoteUsed) = _tryMint(token, quote, tokenIsToken0, lower, upper, quoteLeft);
            if (ok) {
                locker.assignPosition(id, token, c.creatorFeeRecipient, c.protocolLpFeeBps);
                ids[count] = id;
                quoteLeft -= bidQuoteUsed;
                count++;
            }
        }

        IERC20(token).forceApprove(address(positionManager), 0);
        IERC20(quote).forceApprove(address(positionManager), 0);

        // Dust: tokens the mint did not take are burned; quote left over goes to fees.
        uint256 tokenDust = tokensForPool - tokensUsed;
        if (tokenDust > 0) IERC20(token).safeTransfer(DEAD, tokenDust);
        if (quoteLeft > 0) protocolFees[quote] += quoteLeft;

        positionIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            positionIds[i] = ids[i];
        }
    }

    /// @dev The quote-only bid, minted through the position manager but never
    /// allowed to revert the graduation.
    function _tryMint(address token, address quote, bool tokenIsToken0, int24 lower, int24 upper, uint256 quoteAmount)
        internal
        returns (bool ok, uint256 id, uint256 quoteUsed)
    {
        try this.mintBidPosition(token, quote, tokenIsToken0, lower, upper, quoteAmount) returns (uint256 id_, uint256 used) {
            return (true, id_, used);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev External only so the mint can be wrapped in try/catch; self-call only.
    function mintBidPosition(address token, address quote, bool tokenIsToken0, int24 lower, int24 upper, uint256 quoteAmount)
        external
        returns (uint256 id, uint256 quoteUsed)
    {
        if (msg.sender != address(this)) revert UnexpectedSwapCallback();
        (id,, quoteUsed) = _mint(token, quote, tokenIsToken0, lower, upper, 0, quoteAmount);
    }

    /// @dev Mints one locker position. Ranges are canonical (quote per token,
    /// rising with tick) and mirrored here when the token sorts second.
    function _mint(
        address token,
        address quote,
        bool tokenIsToken0,
        int24 canonicalLower,
        int24 canonicalUpper,
        uint256 tokenAmount,
        uint256 quoteAmount
    ) internal returns (uint256 id, uint256 tokensUsed, uint256 quoteUsed) {
        (int24 lower, int24 upper) = tokenIsToken0 ? (canonicalLower, canonicalUpper) : (-canonicalUpper, -canonicalLower);
        uint256 amount0;
        uint256 amount1;
        (id,, amount0, amount1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: tokenIsToken0 ? token : quote,
                token1: tokenIsToken0 ? quote : token,
                fee: POOL_FEE,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: tokenIsToken0 ? tokenAmount : quoteAmount,
                amount1Desired: tokenIsToken0 ? quoteAmount : tokenAmount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(locker),
                deadline: block.timestamp
            })
        );
        (tokensUsed, quoteUsed) = tokenIsToken0 ? (amount0, amount1) : (amount1, amount0);
    }

    /// @dev Quote-only range from the opening price up to (but not above) the
    /// current price, aligned down to the pool's tick spacing.
    function _bidRange(Curve storage c, uint160 sqrtPriceX96, bool tokenIsToken0)
        internal
        view
        returns (int24 lower, int24 upper)
    {
        int24 poolTick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        // The pool's tick is the floor of its own price. Mirrored, `-poolTick`
        // is the CEILING of the canonical tick, and a bid whose top sits on
        // that ceiling would contain the price and need tokens it has none of
        // (a zero-liquidity mint). One tick lower is the canonical floor.
        int24 current = tokenIsToken0 ? poolTick : -(poolTick + 1);
        upper = _floorAlign(current);
        uint256 openRatioX192 = Math.mulDiv(c.y0, 1 << 192, c.x0);
        int24 openTick = TickMath.getTickAtSqrtRatio(uint160(Math.sqrt(openRatioX192)));
        lower = _floorAlign(openTick);
        if (lower >= upper) lower = upper - POOL_TICK_SPACING;
    }

    function _floorAlign(int24 tick) internal pure returns (int24) {
        int24 aligned = (tick / POOL_TICK_SPACING) * POOL_TICK_SPACING;
        if (aligned > tick) aligned -= POOL_TICK_SPACING; // negative ticks round toward zero in Solidity
        return aligned;
    }

    // ----------------------------------------------------------- quote flow

    function _collectQuote(address quote, address from, uint256 amount) internal returns (uint256 credited) {
        if (quote == wbnb) {
            if (msg.value != amount) revert IncorrectNativeValue();
            IWBNB(wbnb).deposit{value: amount}();
            return amount;
        }
        if (msg.value != 0) revert IncorrectNativeValue();
        uint256 before = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransferFrom(from, address(this), amount);
        credited = IERC20(quote).balanceOf(address(this)) - before;
    }

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

    receive() external payable {
        if (msg.sender != wbnb) revert IncorrectNativeValue();
    }

    /// @notice Sends accrued protocol fees in `quote` to the treasury. Anyone may call.
    function claimProtocolFees(address quote) external nonReentrant returns (uint256 amount) {
        amount = protocolFees[quote];
        if (amount == 0) revert NothingToClaim();
        protocolFees[quote] = 0;
        IERC20(quote).safeTransfer(config.treasury, amount);
        emit ProtocolFeesClaimed(quote, config.treasury, amount);
    }

    // ----------------------------------------------------------- validation

    function _validateCreate(CreateParams calldata p) internal view {
        if (bytes(p.name).length == 0 || bytes(p.name).length > 64) revert InvalidName();
        if (bytes(p.symbol).length == 0 || bytes(p.symbol).length > 32) revert InvalidSymbol();
        if (bytes(p.metadataURI).length > 2048) revert InvalidMetadataURI();
        QuoteConfig memory q = quoteConfig[p.quoteToken];
        if (!q.allowed) revert QuoteNotAllowed();
        if (p.openingCap < q.minOpeningCap) revert CapOutOfBounds();
        if (p.graduationCap < q.minGraduationCap || p.graduationCap > q.maxGraduationCap) revert CapOutOfBounds();
        if (p.graduationCap < p.openingCap * MIN_MULTIPLE || p.graduationCap > p.openingCap * MAX_MULTIPLE) {
            revert CapOutOfBounds();
        }
    }

    /// @dev Virtual reserves for a curve opening at `openingCap` and selling
    /// out at `graduationCap`, with the fixed 80/20 split:
    ///   m = graduationCap / openingCap,  T_v = CURVE_SUPPLY / (sqrt(m) - 1),
    ///   x0 = CURVE_SUPPLY + T_v,          y0 = openingCap * x0 / TOTAL_SUPPLY.
    function _reserves(uint256 openingCap, uint256 graduationCap) internal pure returns (uint256 x0, uint256 y0) {
        uint256 sqrtM = Math.sqrt(Math.mulDiv(graduationCap, WAD * WAD, openingCap)); // 1e18-scaled
        uint256 tv = Math.mulDiv(CURVE_SUPPLY, WAD, sqrtM - WAD);
        x0 = CURVE_SUPPLY + tv;
        y0 = Math.mulDiv(openingCap, x0, TOTAL_SUPPLY);
    }

    function _validateConfig(Config memory c) internal pure {
        if (c.treasury == address(0)) revert ZeroAddress();
        if (
            c.curveFeeBps > MAX_CURVE_FEE_BPS || c.graduationFeeBps > MAX_GRADUATION_FEE_BPS
                || c.protocolLpFeeBps > MAX_PROTOCOL_LP_FEE_BPS || c.openingWalletCapBps > MAX_WALLET_CAP_BPS
                || c.openingWalletCapBps == 0
        ) revert ConfigOutOfBounds();
    }

    // ----------------------------------------------------------------- admin
    //
    // Same rules as the factories: every economic change is scheduled, waits
    // CONFIG_DELAY, and is applied by anyone; only the pause is immediate;
    // ownership cannot be renounced.

    function scheduleConfig(Config calldata next) external onlyOwner {
        _validateConfig(next);
        uint64 eta = uint64(block.timestamp + CONFIG_DELAY);
        pendingConfig = PendingConfig({config: next, eta: eta});
        emit ConfigScheduled(next, eta);
    }

    function applyConfig() external {
        PendingConfig memory p = pendingConfig;
        if (p.eta == 0) revert NoPendingConfig();
        if (block.timestamp < p.eta) revert ConfigNotReady(p.eta);
        if (block.timestamp > p.eta + CONFIG_EXPIRY) revert ConfigExpired(p.eta);
        delete pendingConfig;
        config = p.config;
        emit ConfigApplied(p.config);
    }

    function cancelConfig() external onlyOwner {
        if (pendingConfig.eta == 0) revert NoPendingConfig();
        delete pendingConfig;
        emit ConfigCancelled();
    }

    function scheduleQuoteConfig(address quote, QuoteConfig calldata next) external onlyOwner {
        if (quote == address(0)) revert ZeroAddress();
        uint64 eta = uint64(block.timestamp + CONFIG_DELAY);
        pendingQuoteConfig[quote] = PendingQuoteConfig({config: next, eta: eta});
        emit QuoteConfigScheduled(quote, next, eta);
    }

    function applyQuoteConfig(address quote) external {
        PendingQuoteConfig memory p = pendingQuoteConfig[quote];
        if (p.eta == 0) revert NoPendingConfig();
        if (block.timestamp < p.eta) revert ConfigNotReady(p.eta);
        if (block.timestamp > p.eta + CONFIG_EXPIRY) revert ConfigExpired(p.eta);
        delete pendingQuoteConfig[quote];
        quoteConfig[quote] = p.config;
        emit QuoteConfigApplied(quote, p.config);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
