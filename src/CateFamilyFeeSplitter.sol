// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CateFamilyLiquidityLocker, ICateFamilyFeeConfig} from "./CateFamilyLiquidityLocker.sol";

/// @title CateFamilyFeeSplitter
/// @notice Splits a launch's creator fee share across fixed wallets, forever.
///
/// A creator's share of trading fees is otherwise all-or-nothing: it accrues to
/// one address, or it goes permanently to the buyback-and-burn distributor.
/// This is the third option — a team, a co-founder, a marketing wallet — with
/// the shares fixed at deployment and no function anywhere that can move them.
///
/// ## Why this is not a per-token contract
///
/// The locker credits fees to `claimableFees[recipient][currency]` and never
/// calls the recipient, and `claimFees` keys on `msg.sender`. So a splitter
/// needs to know nothing about the token at construction — it claims its OWN
/// credit and divides it. The token and locker are call arguments instead.
///
/// That makes one splitter reusable across every launch by the same team. The
/// commingling that forces the distributor to be one-contract-per-token is
/// harmless here, because the recipients and shares are identical either way.
///
/// It also means the splitter is deployed BEFORE the launch and its address
/// passed to `launch()` directly, rather than being predicted through CREATE2.
/// Prediction would have to cover the recipient list, since that list is part
/// of the initcode — and the failure mode of getting that wrong is fees
/// accruing forever to an address where the contract was never deployed.
///
/// ## Once wired, it cannot be unwired
///
/// `setCreatorFeeRecipient` may only be called by the CURRENT recipient. Once a
/// position points here, only this contract could redirect it, and this
/// contract has no such function. That is the guarantee the splitter exists to
/// provide: a co-founder can verify on-chain that their share cannot be taken
/// away later.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
contract CateFamilyFeeSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    /// @notice Wallets one splitter may pay. Bounds the loop and the gas.
    uint256 public constant MAX_RECIPIENTS = 10;

    /// @dev Read for the live treasury address, exactly as the locker does, so
    /// a treasury move is picked up rather than frozen at deployment.
    address public immutable cappuccinoFactory;

    /// @notice Platform share of everything routed through this contract, in
    /// basis points, SNAPSHOTTED at deployment.
    ///
    /// Fixed for the life of the splitter on purpose. A creator agreeing to a
    /// split is agreeing to a specific deal, and a share the platform could
    /// raise afterwards would not be one — the same reasoning that freezes
    /// `protocolFeeBps` per position in the locker.
    uint16 public immutable platformFeeBps;

    address[] internal _recipients;
    uint16[] internal _shares;

    /// @notice Owed to a recipient whose transfer failed, claimable by them.
    /// @dev See `distribute`: a currency that refuses one address must not be
    /// able to freeze everybody else's fees.
    mapping(address recipient => mapping(address currency => uint256)) public unpaid;

    /// @notice Total `unpaid` across recipients for a currency.
    /// @dev Subtracted from the balance before splitting, or a failed push
    /// would be counted as fresh income and paid out twice.
    mapping(address currency => uint256) public owed;

    event Distributed(
        address indexed caller, address indexed token, address indexed currency, uint256 amount, uint256 platformFee
    );
    event RecipientPaid(address indexed recipient, address indexed currency, uint256 amount);
    event RecipientPaymentFailed(address indexed recipient, address indexed currency, uint256 amount);
    event Withdrawn(address indexed recipient, address indexed currency, uint256 amount);

    error ZeroAddress();
    error InvalidRecipientCount();
    error SharesMustSumToOneHundredPercent();
    error DuplicateRecipient();
    error ZeroShare();
    error NothingToDistribute();
    error NothingToWithdraw();
    error OnlySelf();

    constructor(
        address cappuccinoFactory_,
        uint16 platformFeeBps_,
        address[] memory recipients_,
        uint16[] memory shares_
    ) {
        if (cappuccinoFactory_ == address(0)) revert ZeroAddress();

        uint256 count = recipients_.length;
        if (count == 0 || count > MAX_RECIPIENTS || count != shares_.length) revert InvalidRecipientCount();

        uint256 total;
        for (uint256 i = 0; i < count; i++) {
            if (recipients_[i] == address(0)) revert ZeroAddress();
            if (shares_[i] == 0) revert ZeroShare();
            // A duplicate would still pay the right total, but it makes the
            // published split unreadable — two rows for one wallet — so it is
            // refused rather than silently summed.
            for (uint256 j = 0; j < i; j++) {
                if (recipients_[j] == recipients_[i]) revert DuplicateRecipient();
            }
            total += shares_[i];
        }
        if (total != BPS_DENOMINATOR) revert SharesMustSumToOneHundredPercent();

        cappuccinoFactory = cappuccinoFactory_;
        platformFeeBps = platformFeeBps_;
        _recipients = recipients_;
        _shares = shares_;
    }

    /// @notice Collects a launch's fees, claims this contract's share of them,
    /// and pays every recipient. Callable by anyone, at any time.
    ///
    /// @param locker The locker holding the launch. A single-pair launch and a
    /// bStock launch live in DIFFERENT lockers, each deployed by its own
    /// factory, so this cannot be inferred and has to be passed.
    /// @param token The launched token, for the collection step.
    /// @param currency Which quote asset to pay out. A bStock launch accrues in
    /// one currency per distinct quote asset, so this is called once each.
    function distribute(CateFamilyLiquidityLocker locker, address token, address currency)
        external
        nonReentrant
        returns (uint256 distributed)
    {
        // Permissionless, so it can be done here rather than as a separate
        // transaction the caller has to remember.
        locker.collectAllFees(token);

        // Guarded: `claimFees` reverts NothingToClaim at zero, which would make
        // an otherwise valid sweep fail on a currency that happens to be empty.
        if (locker.claimableFees(address(this), currency) > 0) {
            locker.claimFees(currency, address(this));
        }

        // Balance rather than the claim's return value, so quote sent here
        // directly is distributed too. Less what is already owed to recipients
        // from earlier failed transfers, which is sitting in the same balance.
        uint256 balance = IERC20(currency).balanceOf(address(this));
        uint256 reserved = owed[currency];
        distributed = balance > reserved ? balance - reserved : 0;
        if (distributed == 0) revert NothingToDistribute();

        // Floored, so the rounding dust falls to the recipients rather than to
        // the platform.
        uint256 platformFee = (distributed * platformFeeBps) / BPS_DENOMINATOR;
        if (platformFee > 0) {
            _pay(currency, ICateFamilyFeeConfig(cappuccinoFactory).treasury(), platformFee);
        }

        // Each share is a fraction of the WHOLE payout, not of what is left
        // after the previous recipient — computing it against a shrinking
        // balance would pay 33/22/45 on an even three-way split. Same shape as
        // the supply split at CateFamilyFactory._positionFor.
        uint256 payout = distributed - platformFee;
        uint256 remaining = payout;
        uint256 count = _recipients.length;
        for (uint256 i = 0; i < count; i++) {
            // The last recipient takes the remainder, so the whole amount is
            // always placed and nothing accumulates as dust.
            uint256 amount = i == count - 1 ? remaining : (payout * _shares[i]) / BPS_DENOMINATOR;
            remaining -= amount;
            if (amount > 0) _pay(currency, _recipients[i], amount);
        }

        emit Distributed(msg.sender, token, currency, distributed, platformFee);
    }

    /// @notice Withdraws what a failed transfer left owed to the caller.
    function withdraw(address currency) external nonReentrant returns (uint256 amount) {
        amount = unpaid[msg.sender][currency];
        if (amount == 0) revert NothingToWithdraw();
        unpaid[msg.sender][currency] = 0;
        owed[currency] -= amount;
        IERC20(currency).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, currency, amount);
    }

    /// @notice The split, as published. Anyone can verify it, which is the
    /// point of routing fees here rather than trusting someone to forward them.
    function recipients() external view returns (address[] memory addresses, uint16[] memory shares) {
        return (_recipients, _shares);
    }

    /// @dev Exists only so `_pay` can wrap one transfer in try/catch, which
    /// Solidity permits solely around an external call. Self-only.
    function payOne(address currency, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC20(currency).safeTransfer(to, amount);
    }

    /// @dev A transfer that fails is recorded rather than fatal.
    ///
    /// Several BEP20s can refuse a specific address — a blacklist, a paused
    /// transfer, a recipient contract that reverts. Without this, one such
    /// address among ten would freeze every other recipient's fees
    /// permanently, since there is no admin here to unstick it. The same
    /// lesson `collectAllFees` learned in the locker.
    function _pay(address currency, address to, uint256 amount) internal {
        try this.payOne(currency, to, amount) {
            emit RecipientPaid(to, currency, amount);
        } catch {
            unpaid[to][currency] += amount;
            owed[currency] += amount;
            emit RecipientPaymentFailed(to, currency, amount);
        }
    }
}

