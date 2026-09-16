// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPancakeV3Factory, IPancakeV3Pool, INonfungiblePositionManager} from "./interfaces/IPancakeV3.sol";

/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
interface ICateFamilyPositionRegistry {
    function positionsOf(address token) external view returns (uint256[] memory);
}

/// @title CateFamilyGraduation
/// @notice Records, permanently and permissionlessly, that a bonding-curve
/// launch has sold through its curve range.
///
/// A curve launch splits its supply across two locked ranges: roughly 80% from
/// the opening price up to a graduation price, and the rest above. Buying walks
/// the first range and the quote paid accumulates inside it. When the range is
/// exhausted the token has graduated — the upper range becomes the ask and the
/// first, now holding the entire raise, becomes the permanent bid.
///
/// All of that already works without this contract: the ranges are minted by
/// the factory and locked by the locker, and how far the curve has been
/// consumed is readable from the pool's current tick. This exists for one
/// reason only — so that HAVING graduated is a fact rather than a reading.
/// A price can fall back below the line; a stamp cannot. Without it the
/// progress bar would drop when the market drops, and nothing anywhere would
/// remember the token ever crossed.
///
/// It holds no funds, has no owner, and has no setters. The only state it can
/// ever write is a block number, and only when the chain already says the
/// crossing happened. Nothing here can be revoked, re-pointed, or paused.
///
/// The one thing it does trust is the locker address given at deployment, and
/// it has to: see the note on that field. A registry belongs to one generation.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
contract CateFamilyGraduation {
    IPancakeV3Factory public immutable pancakeV3Factory;
    INonfungiblePositionManager public immutable positionManager;

    /**
     * The locker whose positions this registry believes.
     *
     * Immutable, and that is the entire security model. It was originally a
     * call parameter so one registry could serve every generation, which made
     * the registry trivially forgeable: anyone could deploy a contract with a
     * `positionsOf` returning ids they chose and stamp any token on the chain.
     * Validating harder does not close it — an attacker can mint a real
     * position with a low range in the real pool, so even requiring every id to
     * be owned by the passed locker is forgeable.
     *
     * So the registry trusts exactly one address, fixed at deployment, and a
     * new factory generation gets a new registry. `assignPosition` on the
     * locker is gated to its own factory, so anything this locker reports for a
     * token was put there by that factory at launch.
     */
    address public immutable locker;

    /// @notice Block a token's curve was first observed exhausted. Zero = not yet.
    mapping(address token => uint64 blockNumber) public graduatedAtBlock;

    event Graduated(address indexed token, address indexed pool, int24 canonicalTick, uint64 blockNumber);

    error ZeroAddress();
    error AlreadyGraduated();
    /// @dev Fewer than two locked ranges: this launch has no curve to exhaust.
    error NotACurveLaunch();
    error PoolNotFound();
    /// @dev The locked position does not name this token on either side.
    error TokenNotInPosition();
    /// @dev The pool has not traded past the curve range yet.
    error CurveNotExhausted();
    /// @dev A locked range belongs to a different pool — a multi-pair launch.
    error PositionNotInPool();

    constructor(address pancakeV3Factory_, address positionManager_, address locker_) {
        if (pancakeV3Factory_ == address(0) || positionManager_ == address(0) || locker_ == address(0)) {
            revert ZeroAddress();
        }
        pancakeV3Factory = IPancakeV3Factory(pancakeV3Factory_);
        positionManager = INonfungiblePositionManager(positionManager_);
        locker = locker_;
    }

    /// @notice Stamps `token` as graduated if its curve range has been sold out.
    function markGraduated(address token) external returns (uint64 blockNumber) {
        if (graduatedAtBlock[token] != 0) revert AlreadyGraduated();

        uint256[] memory ids = ICateFamilyPositionRegistry(locker).positionsOf(token);
        if (ids.length < 2) revert NotACurveLaunch();

        (address pool, bool tokenIsToken0) = _poolFor(token, ids[0]);
        (, int24 rawTick,,,,,) = IPancakeV3Pool(pool).slot0();

        // Canonical means "quote per token, rising with the tick". Pancake sorts
        // a pool's tokens by address, so when the launched token sorts SECOND
        // the pool prices token-per-quote and its tick runs backwards: the token
        // getting more expensive moves the pool tick DOWN. The factory already
        // mirrors ranges on the way in for the same reason
        // (`tokenIsToken0 ? (lower, upper) : (-upper, -lower)`), so everything
        // read back out has to be mirrored the same way.
        //
        // Getting this backwards does not fail loudly — it would mark every
        // token graduated the instant it launched, or never mark any. Both
        // orderings are covered in Graduation.t.sol.
        int24 canonicalTick = tokenIsToken0 ? rawTick : -rawTick;
        int24 graduationTick = _graduationTick(ids, tokenIsToken0, pool);

        if (canonicalTick < graduationTick) revert CurveNotExhausted();

        blockNumber = uint64(block.number);
        graduatedAtBlock[token] = blockNumber;
        emit Graduated(token, pool, canonicalTick, blockNumber);
    }

    /// @notice True once `token` has been stamped. Never becomes false again.
    function hasGraduated(address token) external view returns (bool) {
        return graduatedAtBlock[token] != 0;
    }

    /// @dev Resolves the pool from the position itself rather than from a
    /// factory record, so this works for any generation, past or future.
    function _poolFor(address token, uint256 tokenId) internal view returns (address pool, bool tokenIsToken0) {
        (,, address token0, address token1, uint24 fee,,,,,,,) = positionManager.positions(tokenId);

        if (token == token0) tokenIsToken0 = true;
        else if (token != token1) revert TokenNotInPosition();

        pool = pancakeV3Factory.getPool(token0, token1, fee);
        if (pool == address(0)) revert PoolNotFound();
    }

    /// @dev The curve range's upper bound, in canonical terms.
    ///
    /// Taken as the LOWEST canonical upper across every locked range rather
    /// than trusting `ids[0]`. The factory does assign them in the order they
    /// were passed, so the curve range is first today — but that is a property
    /// of how the launch form happens to build its array, and a registry that
    /// silently reads the wrong range if someone reorders it would be a very
    /// quiet way to break this.
    function _graduationTick(uint256[] memory ids, bool tokenIsToken0, address pool)
        internal
        view
        returns (int24 lowest)
    {
        bool first = true;
        for (uint256 i = 0; i < ids.length; i++) {
            (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper,,,,,) =
                positionManager.positions(ids[i]);

            // Every range must be in the SAME pool. Belt and braces given the
            // locker is now trusted, but it is what stops a multi-pair launch —
            // which also holds several positions — from having its line taken
            // as a minimum across pools priced in different quote assets.
            if (pancakeV3Factory.getPool(token0, token1, fee) != pool) revert PositionNotInPool();

            int24 canonicalUpper = tokenIsToken0 ? tickUpper : -tickLower;
            if (first || canonicalUpper < lowest) {
                lowest = canonicalUpper;
                first = false;
            }
        }
    }
}
