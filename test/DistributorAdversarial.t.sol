// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CateFamilyTestBase} from "./Base.t.sol";
import {CateFamilyFactory} from "../src/CateFamilyFactory.sol";
import {CateFamilyMultiPairFactory} from "../src/CateFamilyMultiPairFactory.sol";
import {CateFamilyDistributorFactory, CateFamilyHolderDistributor} from "../src/CateFamilyDistributorFactory.sol";
import {IPancakeV3Pool} from "../src/interfaces/IPancakeV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Adversarial coverage for the buy-back-and-burn distributor.
///
/// The distributor is the only contract in the protocol that HOLDS value
/// between transactions — a creator's accrued fees sit in it until someone
/// triggers a distribution. That makes two questions worth answering
/// precisely: can anything take that balance out other than a buy-and-burn,
/// and can the buy itself be steered somewhere profitable for an attacker.
contract DistributorAdversarialTest is CateFamilyTestBase {
    address internal attacker = makeAddr("distributor-attacker");

    function setUp() public override {
        super.setUp();
        _openDistributions(); // this suite exercises the permissionless trigger
        vm.etch(attacker, "");
        vm.deal(attacker, 1_000 ether);
    }

    /// @dev A launch whose creator fees route to its own distributor, traded so
    /// fees really accrue, with the oracle filled so a distribution can price.
    function _rewardLaunch(uint256 salt)
        internal
        returns (address token, address pool, CateFamilyHolderDistributor dist)
    {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(salt);
        address predicted = factory.predictTokenAddress(creator, p.salt, p.name, p.symbol, p.totalSupply, p.metadataURI);
        p.creatorFeeRecipient = distributorFactory.predict(predicted);

        vm.prank(creator);
        (token, pool,) = factory.launch(p);

        _buy(pool, token, WBNB, trader, 20 ether);
        _sell(pool, token, WBNB, trader, IERC20(token).balanceOf(trader) / 2);
        dist = CateFamilyHolderDistributor(distributorFactory.create(token));

        dist.prepareOracle(32);
        uint256 timestamp = block.timestamp;
        uint256 blockNumber = block.number;
        for (uint256 i = 0; i < 6; i++) {
            timestamp += 120;
            blockNumber += 1;
            vm.warp(timestamp);
            vm.roll(blockNumber);
            _buy(pool, token, WBNB, trader, 0.05 ether);
        }
    }

    // ------------------------------------------- can value leave any other way

    /// THE MONEY QUESTION. The distributor holds real WBNB between calls. There
    /// must be no path that moves it anywhere except into the pool as a buy,
    /// with the proceeds burned — no owner, no rescue, no sweep, no recipient
    /// parameter anywhere.
    function test_TheOnlyWayValueLeavesIsABuyAndBurn() public {
        (address token,, CateFamilyHolderDistributor dist) = _rewardLaunch(3001);

        // Fund it by DONATION rather than by waiting for fees, which also pins
        // a real behaviour: `distribute` reads its own balance, so quote sent
        // to a distributor by anyone becomes a buy-back for that token's
        // holders. There is no way to get it back out, which is worth knowing
        // before someone sends money here by mistake.
        // Modest, so the resulting buy stays inside the TWAP band — a larger
        // one is correctly refused, which `test_DonatingToThePool…` covers.
        deal(WBNB, address(this), 0.2 ether);
        IERC20(WBNB).transfer(address(dist), 0.2 ether);

        uint256 held = IERC20(WBNB).balanceOf(address(dist));
        assertGt(held, 0, "the distributor really is sitting on funds");

        uint256 attackerBefore = IERC20(WBNB).balanceOf(attacker);
        uint256 deadBefore = IERC20(token).balanceOf(DEAD);

        // Anyone may trigger it — that is by design. What they must not be able
        // to do is receive any of it.
        vm.prank(attacker);
        (uint256 spent, uint256 burned) = dist.distribute(0);

        assertGt(spent, 0, "it spent");
        assertGt(burned, 0, "it burned");
        assertEq(IERC20(WBNB).balanceOf(attacker), attackerBefore, "the caller received nothing");
        assertEq(IERC20(token).balanceOf(attacker), 0, "the caller received no tokens either");
        assertEq(IERC20(token).balanceOf(address(dist)), 0, "the distributor never holds the token it buys");
        // A distribution burns TWICE in one transaction: `collectAllFees`
        // sends the token-side pool fees to DEAD, then the buyback proceeds go
        // there too. So the delta strictly EXCEEDS the buyback alone — what
        // matters is that nothing bought ended up anywhere else.
        assertGe(IERC20(token).balanceOf(DEAD) - deadBefore, burned, "bought tokens went somewhere other than DEAD");
    }

    /// The swap's recipient is the dead address, hardcoded. So the burn is not
    /// a separate transfer that could be skipped or redirected — the tokens
    /// never exist anywhere else, even for one instruction.
    function test_BoughtTokensNeverTouchTheDistributor() public {
        (address token,, CateFamilyHolderDistributor dist) = _rewardLaunch(3002);
        vm.prank(attacker);
        dist.distribute(0);
        assertEq(IERC20(token).balanceOf(address(dist)), 0, "proceeds go straight to DEAD");
    }

    // ------------------------------------------------- steering the buy

    /// The cap is measured against in-range liquidity, so quote donated
    /// straight to the pool does not loosen it. This checks both: the cap is
    /// unchanged by a donation, and the TWAP band still holds.
    function test_DonatingToThePoolCannotPushTheBuyPastTheTwapBand() public {
        (address token, address pool, CateFamilyHolderDistributor dist) = _rewardLaunch(3003);

        uint256 capBefore = dist.spendCap();
        deal(WBNB, attacker, 5_000 ether);
        vm.prank(attacker);
        IERC20(WBNB).transfer(pool, 5_000 ether);
        assertEq(dist.spendCap(), capBefore, "a donation to the pool does not enlarge the cap");

        (, int24 before,,,,,) = IPancakeV3Pool(pool).slot0();

        // Either it reverts on the band, or it goes through within it. Both are
        // acceptable; drifting far past the TWAP is not.
        try dist.distribute(0) {
            (, int24 after_,,,,,) = IPancakeV3Pool(pool).slot0();
            int24 moved = after_ > before ? after_ - before : before - after_;
            assertLt(moved, dist.MAX_TICK_DEVIATION() * 2, "price walked further than the band allows");
        } catch {}

        assertEq(IERC20(token).balanceOf(address(dist)), 0, "no token stranded whatever happened");
    }

    /// A caller can demand a tighter floor than the on-chain band, but cannot
    /// waive the band by asking for zero — the two protections are independent.
    function test_CallerSlippageIsAdditionalNotAReplacement() public {
        (,, CateFamilyHolderDistributor dist) = _rewardLaunch(3004);

        vm.expectRevert();
        dist.distribute(type(uint256).max);

        // And the same call with no floor still succeeds, so the revert above
        // was the caller's own limit rather than a broken distribution.
        (, uint256 burned) = dist.distribute(0);
        assertGt(burned, 0);
    }

    /// The depth cap, actually reached.
    ///
    /// `test_DistributeCapsSpendAgainstPoolDepth` asserts `spent <= cap`, but
    /// in that scenario the accrued fee balance is far SMALLER than the cap, so
    /// `min(balance, cap)` returns the balance and the cap never binds — the
    /// assertion holds just as well with the cap deleted, which is how a
    /// security control ended up with a test that could not fail.
    ///
    /// This funds the distributor past the cap so the branch is real: the spend
    /// must equal the cap, and the remainder must stay for the next call rather
    /// than being spent, stranded or lost.
    function test_TheDepthCapActuallyBindsAndTheRemainderRollsOver() public {
        (,, CateFamilyHolderDistributor dist) = _rewardLaunch(3012);

        uint256 cap = dist.spendCap();
        assertGt(cap, 0, "precondition: the pool has liquidity in range");

        // Comfortably more than the cap, so `min` has to choose the cap.
        uint256 funded = cap * 4;
        deal(WBNB, address(this), funded);
        IERC20(WBNB).transfer(address(dist), funded);

        uint256 balanceBefore = IERC20(WBNB).balanceOf(address(dist));
        assertGt(balanceBefore, cap, "precondition: the cap is the binding constraint");

        (uint256 spent,) = dist.distribute(0);

        assertLe(spent, cap, "spent past the depth cap");
        assertLt(spent, balanceBefore, "the cap did not bind at all");
        assertGe(
            IERC20(WBNB).balanceOf(address(dist)),
            balanceBefore - cap,
            "the unspent remainder must stay for the next distribution"
        );
    }

    // --------------------------------------------------- who can be a target

    /// A distributor is defined against exactly ONE pool, so a token that never
    /// launched on the single-pair factory has none — including every
    /// multi-pair launch, whose fees live in a different locker entirely.
    function test_RefusesToBuildForATokenWithNoSinglePairLaunch() public {
        vm.expectRevert(CateFamilyHolderDistributor.UnknownLaunch.selector);
        distributorFactory.create(makeAddr("never-launched"));

        CateFamilyMultiPairFactory.LaunchParams memory p;
        p.name = "Multi";
        p.symbol = "MULTI";
        p.metadataURI = "";
        p.totalSupply = DEFAULT_SUPPLY;
        p.salt = bytes32(uint256(3005));
        p.maxLaunchFeeWei = 5 ether;
        p.pairs = new CateFamilyMultiPairFactory.PairConfig[](2);
        p.pairs[0] = CateFamilyMultiPairFactory.PairConfig({
            quoteToken: WBNB, fee: FEE_1PCT, initialTick: TICK_10_BNB_MCAP, supplyBps: 5000
        });
        p.pairs[1] = CateFamilyMultiPairFactory.PairConfig({
            quoteToken: USDT, fee: FEE_1PCT, initialTick: -122000, supplyBps: 5000
        });
        vm.prank(creator);
        (address multiToken,,) = multiPairFactory.launch(p);

        vm.expectRevert(CateFamilyHolderDistributor.UnknownLaunch.selector);
        distributorFactory.create(multiToken);
    }

    /// One distributor per token, at a deterministic address. A second `create`
    /// must return the same one rather than deploying a rival that could split
    /// a launch's fee credit in two.
    function test_OneDistributorPerTokenForever() public {
        (address token,, CateFamilyHolderDistributor dist) = _rewardLaunch(3006);
        assertEq(distributorFactory.create(token), address(dist), "create is idempotent");
        assertEq(distributorFactory.predict(token), address(dist), "prediction matches the deployment");
    }

    /// Each distributor is bound to its own token and pool at construction, so
    /// one launch's fees can never be spent buying another launch's token.
    function test_ADistributorOnlyEverBuysItsOwnToken() public {
        (address tokenA,, CateFamilyHolderDistributor distA) = _rewardLaunch(3007);
        (address tokenB,, CateFamilyHolderDistributor distB) = _rewardLaunch(3008);

        assertEq(distA.token(), tokenA);
        assertEq(distB.token(), tokenB);
        assertTrue(distA.pool() != distB.pool(), "distinct pools");

        uint256 bDeadBefore = IERC20(tokenB).balanceOf(DEAD);
        distA.distribute(0);
        assertEq(IERC20(tokenB).balanceOf(DEAD), bDeadBefore, "A's distribution did not touch B");
    }

    /// Fee credit is keyed by recipient, so two distributors both owed WBNB
    /// must not be able to reach each other's balance.
    function test_TwoDistributorsCannotClaimEachOthersFees() public {
        (address tokenA,, CateFamilyHolderDistributor distA) = _rewardLaunch(3009);
        (,, CateFamilyHolderDistributor distB) = _rewardLaunch(3010);

        locker.collectAllFees(tokenA);
        uint256 owedToA = locker.claimableFees(address(distA), WBNB);
        assertGt(owedToA, 0, "A's distributor is owed something");
        assertEq(locker.claimableFees(address(distB), WBNB), 0, "and B's is owed nothing from A's launch");

        distB.distribute(0);
        assertEq(locker.claimableFees(address(distA), WBNB), owedToA, "B's distribution left A's credit alone");
    }

    // ------------------------------------------------------- the oracle

    /// `prepareOracle` is permissionless and idempotent — a pool's observation
    /// array only ever grows. An attacker calling it cannot shrink the window
    /// or make a distribution cheaper to manipulate.
    function test_AnyoneMayGrowTheOracleAndNobodyCanShrinkIt() public {
        (,, CateFamilyHolderDistributor dist) = _rewardLaunch(3011);
        (bool readyBefore, uint32 windowBefore) = dist.oracleReady();
        assertTrue(readyBefore);

        vm.prank(attacker);
        dist.prepareOracle(1); // below the current cardinality

        (bool readyAfter, uint32 windowAfter) = dist.oracleReady();
        assertTrue(readyAfter, "still usable");
        assertGe(windowAfter, windowBefore, "the window never got shorter");
    }
}
