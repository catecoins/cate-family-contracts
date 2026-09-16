// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CateFamilyTestBase, DummyERC20} from "./Base.t.sol";
import {CateFamilyFactory} from "../src/CateFamilyFactory.sol";
import {CateFamilyDistributorFactory, CateFamilyHolderDistributor} from "../src/CateFamilyDistributorFactory.sol";
import {CateFamilyLiquidityLocker} from "../src/CateFamilyLiquidityLocker.sol";
import {IPancakeV3Pool} from "../src/interfaces/IPancakeV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------------------
// The hostile family
//
// `_validate` accepts ANY address with code as a quote token — no allowlist, by
// design, since the point is that anyone can launch against anything. So every
// quote-side external call in the protocol is attacker-controlled code, and the
// only question is how far the blast radius reaches. These are the shapes that
// matter, and the tests below establish where each one stops.
// ---------------------------------------------------------------------------

/// @dev Skims a percentage on every transfer. The classic accounting breaker:
/// the recipient never receives what the sender was told they sent.
contract FeeOnTransferToken is ERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_) ERC20("Fee On Transfer", "FOT") {
        feeBps = feeBps_;
        _mint(msg.sender, 1e27);
    }

    function mintTo(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || value == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, DEAD_ADDR, fee);
    }

    address internal constant DEAD_ADDR = 0x000000000000000000000000000000000000dEaD;
}

/// @dev Refuses to move at all. Tests that a currency which cannot pay out
/// cannot take anything else down with it.
contract RevertOnTransferToken is ERC20 {
    bool public armed;

    constructor() ERC20("Brick", "BRICK") {
        _mint(msg.sender, 1e27);
    }

    function arm() external {
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (armed && from != address(0)) revert("BRICK: no");
        super._update(from, to, value);
    }
}

/// @dev Reports whatever it is told to — but only from the right moment.
///
/// The naive version of this token (lie constantly) proves nothing: the locker
/// credits a balance DELTA, so a lie present in both reads cancels out. The
/// attack has to flip the lie BETWEEN them, and a hostile token can do exactly
/// that, because the collect itself transfers to the locker — a state-changing
/// call on the attacker's own code, sitting between the two reads.
contract BalanceLiarToken is ERC20 {
    uint256 internal lie;
    uint256 internal pending;
    address internal lieAbout;

    constructor() ERC20("Liar", "LIAR") {
        _mint(msg.sender, 1e27);
    }

    function mintTo(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Arms the lie. It switches on the next time `who` is transferred to,
    /// which during a fee collect is exactly between the locker's two reads.
    function armLie(address who, uint256 amount) external {
        lieAbout = who;
        pending = amount;
    }

    function balanceOf(address account) public view override returns (uint256) {
        uint256 real = super.balanceOf(account);
        return account == lieAbout ? real + lie : real;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to == lieAbout && pending > 0) {
            lie = pending;
            pending = 0;
        }
    }
}

/// @dev Calls back into the protocol from inside a transfer. Every quote-side
/// movement in a launch runs through here.
contract ReentrantQuoteToken is ERC20 {
    CateFamilyFactory public target;
    CateFamilyFactory.LaunchParams internal nested;
    bool public tripped;
    bytes public lastRevert;

    constructor() ERC20("Reentrant", "REENT") {
        _mint(msg.sender, 1e27);
    }

    function arm(CateFamilyFactory target_, CateFamilyFactory.LaunchParams memory nested_) external {
        target = target_;
        nested = nested_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(target) != address(0) && !tripped && from != address(0)) {
            tripped = true;
            try target.launch(nested) {}
            catch (bytes memory err) {
                lastRevert = err;
            }
        }
    }
}