/// @title CateFamilyFeeSplitterFactory
/// @notice Deploys fee splitters and records the platform's routing fee.
///
/// Deliberately NOT CREATE2: a splitter is deployed before the launch that uses
/// it, so there is nothing to predict. See the note on CateFamilyFeeSplitter.
/// @author Cate Family (https://cate.family)
/// @custom:website https://cate.family
/// @custom:x https://x.com/catecoin
/// @custom:telegram https://t.me/catecoin
contract CateFamilyFeeSplitterFactory is Ownable2Step {
    /// @notice Hard ceiling on the platform's cut of routed fees.
    /// @dev A constant, so raising it needs new contracts. The dial underneath
    /// is `routingFeeBps`.
    uint16 public constant MAX_ROUTING_FEE_BPS = 2000;

    /// @notice The launch factory, passed to each splitter so it can read the
    /// live treasury address.
    address public immutable cappuccinoFactory;

    /// @notice Platform share of routed fees, in basis points. Snapshotted into
    /// each splitter at deployment, so changing it never affects one already
    /// deployed.
    uint16 public routingFeeBps;

    /// @notice Delay between scheduling and applying a routing-fee change.
    uint256 public constant CONFIG_DELAY = 48 hours;
    /// @notice A scheduled change not applied within this long after its delay
    /// lapses: notice cannot be banked and applied at a moment of choice.
    uint256 public constant CONFIG_EXPIRY = 7 days;
    /// @notice Scheduled routing fee and when it may apply (eta == 0: none).
    uint16 public pendingRoutingFeeBps;
    uint64 public pendingRoutingFeeEta;

    mapping(address creator => address[] splitters) internal _splittersOf;

    event SplitterCreated(
        address indexed splitter, address indexed creator, uint16 platformFeeBps, address[] recipients, uint16[] shares
    );
    event RoutingFeeUpdated(uint16 routingFeeBps);
    event RoutingFeeScheduled(uint16 routingFeeBps, uint64 eta);
    event RoutingFeeCancelled();

    error ZeroAddress();
    error ConfigOutOfBounds();
    error NoPendingConfig();
    error ConfigNotReady(uint64 eta);
    error ConfigExpired(uint64 eta);
    error RenounceDisabled();

    constructor(address cappuccinoFactory_, address owner_, uint16 routingFeeBps_) Ownable(owner_) {
        if (cappuccinoFactory_ == address(0)) revert ZeroAddress();
        if (routingFeeBps_ > MAX_ROUTING_FEE_BPS) revert ConfigOutOfBounds();
        cappuccinoFactory = cappuccinoFactory_;
        routingFeeBps = routingFeeBps_;
    }

    /// @notice Deploys a splitter with a fixed set of recipients and shares.
    /// The caller is recorded only so the launch form can list what they have
    /// created; it carries no rights over the splitter.
    function create(address[] calldata recipients, uint16[] calldata shares) external returns (address splitter) {
        splitter = address(new CateFamilyFeeSplitter(cappuccinoFactory, routingFeeBps, recipients, shares));
        _splittersOf[msg.sender].push(splitter);
        emit SplitterCreated(splitter, msg.sender, routingFeeBps, recipients, shares);
    }

    /// @notice Splitters a given address has deployed through this factory.
    function splittersOf(address creator) external view returns (address[] memory) {
        return _splittersOf[creator];
    }

    /// @notice Schedules a routing-fee change; applies after CONFIG_DELAY.
    function scheduleRoutingFee(uint16 routingFeeBps_) external onlyOwner {
        if (routingFeeBps_ > MAX_ROUTING_FEE_BPS) revert ConfigOutOfBounds();
        pendingRoutingFeeBps = routingFeeBps_;
        pendingRoutingFeeEta = uint64(block.timestamp + CONFIG_DELAY);
        emit RoutingFeeScheduled(routingFeeBps_, pendingRoutingFeeEta);
    }

    /// @notice Applies the scheduled routing fee once due. Callable by anyone.
    function applyRoutingFee() external {
        uint64 eta = pendingRoutingFeeEta;
        if (eta == 0) revert NoPendingConfig();
        if (block.timestamp < eta) revert ConfigNotReady(eta);
        if (block.timestamp > eta + CONFIG_EXPIRY) revert ConfigExpired(eta);
        routingFeeBps = pendingRoutingFeeBps;
        delete pendingRoutingFeeBps;
        delete pendingRoutingFeeEta;
        emit RoutingFeeUpdated(routingFeeBps);
    }

    function cancelRoutingFee() external onlyOwner {
        if (pendingRoutingFeeEta == 0) revert NoPendingConfig();
        delete pendingRoutingFeeBps;
        delete pendingRoutingFeeEta;
        emit RoutingFeeCancelled();
    }

    /// @dev See CateFamilyFactory.renounceOwnership.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
