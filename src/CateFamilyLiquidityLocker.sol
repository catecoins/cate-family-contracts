// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {INonfungiblePositionManager} from "./interfaces/IPancakeV3.sol";

/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
interface ICateFamilyFeeConfig {
    function treasury() external view returns (address);
}

/// @title CateFamilyLiquidityLocker
/// @notice Permanent vault for the PancakeSwap V3 LP NFTs minted at launch.
/// There is deliberately no function that can decrease liquidity, transfer a
/// position out, or approve an operator: once a position arrives it can never
/// leave, so launch liquidity is provably locked forever.
///
/// The only value that ever exits is accrued swap fees. Anyone may trigger
/// collection; the pool tax then settles like this:
///   - the LAUNCHED-token side of the fees is BURNED in full — neither the
///     creator nor the protocol ever holds or sells a token launched through
///     CateFamily, and every sell permanently deflates the supply;
///   - the QUOTE (paired token) side is split creator/protocol by the ratio
///     snapshotted at launch (80/20 in the creator's favour at the shipped
///     configuration) and credited
///     to pull-based balances — creators and the protocol each claim their own
///     earnings whenever they choose, so one blocked recipient can never jam
///     collection for everyone else.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
contract CateFamilyLiquidityLocker is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct LockedPosition {
        /// @dev CateFamilyToken this position belongs to (zero until assigned).
        address token;
        /// @dev Receiver of the creator's share of swap fees.
        address creatorFeeRecipient;
        /// @dev Protocol share of collected fees in basis points, snapshotted at launch.
        uint16 protocolFeeBps;
    }

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice PancakeSwap V3 position manager whose NFTs this locker accepts.
    INonfungiblePositionManager public immutable positionManager;

    /// @notice The CateFamily factory allowed to assign fee routing for new positions.
    address public immutable cappuccinoFactory;

    /// @notice The claimable-fees key that holds the protocol's share. Not an
    /// account: whoever is the launchpad's treasury at claim time may claim
    /// it, so a treasury change never splits credit across two addresses.
    address public constant PROTOCOL = address(1);

    /// @notice Fee routing per locked position id.
    mapping(uint256 tokenId => LockedPosition) public lockedPositions;

    /// @notice All locked position ids for a launched token.
    mapping(address token => uint256[]) internal _positionsOf;

    /// @notice Pull-based fee balances: account => currency => claimable amount.
    mapping(address account => mapping(address currency => uint256)) public claimableFees;

    event PositionLocked(uint256 indexed tokenId);
    event PositionAssigned(
        uint256 indexed tokenId, address indexed token, address indexed creatorFeeRecipient, uint16 protocolFeeBps
    );
    event CreatorFeeRecipientUpdated(
        uint256 indexed tokenId, address indexed previousRecipient, address indexed newRecipient
    );
    event FeesCollected(
        uint256 indexed tokenId,
        address indexed token,
        address caller,
        address quoteCurrency,
        uint256 creatorQuoteAmount,
        uint256 protocolQuoteAmount,
        uint256 tokensBurned
    );
    /// @notice One position's collection failed and was skipped by
    /// `collectAllFees`. Emitted rather than reverted so a single misbehaving
    /// quote asset cannot strand a launch's other pools — see that function.
    event FeeCollectionSkipped(uint256 indexed tokenId, address indexed token, address caller);
    event FeesClaimed(address indexed account, address indexed currency, address indexed to, uint256 amount);

    error OnlyPositionManagerNFTs();
    error OnlyCateFamilyFactory();
    error OnlyCreatorFeeRecipient();
    error ZeroAddress();
    error PositionNotHeld(uint256 tokenId);
    error PositionAlreadyAssigned(uint256 tokenId);
    error PositionNotAssigned(uint256 tokenId);
    error InvalidProtocolFee();
    error NothingToClaim();
    error OnlySelf();
    error TokenNotInPosition(uint256 tokenId);
    error OnlyTreasury();

    constructor(INonfungiblePositionManager positionManager_, address cappuccinoFactory_) {
        if (address(positionManager_) == address(0) || cappuccinoFactory_ == address(0)) revert ZeroAddress();
        positionManager = positionManager_;
        cappuccinoFactory = cappuccinoFactory_;
    }

    /// @notice Accepts LP NFTs, but only ones minted by the configured position manager.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external override returns (bytes4) {
        if (msg.sender != address(positionManager)) revert OnlyPositionManagerNFTs();
        emit PositionLocked(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Called by the factory right after minting a launch position to wire up fee routing.
    function assignPosition(uint256 tokenId, address token, address creatorFeeRecipient, uint16 protocolFeeBps)
        external
    {
        if (msg.sender != cappuccinoFactory) revert OnlyCateFamilyFactory();
        if (token == address(0) || creatorFeeRecipient == address(0)) revert ZeroAddress();
        if (protocolFeeBps > BPS_DENOMINATOR / 2) revert InvalidProtocolFee();
        if (positionManager.ownerOf(tokenId) != address(this)) revert PositionNotHeld(tokenId);
        if (lockedPositions[tokenId].token != address(0)) revert PositionAlreadyAssigned(tokenId);
        (,, address t0, address t1,,,,,,,,) = positionManager.positions(tokenId);
        if (token != t0 && token != t1) revert TokenNotInPosition(tokenId);

        lockedPositions[tokenId] =
            LockedPosition({token: token, creatorFeeRecipient: creatorFeeRecipient, protocolFeeBps: protocolFeeBps});
        _positionsOf[token].push(tokenId);
        emit PositionAssigned(tokenId, token, creatorFeeRecipient, protocolFeeBps);
    }

    /// @notice Collects accrued swap fees for one locked position, credits the
    /// creator and treasury pull-balances, and burns the protocol's share of
    /// the launched token. Callable by anyone.
    function collectFees(uint256 tokenId) public nonReentrant returns (uint256 amount0, uint256 amount1) {
        return _collectFees(tokenId, msg.sender);
    }

    /// @dev Exists only so `collectAllFees` can wrap ONE position in try/catch,
    /// which Solidity permits solely around an external call. Self-only, and
    /// carries the original caller through so the emitted event still names the
    /// person who asked rather than this contract.
    function collectFeesFromBatch(uint256 tokenId, address caller)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        return _collectFees(tokenId, caller);
    }

    function _collectFees(uint256 tokenId, address caller) internal returns (uint256 amount0, uint256 amount1) {
        LockedPosition memory locked = lockedPositions[tokenId];
        if (locked.token == address(0)) revert PositionNotAssigned(tokenId);

        (,, address token0, address token1,,,,,,,,) = positionManager.positions(tokenId);
        // Credit only what actually arrives (balance deltas), not what the
        // position manager reports: a quote token that skims transfers can
        // then only shortchange its own launches, never make the shared
        // claimable pool insolvent for other currencies or recipients.
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));
        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        amount0 = IERC20(token0).balanceOf(address(this)) - balance0Before;
        amount1 = IERC20(token1).balanceOf(address(this)) - balance1Before;

        (uint256 tokenSideAmount, uint256 quoteSideAmount, address quoteCurrency) =
            token0 == locked.token ? (amount0, amount1, token1) : (amount1, amount0, token0);

        // Quote side: creator/protocol split at the launch-time snapshot,
        // credited for pull-based claiming.
        uint256 protocolQuote = (quoteSideAmount * locked.protocolFeeBps) / BPS_DENOMINATOR;
        uint256 creatorQuote = quoteSideAmount - protocolQuote;
        if (creatorQuote > 0) claimableFees[locked.creatorFeeRecipient][quoteCurrency] += creatorQuote;
        if (protocolQuote > 0) claimableFees[PROTOCOL][quoteCurrency] += protocolQuote;

        // Launched-token side: burned in full. CateFamilyTokens are hook-free, so
        // the burn cannot revert or be blocked.
        if (tokenSideAmount > 0) IERC20(locked.token).safeTransfer(DEAD, tokenSideAmount);

        emit FeesCollected(tokenId, locked.token, caller, quoteCurrency, creatorQuote, protocolQuote, tokenSideAmount);
    }

    /// @notice Collects fees across every position locked for a launched token.
    ///
    /// A position that cannot be collected is SKIPPED rather than reverting the
    /// whole batch, and the reason is a multi-pair launch: its positions sit in
    /// different pools against DIFFERENT quote assets, so one hostile or merely
    /// broken quote token used to take every other pool's fees down with it.
    /// Nothing was lost — `collectFees(id)` per position still reached them —
    /// but this is the entry point the UI and the distributor both call, and a
    /// creator had no way to know the fallback existed.
    ///
    /// Skipping is safe because collection is idempotent: a skipped position
    /// writes no state, keeps its fees inside the Pancake position, and can be
    /// collected later if the currency starts behaving. `FeeCollectionSkipped`
    /// says which ones, so a caller reading totals is never quietly misled.
    ///
    /// Deliberately NOT `nonReentrant`: it self-calls a guarded function, so
    /// taking the guard here would make every inner call revert. Re-entering it
    /// therefore skips everything and returns zero rather than moving funds.
    ///
    /// One consequence of `catch` worth knowing: it swallows out-of-gas as
    /// readily as a revert. Under EIP-150 the outer frame keeps a 64th of the
    /// gas, so a caller who supplies too little gets a transaction that
    /// succeeds having skipped positions it could have collected. Nothing is
    /// lost — the fees stay in the position and the next call takes them — but
    /// read `FeeCollectionSkipped` rather than the return value to know what
    /// actually happened.
    function collectAllFees(address token) external returns (uint256 total0, uint256 total1) {
        uint256[] memory ids = _positionsOf[token];
        address caller = msg.sender;
        for (uint256 i = 0; i < ids.length; i++) {
            try this.collectFeesFromBatch(ids[i], caller) returns (uint256 a0, uint256 a1) {
                total0 += a0;
                total1 += a1;
            } catch {
                emit FeeCollectionSkipped(ids[i], token, caller);
            }
        }
    }

    /// @notice Sends the caller's accrued fee balance for one currency to `to`.
    ///
    /// Pays out at most the locker's balance and reduces the credit only by
    /// what was paid, so a currency that rebases down delays its own claims
    /// rather than losing them.
    ///
    /// That cap is read from the currency itself, so it is only as honest as
    /// the currency is. A token that overstates `balanceOf` inflates both its
    /// credit (through the deltas in `collectFees`) and this cap, and the
    /// transfer below then reverts on the real balance — its claims are bricked
    /// outright, not delayed. That is accepted rather than defended: the loss
    /// is confined to fees denominated in that token, credits in every other
    /// currency are untouched, and nobody who did not choose it as a quote
    /// asset is affected. See `HostileTokensTest`.
    function claimFees(address currency, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        uint256 credit = claimableFees[msg.sender][currency];
        uint256 available = IERC20(currency).balanceOf(address(this));
        amount = credit <= available ? credit : available;
        if (amount == 0) revert NothingToClaim();
        claimableFees[msg.sender][currency] = credit - amount;
        IERC20(currency).safeTransfer(to, amount);
        emit FeesClaimed(msg.sender, currency, to, amount);
    }

    /// @notice Pays out the protocol's accrued share of `currency` to `to`.
    /// Only the launchpad's CURRENT treasury may call it; the credit itself
    /// is keyed to PROTOCOL, so it follows the role, not an address.
    function claimProtocolFees(address currency, address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != ICateFamilyFeeConfig(cappuccinoFactory).treasury()) revert OnlyTreasury();
        if (to == address(0)) revert ZeroAddress();
        uint256 credit = claimableFees[PROTOCOL][currency];
        uint256 available = IERC20(currency).balanceOf(address(this));
        amount = credit <= available ? credit : available;
        if (amount == 0) revert NothingToClaim();
        claimableFees[PROTOCOL][currency] = credit - amount;
        IERC20(currency).safeTransfer(to, amount);
        emit FeesClaimed(PROTOCOL, currency, to, amount);
    }

    /// @notice Lets the current creator fee recipient hand fee rights to a new address.
    /// Already-accrued claimable balances stay with the previous recipient.
    function setCreatorFeeRecipient(uint256 tokenId, address newRecipient) external {
        LockedPosition storage locked = lockedPositions[tokenId];
        if (locked.token == address(0)) revert PositionNotAssigned(tokenId);
        if (msg.sender != locked.creatorFeeRecipient) revert OnlyCreatorFeeRecipient();
        if (newRecipient == address(0)) revert ZeroAddress();
        emit CreatorFeeRecipientUpdated(tokenId, locked.creatorFeeRecipient, newRecipient);
        locked.creatorFeeRecipient = newRecipient;
    }

    /// @notice Position ids locked for a launched token.
    function positionsOf(address token) external view returns (uint256[] memory) {
        return _positionsOf[token];
    }
}
