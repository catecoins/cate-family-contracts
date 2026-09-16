// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CateFamilyTestBase} from "./Base.t.sol";
import {CateFamilyFactory} from "../src/CateFamilyFactory.sol";
import {CateFamilyMultiPairFactory} from "../src/CateFamilyMultiPairFactory.sol";
import {CateFamilyLiquidityLocker} from "../src/CateFamilyLiquidityLocker.sol";
import {CateFamilyFeeSplitter, CateFamilyFeeSplitterFactory} from "../src/CateFamilyFeeSplitter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A wallet that cannot be paid. Stands in for the realistic cases: a
/// blacklisted address, a paused token, a contract that reverts on receipt.
contract RefusingWallet {
    // No receive, no fallback — but ERC20 transfers do not call the recipient,
    // so refusal has to come from the token. See RefusingToken below.
}

/// @dev Refuses transfers to one specific address, the way a blacklist does.
contract BlacklistToken is IERC20 {
    string public constant name = "Blacklist";
    string public constant symbol = "BL";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public blocked;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address blocked_) {
        blocked = blocked_;
        totalSupply = 1e27;
        balanceOf[msg.sender] = 1e27;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(to != blocked, "BL: blocked");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(t != blocked, "BL: blocked");
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @notice Splitting a creator's fee share across fixed wallets.
///
/// The money here belongs to people who are not the caller, so the properties
/// that matter are arithmetic exactness and the impossibility of one recipient
/// stalling the others.
contract FeeSplitterTest is CateFamilyTestBase {
    CateFamilyFeeSplitterFactory internal splitterFactory;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint16 internal constant ROUTING_FEE_BPS = 1000; // 10%

    function setUp() public override {
        super.setUp();
        splitterFactory = new CateFamilyFeeSplitterFactory(address(factory), owner, ROUTING_FEE_BPS);
        vm.etch(alice, "");
        vm.etch(bob, "");
        vm.etch(carol, "");
    }

    function _addrs(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        (out[0], out[1]) = (a, b);
    }

    function _addrs(address a, address b, address c) internal pure returns (address[] memory out) {
        out = new address[](3);
        (out[0], out[1], out[2]) = (a, b, c);
    }

    function _bps(uint16 a, uint16 b) internal pure returns (uint16[] memory out) {
        out = new uint16[](2);
        (out[0], out[1]) = (a, b);
    }

    function _bps(uint16 a, uint16 b, uint16 c) internal pure returns (uint16[] memory out) {
        out = new uint16[](3);
        (out[0], out[1], out[2]) = (a, b, c);
    }

    /// @dev Launches a token whose creator fees route to `splitter`, and trades
    /// it so real fees accrue.
    function _launchRoutedTo(address splitter, uint256 salt) internal returns (address tkn, address pl) {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(salt);
        p.creatorFeeRecipient = splitter;

        vm.prank(creator);
        (tkn, pl,) = factory.launch(p);

        _buy(pl, tkn, WBNB, trader, 20 ether);
        _sell(pl, tkn, WBNB, trader, IERC20(tkn).balanceOf(trader) / 2);
    }

    // ------------------------------------------------------------ the split

    /// The end-to-end journey, and the arithmetic that matters: the platform
    /// takes exactly its 10%, and the rest lands in the agreed proportions.
    function test_SplitsTheCreatorShareAcrossWallets() public {
        address splitter = splitterFactory.create(_addrs(alice, bob), _bps(7000, 3000));
        (address tkn,) = _launchRoutedTo(splitter, 1);

        uint256 treasuryBefore = IERC20(WBNB).balanceOf(treasury);

        uint256 distributed = CateFamilyFeeSplitter(splitter).distribute(locker, tkn, WBNB);

        assertGt(distributed, 0, "there were fees to split");

        uint256 platformFee = (distributed * ROUTING_FEE_BPS) / 10_000;
        uint256 payout = distributed - platformFee;

        assertEq(IERC20(WBNB).balanceOf(treasury) - treasuryBefore, platformFee, "platform took exactly 10%");
        assertEq(IERC20(WBNB).balanceOf(alice), (payout * 7000) / 10_000, "alice got 70%");
        assertEq(IERC20(WBNB).balanceOf(bob), payout - (payout * 7000) / 10_000, "bob got the rest");
        assertEq(IERC20(WBNB).balanceOf(splitter), 0, "nothing left behind");
    }

    /// Three uneven ways, which is where a naive loop goes wrong.
    ///
    /// Computing each share against the SHRINKING balance rather than the whole
    /// payout pays roughly 33/22/45 on an even three-way split instead of
    /// 33/33/34. It is an easy mistake, it is silent, and it costs the last
    /// recipients real money — so it gets its own test.
    function test_AnEvenThreeWaySplitIsActuallyEven() public {
        address splitter = splitterFactory.create(_addrs(alice, bob, carol), _bps(3333, 3333, 3334));
        (address tkn,) = _launchRoutedTo(splitter, 2);

        uint256 distributed = CateFamilyFeeSplitter(splitter).distribute(locker, tkn, WBNB);
        uint256 payout = distributed - (distributed * ROUTING_FEE_BPS) / 10_000;

        uint256 a = IERC20(WBNB).balanceOf(alice);
        uint256 b = IERC20(WBNB).balanceOf(bob);
        uint256 c = IERC20(WBNB).balanceOf(carol);

        assertEq(a, (payout * 3333) / 10_000, "alice exactly 33.33%");
        assertEq(b, (payout * 3333) / 10_000, "bob exactly 33.33%");
        assertEq(a, b, "the two equal shares really are equal");
        assertEq(a + b + c, payout, "every wei placed");
        // Carol's remainder is the dust, never a materially different share.
        assertApproxEqRel(c, a, 0.001e18, "the third share is not skewed");
    }

    /// Rounding dust goes to the recipients, never to us.
    function test_RoundingFavoursTheRecipients() public {
        address splitter = splitterFactory.create(_addrs(alice, bob, carol), _bps(3333, 3333, 3334));
        (address tkn,) = _launchRoutedTo(splitter, 3);

        uint256 treasuryBefore = IERC20(WBNB).balanceOf(treasury);
        uint256 distributed = CateFamilyFeeSplitter(splitter).distribute(locker, tkn, WBNB);

        uint256 toTreasury = IERC20(WBNB).balanceOf(treasury) - treasuryBefore;
        uint256 toWallets = IERC20(WBNB).balanceOf(alice) + IERC20(WBNB).balanceOf(bob) + IERC20(WBNB).balanceOf(carol);

        assertEq(toTreasury, (distributed * ROUTING_FEE_BPS) / 10_000, "platform cut is floored");
        assertEq(toTreasury + toWallets, distributed, "nothing vanished");
    }

    /// The same property at an amount chosen so the division CANNOT come out
    /// even.
    ///
    /// The test above takes whatever the pool produced, and that happened to
    /// divide by ten exactly — which makes floor and ceiling identical and the
    /// assertion blind to which one the contract uses. A hand-picked amount
    /// with a real remainder is what actually pins the direction.
    function test_TheRoundingDirectionIsPinnedAtAnAwkwardAmount() public {
        address splitter = splitterFactory.create(_addrs(alice, bob, carol), _bps(3333, 3333, 3334));

        // Prime, so nothing divides evenly by 10 or by 3.
        uint256 amount = 1_000_000_007;
        deal(WBNB, splitter, amount);

        uint256 treasuryBefore = IERC20(WBNB).balanceOf(treasury);
        // A token with no locked positions: collectAllFees is a no-op, which
        // isolates the payout arithmetic from the collection path.
        CateFamilyFeeSplitter(splitter).distribute(locker, address(0xdead), WBNB);

        uint256 toTreasury = IERC20(WBNB).balanceOf(treasury) - treasuryBefore;
        assertEq(toTreasury, amount / 10, "floored: 100000000, not 100000001");
        assertEq(toTreasury * 10, 1_000_000_000, "and the dust stayed with the wallets");

        uint256 toWallets = IERC20(WBNB).balanceOf(alice) + IERC20(WBNB).balanceOf(bob) + IERC20(WBNB).balanceOf(carol);
        assertEq(toTreasury + toWallets, amount, "every wei placed");
    }

    // ------------------------------------------------- one bad recipient

    /// THE PROPERTY THAT MATTERS MOST. A currency that refuses one address —
    /// a blacklist, a paused transfer — must not freeze everybody else's money.
    /// There is no admin here to unstick it, so a fatal push would strand the
    /// other recipients permanently.
    function test_ARefusedRecipientDoesNotBlockTheOthers() public {
        BlacklistToken bad = new BlacklistToken(bob);
        address splitter = splitterFactory.create(_addrs(alice, bob, carol), _bps(4000, 3000, 3000));

        // Fund the splitter directly: the point under test is the payout loop,
        // not the collection path, which the tests above already cover.
        bad.transfer(splitter, 1_000 ether);

        CateFamilyFeeSplitter s = CateFamilyFeeSplitter(splitter);
        uint256 distributed = s.distribute(locker, address(0xdead), address(bad));

        uint256 payout = distributed - (distributed * ROUTING_FEE_BPS) / 10_000;
        uint256 bobsShare = (payout * 3000) / 10_000;

        // Alice and Carol were paid despite Bob's transfer reverting.
        assertEq(bad.balanceOf(alice), (payout * 4000) / 10_000, "alice paid");
        assertGt(bad.balanceOf(carol), 0, "carol paid, even though she comes AFTER bob");
        assertEq(bad.balanceOf(bob), 0, "bob could not be paid");

        // Bob's share is recorded, not lost.
        assertEq(s.unpaid(bob, address(bad)), bobsShare, "bob is owed his share");
        assertEq(s.owed(address(bad)), bobsShare, "and it is reserved");

        // It is still there to collect once he can receive again.
        bad.blocked();
        vm.prank(bob);
        vm.expectRevert(); // still blacklisted
        s.withdraw(address(bad));
    }

    /// The reserved balance must not be re-counted as fresh income, or the next
    /// distribution pays Bob's stuck share out to everyone a second time.
    function test_AnOwedBalanceIsNotDistributedTwice() public {
        BlacklistToken bad = new BlacklistToken(bob);
        address splitter = splitterFactory.create(_addrs(alice, bob), _bps(5000, 5000));
        CateFamilyFeeSplitter s = CateFamilyFeeSplitter(splitter);

        bad.transfer(splitter, 1_000 ether);
        s.distribute(locker, address(0xdead), address(bad));

        uint256 stuck = s.owed(address(bad));
        assertGt(stuck, 0, "bob's share is stuck in the contract");
        uint256 aliceAfterFirst = bad.balanceOf(alice);

        // Nothing new has arrived, so there is nothing to distribute — the
        // balance that remains belongs to Bob.
        vm.expectRevert(CateFamilyFeeSplitter.NothingToDistribute.selector);
        s.distribute(locker, address(0xdead), address(bad));

        assertEq(bad.balanceOf(alice), aliceAfterFirst, "alice was not paid twice");
        assertEq(s.owed(address(bad)), stuck, "bob's reservation is intact");
    }

    // -------------------------------------------------------- construction

    function test_RejectsAMalformedSplit() public {
        vm.expectRevert(CateFamilyFeeSplitter.SharesMustSumToOneHundredPercent.selector);
        splitterFactory.create(_addrs(alice, bob), _bps(5000, 4000));

        vm.expectRevert(CateFamilyFeeSplitter.SharesMustSumToOneHundredPercent.selector);
        splitterFactory.create(_addrs(alice, bob), _bps(5000, 6000));

        vm.expectRevert(CateFamilyFeeSplitter.DuplicateRecipient.selector);
        splitterFactory.create(_addrs(alice, alice), _bps(5000, 5000));

        vm.expectRevert(CateFamilyFeeSplitter.ZeroAddress.selector);
        splitterFactory.create(_addrs(alice, address(0)), _bps(5000, 5000));

        vm.expectRevert(CateFamilyFeeSplitter.ZeroShare.selector);
        splitterFactory.create(_addrs(alice, bob), _bps(10000, 0));

        vm.expectRevert(CateFamilyFeeSplitter.InvalidRecipientCount.selector);
        splitterFactory.create(new address[](0), new uint16[](0));

        // Mismatched lengths.
        vm.expectRevert(CateFamilyFeeSplitter.InvalidRecipientCount.selector);
        splitterFactory.create(_addrs(alice, bob), _bps(10000, 0, 0));
    }

    function test_AcceptsTheMaximumNumberOfRecipients() public {
        address[] memory many = new address[](10);
        uint16[] memory shares = new uint16[](10);
        for (uint256 i = 0; i < 10; i++) {
            many[i] = makeAddr(string.concat("r", vm.toString(i)));
            shares[i] = 1000;
        }
        address splitter = splitterFactory.create(many, shares);
        (address[] memory got,) = CateFamilyFeeSplitter(splitter).recipients();
        assertEq(got.length, 10);

        address[] memory tooMany = new address[](11);
        uint16[] memory tooManyShares = new uint16[](11);
        for (uint256 i = 0; i < 11; i++) {
            tooMany[i] = makeAddr(string.concat("x", vm.toString(i)));
            tooManyShares[i] = i == 10 ? 1000 : 900;
        }
        vm.expectRevert(CateFamilyFeeSplitter.InvalidRecipientCount.selector);
        splitterFactory.create(tooMany, tooManyShares);
    }

    // ------------------------------------------------------- immutability

    /// The deal a creator agreed to cannot be changed afterwards — by anyone,
    /// including us. That is the whole reason to route fees here instead of
    /// trusting someone to forward them.
    function test_TheSplitIsPublishedAndPermanent() public {
        address splitter = splitterFactory.create(_addrs(alice, bob), _bps(7000, 3000));
        CateFamilyFeeSplitter s = CateFamilyFeeSplitter(splitter);

        (address[] memory addrs, uint16[] memory shares) = s.recipients();
        assertEq(addrs[0], alice);
        assertEq(shares[0], 7000);
        assertEq(s.platformFeeBps(), ROUTING_FEE_BPS, "the fee is snapshotted at deployment");

        // Raising the platform's routing fee leaves existing splitters alone.
        vm.prank(owner);
        splitterFactory.scheduleRoutingFee(2000);
        vm.warp(vm.getBlockTimestamp() + splitterFactory.CONFIG_DELAY());
        splitterFactory.applyRoutingFee();
        assertEq(s.platformFeeBps(), ROUTING_FEE_BPS, "an existing split is untouched");
        assertEq(splitterFactory.routingFeeBps(), 2000, "only new ones get the new fee");
    }

    function test_TheRoutingFeeIsCapped() public {
        vm.prank(owner);
        vm.expectRevert(CateFamilyFeeSplitterFactory.ConfigOutOfBounds.selector);
        splitterFactory.scheduleRoutingFee(2001);
    }

    /// Once a launch's fees point at a splitter, nobody can redirect them —
    /// `setCreatorFeeRecipient` may only be called by the current recipient,
    /// and the splitter has no function that calls it.
    function test_RoutingToASplitterIsOneWay() public {
        address splitter = splitterFactory.create(_addrs(alice, bob), _bps(5000, 5000));
        (address tkn,) = _launchRoutedTo(splitter, 4);

        uint256[] memory ids = locker.positionsOf(tkn);
        (, address recorded,) = locker.lockedPositions(ids[0]);
        assertEq(recorded, splitter, "fees are routed to the splitter");

        // The creator no longer holds the right.
        vm.prank(creator);
        vm.expectRevert(CateFamilyLiquidityLocker.OnlyCreatorFeeRecipient.selector);
        locker.setCreatorFeeRecipient(ids[0], creator);
    }

    /// The payout loop is self-only. It takes a recipient and an amount, so an
    /// open version would let anyone drain the contract.
    function test_ThePayoutHelperIsSelfOnly() public {
        address splitter = splitterFactory.create(_addrs(alice, bob), _bps(5000, 5000));
        deal(WBNB, splitter, 100 ether);

        vm.prank(makeAddr("thief"));
        vm.expectRevert(CateFamilyFeeSplitter.OnlySelf.selector);
        CateFamilyFeeSplitter(splitter).payOne(WBNB, makeAddr("thief"), 100 ether);
    }

    // -------------------------------------------------------- multi-currency

    /// A bStock launch accrues one balance per distinct quote asset, so
    /// `distribute` is called once per currency. An empty one must say so
    /// rather than reverting somewhere confusing.
    function test_MultiCurrencyAndEmptyCurrencies() public {
        address splitter = splitterFactory.create(_addrs(alice, bob), _bps(5000, 5000));

        CateFamilyMultiPairFactory.LaunchParams memory p;
        p.name = "Multi";
        p.symbol = "MULTI";
        p.metadataURI = "";
        p.totalSupply = DEFAULT_SUPPLY;
        p.salt = bytes32(uint256(55));
        p.maxLaunchFeeWei = 5 ether;
        p.creatorFeeRecipient = splitter;
        p.pairs = new CateFamilyMultiPairFactory.PairConfig[](2);
        p.pairs[0] = CateFamilyMultiPairFactory.PairConfig({
            quoteToken: WBNB, fee: FEE_1PCT, initialTick: TICK_10_BNB_MCAP, supplyBps: 5000
        });
        p.pairs[1] = CateFamilyMultiPairFactory.PairConfig({
            quoteToken: USDT, fee: FEE_1PCT, initialTick: -122000, supplyBps: 5000
        });

        vm.prank(creator);
        (address tkn, address[] memory pools,) = multiPairFactory.launch(p);

        // Only the WBNB pool trades.
        _buy(pools[0], tkn, WBNB, trader, 20 ether);

        CateFamilyLiquidityLocker mpLocker = multiPairFactory.locker();
        CateFamilyFeeSplitter s = CateFamilyFeeSplitter(splitter);

        assertGt(s.distribute(mpLocker, tkn, WBNB), 0, "the traded currency pays out");
        assertGt(IERC20(WBNB).balanceOf(alice), 0);

        // The untraded one has nothing, and says so by name.
        vm.expectRevert(CateFamilyFeeSplitter.NothingToDistribute.selector);
        s.distribute(mpLocker, tkn, USDT);
    }
}
