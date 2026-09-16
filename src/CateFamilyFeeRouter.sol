// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWBNB} from "./interfaces/IPancakeV3.sol";
import {CateFamilyLiquidityLocker} from "./CateFamilyLiquidityLocker.sol";

/// @dev The slice of PancakeSwap's SmartRouter this contract uses.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
interface ISmartRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title CateFamilyFeeRouter
/// @notice The site's swap entry point for graduated and instant-launch tokens.
///
/// PancakeSwap pools are public: nothing can charge a fee on a trade that goes
/// straight to Pancake. What a platform CAN do is charge on the trades made
/// through its own site, which is where most of a launchpad token's volume
/// comes from. This contract is that: it takes `feeBps` of the quote side of
/// every buy and sell routed through it, splits the fee between the token's
/// creator fee recipient and the treasury on the spot, and forwards the rest
/// of the trade to Pancake's SmartRouter unchanged.
///
/// It never holds funds between transactions, has no privileged path to a
/// trader's tokens beyond the allowance a trade needs, and can only route
/// tokens the platform's lockers know, so the creator paid is always the one
/// recorded at that token's launch.
///
/// The fee and the split are owner-settable within fixed caps, behind the same
/// 48-hour delay as every other economic setting on the platform.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
contract CateFamilyFeeRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @dev Hard ceiling on the routed-trade fee: 3%.
    uint16 public constant MAX_FEE_BPS = 300;
    uint256 public constant CONFIG_DELAY = 48 hours;
    uint256 public constant CONFIG_EXPIRY = 7 days;

    struct Config {
        address treasury;
        /// @dev Fee on the quote side of every routed trade, bps.
        uint16 feeBps;
        /// @dev Share of that fee paid to the token's creator fee recipient, bps.
        uint16 creatorShareBps;
    }

    struct PendingConfig {
        Config config;
        uint64 eta;
    }

    ISmartRouter public immutable pancake;
    IWBNB public immutable wbnb;

    Config public config;
    PendingConfig public pendingConfig;
    bool public paused;

    /// @dev Lockers whose records say who a token's creator fee recipient is.
    CateFamilyLiquidityLocker[] public lockers;

    event Routed(
        address indexed token,
        address indexed trader,
        bool isBuy,
        address quote,
        uint256 grossQuote,
        uint256 fee,
        uint256 creatorFee,
        uint256 protocolFee,
        address creatorRecipient
    );
    event ConfigScheduled(Config config, uint64 eta);
    event ConfigApplied(Config config);
    event ConfigCancelled();
    event LockerAdded(address indexed locker);
    event PausedSet(bool paused);

    error ZeroAddress();
    error ConfigOutOfBounds();
    error NoPendingConfig();
    error ConfigNotReady(uint64 eta);
    error ConfigExpired(uint64 eta);
    error Paused();
    error UnknownToken(address token);
    error BadPath();
    error WrongValue();
    error DeadlinePassed();
    error SlippageExceeded(uint256 out, uint256 minOut);
    error NativeSendFailed();

    constructor(
        ISmartRouter pancake_,
        IWBNB wbnb_,
        address owner_,
        Config memory cfg,
        CateFamilyLiquidityLocker[] memory lockers_
    ) Ownable(owner_) {
        if (address(pancake_) == address(0) || address(wbnb_) == address(0)) revert ZeroAddress();
        _validate(cfg);
        pancake = pancake_;
        wbnb = wbnb_;
        config = cfg;
        for (uint256 i = 0; i < lockers_.length; i++) _addLocker(lockers_[i]);
    }

    receive() external payable {}

    // ------------------------------------------------------------------ trades

    /// @notice Buys `token` through Pancake, paying in the first asset of `path`.
    /// @dev Pay in native BNB by sending `amountIn` as value with a path that
    /// starts at WBNB; otherwise the first asset is pulled by allowance. The fee
    /// comes off `amountIn` before the swap, so `minOut` is what the buyer must
    /// receive for the net amount.
    function buy(address token, bytes calldata path, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 out)
    {
        _checks(deadline);
        (address tokenIn, address tokenOut) = _ends(path);
        if (tokenOut != token) revert BadPath();
        address creatorRecipient = _creatorOf(token);

        bool native = msg.value > 0;
        if (native) {
            if (tokenIn != address(wbnb) || msg.value != amountIn) revert WrongValue();
        } else {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        (uint256 fee, uint256 creatorFee, uint256 protocolFee) = _split(amountIn);
        uint256 net = amountIn - fee;

        if (native) {
            _payNative(creatorRecipient, creatorFee);
            _payNative(config.treasury, protocolFee);
            out = pancake.exactInput{value: net}(
                ISmartRouter.ExactInputParams({path: path, recipient: msg.sender, amountIn: net, amountOutMinimum: minOut})
            );
        } else {
            IERC20(tokenIn).safeTransfer(creatorRecipient, creatorFee);
            IERC20(tokenIn).safeTransfer(config.treasury, protocolFee);
            IERC20(tokenIn).forceApprove(address(pancake), net);
            out = pancake.exactInput(
                ISmartRouter.ExactInputParams({path: path, recipient: msg.sender, amountIn: net, amountOutMinimum: minOut})
            );
        }
        emit Routed(token, msg.sender, true, tokenIn, amountIn, fee, creatorFee, protocolFee, creatorRecipient);
    }

    /// @notice Sells `token` through Pancake for the last asset of `path`.
    /// @dev The fee comes off what the swap returns, so `minOut` is the net the
    /// seller must receive. With `unwrap` and a path ending at WBNB, the net is
    /// paid as native BNB.
    function sell(
        address token,
        bytes calldata path,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline,
        bool unwrap
    ) external nonReentrant returns (uint256 net) {
        _checks(deadline);
        (address tokenIn, address tokenOut) = _ends(path);
        if (tokenIn != token) revert BadPath();
        address creatorRecipient = _creatorOf(token);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(token).forceApprove(address(pancake), amountIn);
        uint256 gross = pancake.exactInput(
            ISmartRouter.ExactInputParams({path: path, recipient: address(this), amountIn: amountIn, amountOutMinimum: 0})
        );

        (uint256 fee, uint256 creatorFee, uint256 protocolFee) = _split(gross);
        net = gross - fee;
        if (net < minOut) revert SlippageExceeded(net, minOut);

        if (unwrap && tokenOut == address(wbnb)) {
            wbnb.withdraw(gross);
            _payNative(creatorRecipient, creatorFee);
            _payNative(config.treasury, protocolFee);
            (bool ok,) = msg.sender.call{value: net}("");
            if (!ok) revert NativeSendFailed();
        } else {
            IERC20(tokenOut).safeTransfer(creatorRecipient, creatorFee);
            IERC20(tokenOut).safeTransfer(config.treasury, protocolFee);
            IERC20(tokenOut).safeTransfer(msg.sender, net);
        }
        emit Routed(token, msg.sender, false, tokenOut, gross, fee, creatorFee, protocolFee, creatorRecipient);
    }

    // ------------------------------------------------------------------- views

    /// @notice The fee the router takes on a trade of `grossQuote`, and how it splits.
    function quoteFee(uint256 grossQuote) external view returns (uint256 fee, uint256 creatorFee, uint256 protocolFee) {
        return _split(grossQuote);
    }

    /// @notice Who receives the creator share for `token`, or zero when the
    /// token is not one the platform's lockers know.
    function creatorRecipientOf(address token) external view returns (address) {
        return _lookup(token);
    }

    function lockerCount() external view returns (uint256) {
        return lockers.length;
    }

    // ------------------------------------------------------------------- admin

    /// @notice Schedules new economics; takes effect after CONFIG_DELAY.
    function scheduleConfig(Config calldata next) external onlyOwner {
        _validate(next);
        uint64 eta = uint64(block.timestamp + CONFIG_DELAY);
        pendingConfig = PendingConfig({config: next, eta: eta});
        emit ConfigScheduled(next, eta);
    }

    /// @notice Applies the scheduled economics once the delay has passed. Anyone may call.
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

    /// @notice Registers another locker whose tokens may be routed. Widening
    /// which tokens are recognised moves no value, so it is immediate.
    function addLocker(CateFamilyLiquidityLocker locker) external onlyOwner {
        _addLocker(locker);
    }

    /// @notice Stops routing. Trading itself is unaffected: the pools are public.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Ownership cannot be renounced (H-01): a routerless treasury is a bug, not a feature.
    function renounceOwnership() public view override onlyOwner {
        revert("renounce disabled");
    }

    // --------------------------------------------------------------- internals

    function _checks(uint256 deadline) internal view {
        if (paused) revert Paused();
        if (block.timestamp > deadline) revert DeadlinePassed();
    }

    /// @dev First and last assets of a Pancake V3 path: 20-byte addresses joined by 3-byte fees.
    function _ends(bytes calldata path) internal pure returns (address first, address last) {
        if (path.length < 43 || (path.length - 20) % 23 != 0) revert BadPath();
        first = address(bytes20(path[0:20]));
        last = address(bytes20(path[path.length - 20:]));
    }

    function _creatorOf(address token) internal view returns (address recipient) {
        recipient = _lookup(token);
        if (recipient == address(0)) revert UnknownToken(token);
    }

    function _lookup(address token) internal view returns (address) {
        for (uint256 i = 0; i < lockers.length; i++) {
            uint256[] memory ids = lockers[i].positionsOf(token);
            if (ids.length == 0) continue;
            (, address recipient,) = lockers[i].lockedPositions(ids[0]);
            if (recipient != address(0)) return recipient;
        }
        return address(0);
    }

    function _split(uint256 gross) internal view returns (uint256 fee, uint256 creatorFee, uint256 protocolFee) {
        fee = (gross * config.feeBps) / BPS;
        creatorFee = (fee * config.creatorShareBps) / BPS;
        protocolFee = fee - creatorFee;
    }

    /// @dev Native payout that cannot block a trade: a recipient that refuses
    /// BNB (a contract without a payable path) is paid in WBNB instead.
    function _payNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount, gas: 30_000}("");
        if (!ok) {
            wbnb.deposit{value: amount}();
            IERC20(address(wbnb)).safeTransfer(to, amount);
        }
    }

    function _validate(Config memory cfg) internal pure {
        if (cfg.treasury == address(0)) revert ZeroAddress();
        if (cfg.feeBps > MAX_FEE_BPS || cfg.creatorShareBps > BPS) revert ConfigOutOfBounds();
    }

    function _addLocker(CateFamilyLiquidityLocker locker) internal {
        if (address(locker) == address(0)) revert ZeroAddress();
        lockers.push(locker);
        emit LockerAdded(address(locker));
    }
}