/// @dev USDT-style: mutates state and returns NOTHING. A bare `IERC20.transfer`
/// call reverts on the ABI decode; SafeERC20 is what makes it work.
contract NoReturnDataToken {
    string public constant name = "No Return";
    string public constant symbol = "NORET";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        totalSupply = 1e27;
        balanceOf[msg.sender] = 1e27;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice What a hostile quote token can and cannot do.
///
/// The protocol's defence is not that these tokens are kept out — they are
/// explicitly let in — but that the damage each one can do is confined to its
/// own launches and its own currency. Each test below names the boundary it is
/// pinning, because the value is in the boundary, not in the revert.
contract HostileTokensTest is CateFamilyTestBase {
    /// A price low enough that one token is worth far less than one quote unit,
    /// aligned to the 1% tier's 200 grid.
    int24 internal constant START_TICK = -122000;

    function _hostileParams(address quote, bytes32 salt)
        internal
        pure
        returns (CateFamilyFactory.LaunchParams memory p)
    {
        p = _defaultParams(quote, START_TICK);
        p.salt = salt;
    }

    // ------------------------------------------------- fee-on-transfer

    /// A launch with no first buy moves NO quote at all — the mint is
    /// single-sided — so a skimming quote token is irrelevant to it. Worth
    /// stating: the pool opens fine, and only the buy path is exposed.
    function test_FeeOnTransferQuote_LaunchWithoutFirstBuySucceeds() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(500); // 5%
        vm.prank(creator);
        (address token, address pool,) = factory.launch(_hostileParams(address(fot), bytes32(uint256(1))));

        assertTrue(pool != address(0), "pool opened");
        assertEq(IERC20(address(fot)).balanceOf(address(factory)), 0, "no quote ever touched the factory");
        assertEq(IERC20(token).balanceOf(address(factory)), 0, "factory keeps nothing");
    }

    /// The first buy is where it breaks, and it breaks CLEANLY. The factory
    /// pulls `amountIn` and receives less; the pool then asks for the full
    /// amount in the callback and there is not enough. The whole launch reverts
    /// rather than half-completing — which matters, because the alternative
    /// would be a pool that exists with a creator who paid and got nothing.
    ///
    /// The factory is left holding nothing, which is the property that stops
    /// this becoming a way to drain a later launch's in-flight funds.
    function test_FeeOnTransferQuote_FirstBuyRevertsAndStrandsNothing() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(500);
        fot.mintTo(creator, 10_000 ether);

        CateFamilyFactory.LaunchParams memory p = _hostileParams(address(fot), bytes32(uint256(2)));
        p.initialBuyQuoteAmount = 1_000 ether;

        vm.startPrank(creator);
        IERC20(address(fot)).approve(address(factory), type(uint256).max);
        vm.expectRevert();
        factory.launch(p);
        vm.stopPrank();

        assertEq(IERC20(address(fot)).balanceOf(address(factory)), 0, "nothing stranded in the factory");
    }

    // ------------------------------------------------ balance-of liar

    /// The locker credits fees from BALANCE DELTAS, so a quote token that
    /// inflates its own `balanceOf` inflates its own claimable credit. That is
    /// unavoidable — a token can always lie about itself.
    ///
    /// What must hold is that the lie stays in its own currency: the locker's
    /// USDT and WBNB balances are never a source of payment for a LIAR credit,
    /// because `claimFees` caps the payout at the balance OF THAT CURRENCY.
    /// This is the property the comment at CateFamilyLiquidityLocker.sol:124
    /// claims, and it is otherwise untested.
    function test_BalanceLiarQuote_CannotMakeTheLockerInsolventInOtherCurrencies() public {
        // An honest USDT launch first, so the locker is genuinely holding USDT
        // that a successful attack would have something to reach for.
        vm.prank(creator);
        (address honest, address honestPool,) = factory.launch(_defaultParams(USDT, START_TICK));
        _buy(honestPool, honest, USDT, trader, 20_000 ether);
        locker.collectAllFees(honest);
        uint256 lockerUsdt = IERC20(USDT).balanceOf(address(locker));
        assertGt(lockerUsdt, 0, "locker really is holding USDT");

        // Now the liar's own launch, traded enough to accrue real fees — the
        // collect is what carries the lie into the middle of the two reads.
        BalanceLiarToken liar = new BalanceLiarToken();
        vm.prank(creator);
        (address token, address pool,) = factory.launch(_hostileParams(address(liar), bytes32(uint256(3))));

        liar.mintTo(trader, 20_000 ether);
        vm.startPrank(trader);
        IERC20(address(liar)).approve(address(swapper), type(uint256).max);
        swapper.swap(pool, address(liar) < token, int256(20_000 ether), trader);
        vm.stopPrank();

        liar.armLie(address(locker), 500_000 ether);
        locker.collectAllFees(token);

        // The credit is a fantasy, several orders of magnitude past the fees
        // actually earned — half the invented amount, since the creator takes
        // half and the treasury the rest, which is credited just as falsely.
        uint256 credit = locker.claimableFees(creator, address(liar));
        assertGt(credit, 200_000 ether, "the lie did land as credit");

        // ...and it cannot be paid. `claimFees` caps the payout at
        // `balanceOf(locker)` — read from the SAME lying token, so the cap is a
        // lie too, and the transfer underneath it reverts on the real balance.
        //
        // Note this refines the comment on `claimFees`, which says a
        // misreporting currency "can delay its own claims but never permanently
        // brick them". For a token that lies UPWARD that is not right: the
        // credit is inflated past anything that can ever exist, so the claim is
        // bricked outright rather than delayed. It is still confined — the
        // creator of a LIAR launch loses LIAR fees and nothing else — and the
        // comment has been corrected to say so.
        vm.prank(creator);
        vm.expectRevert();
        locker.claimFees(address(liar), creator);

        // And the honest currency is untouched and still claimable in full.
        assertEq(IERC20(USDT).balanceOf(address(locker)), lockerUsdt, "USDT never moved");
        vm.prank(creator);
        assertGt(locker.claimFees(USDT, creator), 0, "the honest creator is still paid");
    }

    // --------------------------------------------- revert-on-transfer

    /// A currency that refuses to move can brick its own claims — and nothing
    /// else. In particular `collectAllFees` for OTHER tokens must not be caught
    /// up in it, since anyone can call that for anyone.
    function test_RevertOnTransferQuote_BricksOnlyItself() public {
        RevertOnTransferToken brick = new RevertOnTransferToken();
        vm.prank(creator);
        (address token,,) = factory.launch(_hostileParams(address(brick), bytes32(uint256(4))));

        vm.prank(creator);
        (address other, address otherPool,) = factory.launch(_defaultParams(USDT, START_TICK));

        brick.arm();

        // Collecting the brick's launch: nothing accrued, so nothing is moved
        // and it does not revert. It also cannot poison the shared claim state.
        locker.collectAllFees(token);

        // The unrelated launch still collects and pays out normally.
        _buy(otherPool, other, USDT, trader, 20_000 ether);
        locker.collectAllFees(other);
        vm.prank(creator);
        assertGt(locker.claimFees(USDT, creator), 0, "an unrelated currency still pays");
    }

    // ---------------------------------------------------- re-entrancy

    /// The quote token's `transfer` runs INSIDE the swap callback, at the one
    /// moment `_activeSwapPool` is armed. A nested `launch` from there is the
    /// natural attack, and `nonReentrant` is what stops it — the try/catch
    /// records the revert so the test asserts on the reason rather than merely
    /// observing that nothing bad happened.
    function test_ReentrantQuote_NestedLaunchIsRejected() public {
        ReentrantQuoteToken evil = new ReentrantQuoteToken();
        evil.transfer(creator, 100_000 ether);

        CateFamilyFactory.LaunchParams memory outer = _hostileParams(address(evil), bytes32(uint256(5)));
        outer.initialBuyQuoteAmount = 1_000 ether;

        CateFamilyFactory.LaunchParams memory inner = _hostileParams(address(evil), bytes32(uint256(6)));
        evil.arm(factory, inner);

        vm.startPrank(creator);
        IERC20(address(evil)).approve(address(factory), type(uint256).max);
        factory.launch(outer);
        vm.stopPrank();

        assertTrue(evil.tripped(), "the re-entrant path really was taken");
        assertEq(
            bytes4(evil.lastRevert()),
            bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "nested launch was rejected by the reentrancy guard"
        );
    }

    /// `_activeSwapPool` must not be left armed after a launch, or the next
    /// caller inherits an open callback. Asserting it through the public
    /// callback, since the field itself is private.
    function test_SwapCallbackIsDisarmedAfterALaunch() public {
        ReentrantQuoteToken evil = new ReentrantQuoteToken();
        evil.transfer(creator, 100_000 ether);
        CateFamilyFactory.LaunchParams memory p = _hostileParams(address(evil), bytes32(uint256(7)));
        p.initialBuyQuoteAmount = 1_000 ether;

        vm.startPrank(creator);
        IERC20(address(evil)).approve(address(factory), type(uint256).max);
        factory.launch(p);
        vm.stopPrank();

        vm.expectRevert(CateFamilyFactory.UnexpectedSwapCallback.selector);
        factory.pancakeV3SwapCallback(1, 0, abi.encode(address(evil)));
    }

    // -------------------------------------------------- no return data

    /// USDT itself returns no data, so this path is load-bearing on the live
    /// chain. A bare `IERC20.transfer` would revert decoding the empty return;
    /// it works only because every call site uses SafeERC20.
    function test_NoReturnDataQuote_LaunchesAndBuys() public {
        NoReturnDataToken noret = new NoReturnDataToken();
        noret.transfer(creator, 100_000 ether);

        CateFamilyFactory.LaunchParams memory p = _hostileParams(address(noret), bytes32(uint256(8)));
        p.initialBuyQuoteAmount = 1_000 ether;

        vm.startPrank(creator);
        noret.approve(address(factory), type(uint256).max);
        (address token,,) = factory.launch(p);
        vm.stopPrank();

        assertGt(IERC20(token).balanceOf(creator), 0, "the first buy landed");
    }

    // ------------------------------------------ callbacks from nobody

    /// Both swap callbacks are public and unauthenticated by signature. Neither
    /// may be usable by an arbitrary caller to make the contract pay out.
    function test_SwapCallbacksRejectNonPoolCallers() public {
        vm.expectRevert(CateFamilyFactory.UnexpectedSwapCallback.selector);
        factory.pancakeV3SwapCallback(1e18, 0, abi.encode(USDT));

        vm.prank(creator);
        (address token,,) = factory.launch(_defaultParams(USDT, START_TICK));
        CateFamilyHolderDistributor distributor = CateFamilyHolderDistributor(payable(distributorFactory.create(token)));

        vm.prank(makeAddr("nobody"));
        vm.expectRevert(CateFamilyHolderDistributor.UnexpectedSwapCallback.selector);
        distributor.pancakeV3SwapCallback(1e18, 0, "");
    }

    /// `assignPosition` is what makes a position eligible for fee routing. Only
    /// the factory may call it — otherwise anyone could point an arbitrary NFT
    /// at themselves as the creator recipient.
    function test_OnlyTheFactoryCanAssignPositions() public {
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(CateFamilyLiquidityLocker.OnlyCateFamilyFactory.selector);
        locker.assignPosition(1, USDT, makeAddr("nobody"), 5000);
    }
}
