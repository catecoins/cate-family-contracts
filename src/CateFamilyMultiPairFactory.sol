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

/// @title CateFamilyMultiPairFactory
/// @notice Launches one token into UP TO FIVE PancakeSwap V3 pools in a single
/// transaction — the "bStock" launch, where a creator lists against BNB, USDT
/// and several tokenized-stock quote assets at once.
///
/// Mechanically this is the single-pair launch repeated per pair: the supply is
/// split by basis points, each slice is minted as single-sided liquidity above
/// that pair's starting tick, and every LP NFT is locked forever in this
/// factory's own CateFamilyLiquidityLocker. Fees accrue and are claimed exactly
/// as they are for a standard launch, so a creator's claimable balance pools
/// across every pair that shares a quote currency.
///
/// Deliberate differences from the single-pair factory:
///   - no atomic first buy (five pools, five routes, five slippage surfaces —
///     the launch form quotes and buys as a follow-up transaction instead);
///   - holder-reward routing is not wired up in v1, because a buyback-and-burn
///     distributor is defined against exactly one pool.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
contract CateFamilyMultiPairFactory is Ownable2Step, ReentrancyGuard, IPancakeV3SwapCallback {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    /// @param quoteToken Any standard BEP20 to pair against.
    /// @param fee Pancake V3 fee tier: 100, 500, 2500 or 10000.
    /// @param initialTick Starting tick in canonical orientation (quote per token).
    /// @param supplyBps Share of total supply placed in this pair, in basis points.
    struct PairConfig {
        address quoteToken;
        uint24 fee;
        int24 initialTick;
        uint16 supplyBps;
    }

    struct LaunchParams {
        string name;
        string symbol;
        string metadataURI;
        uint256 totalSupply;
        PairConfig[] pairs;
        address creatorFeeRecipient;
        bytes32 salt;
        uint256 maxLaunchFeeWei;
    }

    struct LaunchRecord {
        address token;
        address creator;
        uint8 pairCount;
        uint64 launchedAtBlock;
    }

    // ------------------------------------------------------------- constants

    /// @notice Hard ceiling on pools per launch. Five keeps the launch inside a
    /// comfortable BSC block gas budget and bounds the locker's per-token loop.
    uint256 public constant MAX_PAIRS = 5;
    uint256 public constant MIN_TOTAL_SUPPLY = 1e18;
    uint256 public constant MAX_TOTAL_SUPPLY = 1e30;
    uint256 public constant MAX_LAUNCH_FEE = 5 ether;
    uint16 public constant MAX_PROTOCOL_LP_FEE_BPS = 5000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ------------------------------------------------------------ immutables

    IPancakeV3Factory public immutable pancakeV3Factory;
    INonfungiblePositionManager public immutable positionManager;
    address public immutable wbnb;
    CateFamilyLiquidityLocker public immutable locker;

    // ---------------------------------------------------------------- config

    /// @notice Receives launch fees and the protocol share of LP fees.
    /// @dev Also read by the locker through ICateFamilyFeeConfig.
    address public treasury;
    uint256 public launchFeeWei;
    uint16 public protocolLpFeeBps;
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

    mapping(address token => LaunchRecord) public launches;
    mapping(address token => address[] pools) internal _poolsOf;
    uint256 public totalLaunches;

    /// @dev Pool allowed to invoke the swap callback, only during a price restore.
    address private _activeSwapPool;
    /// @dev The launched token a restore may pay with; never the quote.
    address private _activeSwapToken;
    /// @notice Most of a pair's slice a price restore may sell through parked
    /// quote bids above the opening price (second audit, M-05).
    uint256 public constant MAX_RESTORE_BPS = 1000;

    // ---------------------------------------------------------------- events

    event TokenLaunchedMultiPair(
        address indexed token,
        address indexed creator,
        uint256 totalSupply,
        uint8 pairCount,
        address[] quoteTokens,
        address[] pools,
        uint24[] fees,
        int24[] initialTicks,
        uint256[] lockedPositionIds,
        string name,
        string symbol,
        string metadataURI
    );
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
    error InvalidPairCount();
    error DuplicatePair();
    error InvalidBps();
    error IncorrectNativeValue();
    error ConfigOutOfBounds();
    error NativeTransferFailed();
    error PoolPriceMismatch();

    /// @notice A pair's price restore had to sell launched tokens through bids
    /// parked above the opening price; the quote received went to the creator.
    event PriceRestoredBySale(address indexed token, address indexed pool, uint256 tokensSold, uint256 quoteReceived);
    error LaunchFeeAboveCap(uint256 currentFee, uint256 consentedMax);
    error UnexpectedSwapCallback();
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

    /// @notice Launches a token across 1–5 PancakeSwap V3 pools at once.
    /// Send exactly `launchFeeWei` as native value; there is no first buy here.
    function launch(LaunchParams calldata params)
        external
        payable
        nonReentrant
        returns (address token, address[] memory pools, uint256[] memory positionIds)
    {
        if (paused) revert LaunchesPaused();
        _validate(params);
        _collectLaunchFee(params);

        token = address(
            new CateFamilyToken{salt: keccak256(abi.encode(msg.sender, params.salt))}(
                params.name, params.symbol, params.totalSupply, address(this), params.metadataURI, msg.sender
            )
        );

        (pools, positionIds) = _openPairs(token, params);

        uint8 pairCount = uint8(params.pairs.length);
        launches[token] = LaunchRecord({
            token: token,
            creator: msg.sender,
            pairCount: pairCount,
            launchedAtBlock: uint64(block.number)
        });
        _poolsOf[token] = pools;
        totalLaunches += 1;

        _emitLaunch(token, params, pools, positionIds, pairCount);
    }

    /// @notice Predicts the CREATE2 address a launch will deploy its token at.
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

    /// @notice Every pool opened for a multi-pair launch.
    function poolsOf(address token) external view returns (address[] memory) {
        return _poolsOf[token];
    }

    // ------------------------------------------------------------- internals

    function _validate(LaunchParams calldata params) internal view {
        if (bytes(params.name).length == 0 || bytes(params.name).length > 64) revert InvalidName();
        if (bytes(params.symbol).length == 0 || bytes(params.symbol).length > 32) revert InvalidSymbol();
        if (bytes(params.metadataURI).length > 2048) revert InvalidMetadataURI();
        if (params.totalSupply < MIN_TOTAL_SUPPLY || params.totalSupply > MAX_TOTAL_SUPPLY) revert InvalidTotalSupply();

        uint256 count = params.pairs.length;
        if (count == 0 || count > MAX_PAIRS) revert InvalidPairCount();

        uint256 bpsSum = 0;
        for (uint256 i = 0; i < count; i++) {
            PairConfig calldata p = params.pairs[i];
            if (p.quoteToken == address(0) || p.quoteToken.code.length == 0) revert InvalidQuoteToken();

            int24 tickSpacing = pancakeV3Factory.feeAmountTickSpacing(p.fee);
            if (tickSpacing <= 0) revert UnsupportedFeeTier();
            if (p.initialTick % tickSpacing != 0) revert TickNotAligned();
            int24 maxUsableTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
            if (p.initialTick <= -maxUsableTick || p.initialTick >= maxUsableTick) revert TickOutOfRange();

            if (p.supplyBps == 0) revert InvalidBps();
            bpsSum += p.supplyBps;

            // Two pairs sharing a quote token AND a fee tier resolve to the
            // same Pancake pool; the second would mint into the first's pool at
            // a price it never agreed to. Reject the collision outright.
            for (uint256 j = 0; j < i; j++) {
                if (params.pairs[j].quoteToken == p.quoteToken && params.pairs[j].fee == p.fee) revert DuplicatePair();
            }
        }
        if (bpsSum != BPS_DENOMINATOR) revert InvalidBps();
    }

    function _collectLaunchFee(LaunchParams calldata params) internal {
        uint256 fee_ = launchFeeWei;
        if (fee_ > params.maxLaunchFeeWei) revert LaunchFeeAboveCap(fee_, params.maxLaunchFeeWei);
        if (msg.value != fee_) revert IncorrectNativeValue();
        if (fee_ > 0) {
            (bool ok,) = treasury.call{value: fee_}("");
            if (!ok) revert NativeTransferFailed();
        }
    }

    function _openPairs(address token, LaunchParams calldata params)
        internal
        returns (address[] memory pools, uint256[] memory positionIds)
    {
        uint256 count = params.pairs.length;
        pools = new address[](count);
        positionIds = new uint256[](count);

        IERC20(token).forceApprove(address(positionManager), params.totalSupply);

        address creatorRecipient =
            params.creatorFeeRecipient == address(0) ? msg.sender : params.creatorFeeRecipient;
        uint16 protocolBps = protocolLpFeeBps;
        uint256 remaining = params.totalSupply;

        for (uint256 i = 0; i < count; i++) {
            PairConfig calldata p = params.pairs[i];
            uint256 amount = i == count - 1 ? remaining : (params.totalSupply * p.supplyBps) / BPS_DENOMINATOR;
            remaining -= amount;
            (pools[i], positionIds[i]) = _openPair(token, p, amount);
            locker.assignPosition(positionIds[i], token, creatorRecipient, protocolBps);
        }

        IERC20(token).forceApprove(address(positionManager), 0);
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) IERC20(token).safeTransfer(DEAD, dust);
    }

    /// @dev Creates (or restores) one pair's pool and mints its single-sided
    /// position. Split out of the loop to stay inside the stack limit.
    function _openPair(address token, PairConfig calldata p, uint256 amount)
        internal
        returns (address pool, uint256 tokenId)
    {
        bool tokenIsToken0 = token < p.quoteToken;
        uint256 tokensSold;
        (pool, tokensSold) = _createPool(token, p, tokenIsToken0, amount);
        amount -= tokensSold;

        int24 tickSpacing = pancakeV3Factory.feeAmountTickSpacing(p.fee);
        int24 upper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        (int24 mintLower, int24 mintUpper) = tokenIsToken0 ? (p.initialTick, upper) : (-upper, -p.initialTick);

        (tokenId,,,) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: tokenIsToken0 ? token : p.quoteToken,
                token1: tokenIsToken0 ? p.quoteToken : token,
                fee: p.fee,
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
    }

    function _createPool(address token, PairConfig calldata p, bool tokenIsToken0, uint256 slice)
        internal
        returns (address pool, uint256 tokensSold)
    {
        (address token0, address token1) = tokenIsToken0 ? (token, p.quoteToken) : (p.quoteToken, token);
        int24 poolTick = tokenIsToken0 ? p.initialTick : -p.initialTick;
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(poolTick);
        pool = positionManager.createAndInitializePoolIfNecessary(token0, token1, p.fee, sqrtPriceX96);
        // Same front-running defence as the single-pair factory: a pre-created
        // mispriced pool is restored, selling through parked bids with up to
        // MAX_RESTORE_BPS of this pair's slice (M-02 / M-05).
        (uint160 actualSqrtPriceX96,,,,,,) = IPancakeV3Pool(pool).slot0();
        if (actualSqrtPriceX96 != sqrtPriceX96) {
            uint256 quoteReceived;
            (tokensSold, quoteReceived) = _restorePrice(pool, token, tokenIsToken0, slice, actualSqrtPriceX96, sqrtPriceX96);
            if (tokensSold > 0) {
                _payQuote(p.quoteToken, msg.sender, quoteReceived);
                emit PriceRestoredBySale(token, pool, tokensSold, quoteReceived);
            }
        }
    }

    /// @dev See CateFamilyFactory._restorePrice: pays only in the launched
    /// token, bounded, never in quote. The token exists by now.
    function _restorePrice(
        address pool,
        address token,
        bool tokenIsToken0,
        uint256 slice,
        uint160 current,
        uint160 target
    ) internal returns (uint256 tokensSold, uint256 quoteReceived) {
        bool zeroForOne = current > target;
        bool payingInToken = zeroForOne == tokenIsToken0;
        _activeSwapPool = pool;
        _activeSwapToken = payingInToken ? token : address(0);
        (int256 amount0, int256 amount1) = IPancakeV3Pool(pool).swap(
            address(this),
            zeroForOne,
            payingInToken ? int256((slice * MAX_RESTORE_BPS) / BPS_DENOMINATOR) : int256(1),
            target,
            ""
        );
        _activeSwapPool = address(0);
        _activeSwapToken = address(0);
        (uint160 actual,,,,,,) = IPancakeV3Pool(pool).slot0();
        if (actual != target) revert PoolPriceMismatch();
        (int256 tokenDelta, int256 quoteDelta) = tokenIsToken0 ? (amount0, amount1) : (amount1, amount0);
        if (quoteDelta > 0) revert PoolPriceMismatch();
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

    /// @dev Accepts BNB only while unwrapping WBNB for a restore's proceeds.
    receive() external payable {
        if (msg.sender != wbnb) revert IncorrectNativeValue();
    }

    /// @inheritdoc IPancakeV3SwapCallback
    /// @dev Only ever reached from `_restorePrice`; pays the launched token only.
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

    /// @dev Split out purely to keep `launch` inside the stack limit.
    function _emitLaunch(
        address token,
        LaunchParams calldata params,
        address[] memory pools,
        uint256[] memory positionIds,
        uint8 pairCount
    ) internal {
        uint256 count = params.pairs.length;
        address[] memory quoteTokens = new address[](count);
        uint24[] memory fees = new uint24[](count);
        int24[] memory initialTicks = new int24[](count);
        for (uint256 i = 0; i < count; i++) {
            quoteTokens[i] = params.pairs[i].quoteToken;
            fees[i] = params.pairs[i].fee;
            initialTicks[i] = params.pairs[i].initialTick;
        }
        emit TokenLaunchedMultiPair(
            token,
            msg.sender,
            params.totalSupply,
            pairCount,
            quoteTokens,
            pools,
            fees,
            initialTicks,
            positionIds,
            params.name,
            params.symbol,
            params.metadataURI
        );
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
