// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CateFamilyTestBase} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CateFamilyFactory} from "../src/CateFamilyFactory.sol";
import {CateFamilyLiquidityLocker} from "../src/CateFamilyLiquidityLocker.sol";
import {CateFamilyHolderDistributor} from "../src/CateFamilyDistributorFactory.sol";
import {INonfungiblePositionManager, IPancakeV3Pool} from "../src/interfaces/IPancakeV3.sol";

contract FeesTest is CateFamilyTestBase {
    address internal token;
    address internal pool;
    uint256 internal positionId;

    function setUp() public override {
        super.setUp();
        _openDistributions(); // this suite exercises the permissionless trigger
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        vm.prank(creator);
        uint256[] memory ids;
        (token, pool, ids) = factory.launch(p);
        positionId = ids[0];
    }

    /// @dev Grows a pool's oracle and fills it with observations spread over
    /// real time, so a TWAP long enough to price a distribution exists.
    ///
    /// The clock is tracked in locals on purpose. Under `via_ir` the optimizer
    /// is entitled to hoist `block.timestamp` out of a loop — within a real
    /// transaction it cannot change — so `vm.warp(block.timestamp + 120)` in a
    /// loop warps to the SAME instant every iteration, the pool writes no new
    /// observations, and every TWAP assertion silently fails.
    function _buildOracleHistory(address distributor, address pl, address tkn) internal {
        CateFamilyHolderDistributor(distributor).prepareOracle(32);
        uint256 timestamp = block.timestamp;
        uint256 blockNumber = block.number;
        for (uint256 i = 0; i < 6; i++) {
            timestamp += 120;
            blockNumber += 1;
            vm.warp(timestamp);
            vm.roll(blockNumber);
            _buy(pl, tkn, WBNB, trader, 0.05 ether);
        }
    }

    /// @dev Round trip through the pool so fees accrue on BOTH sides.
    function _generateFees() internal {
        _buy(pool, token, WBNB, trader, 20 ether);
        uint256 held = IERC20(token).balanceOf(trader);
        _sell(pool, token, WBNB, trader, held / 2);
    }

    // --------------------------------------------------------------- locker

    function test_LiquidityIsPermanentlyLocked() public {
        assertEq(INonfungiblePositionManager(POSITION_MANAGER).ownerOf(positionId), address(locker));

        _generateFees();
        locker.collectFees(positionId);

        // Collecting fees must never move, shrink or approve the position.
        assertEq(
            INonfungiblePositionManager(POSITION_MANAGER).ownerOf(positionId),
            address(locker),
            "position must stay locked after a fee collection"
        );
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(positionId);
        assertGt(liquidity, 0, "launch liquidity must remain in the pool");
    }

    function test_CollectSplitsQuoteFiftyFiftyAndBurnsTokenSide() public {
        _generateFees();

        uint256 deadBefore = IERC20(token).balanceOf(DEAD);
        locker.collectFees(positionId);

        uint256 creatorCredit = locker.claimableFees(creator, WBNB);
        uint256 protocolCredit = locker.claimableFees(locker.PROTOCOL(), WBNB);
        uint256 burned = IERC20(token).balanceOf(DEAD) - deadBefore;

        assertGt(creatorCredit, 0, "creator must be credited quote fees");
        assertGt(burned, 0, "the launched-token side of fees must be burned");
        // 50/50 at protocolLpFeeBps = 5000, allowing one wei of rounding.
        assertApproxEqAbs(creatorCredit, protocolCredit, 1, "quote fees must split 50/50");

        // Neither party is ever credited the launched token itself.
        assertEq(IERC20(token).balanceOf(creator), 0, "creator must not receive launched tokens");
        assertEq(IERC20(token).balanceOf(treasury), 0, "treasury must not receive launched tokens");
        assertEq(IERC20(token).balanceOf(address(locker)), 0, "locker must not retain launched tokens");
    }

    // -------------------------------------------- the 80/20 fee model
    //
    // The split above is the DEPLOYED 50/50. These cover the configuration we
    // are moving to, which is a `setProtocolLpFeeBps` call rather than a code
    // change — 2000 bps sits well under the contract's own 5000 ceiling.

    /// @dev A second launch made after the owner has changed the split, so it
    /// carries a different snapshot from the one in `setUp`.
    function _launchAt(uint16 protocolBps, uint256 salt) internal returns (address tkn, address pl, uint256 id) {
                _setProtocolLpFeeBps(factory, protocolBps);

        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(salt);
        vm.prank(creator);
        uint256[] memory ids;
        (tkn, pl, ids) = factory.launch(p);
        id = ids[0];
    }

    function test_QuoteFeesSplitEightyTwentyAtTwoThousandBps() public {
        (address tkn, address pl, uint256 id) = _launchAt(2000, 8020);

        _buy(pl, tkn, WBNB, trader, 20 ether);
        _sell(pl, tkn, WBNB, trader, IERC20(tkn).balanceOf(trader) / 2);

        uint256 creatorBefore = locker.claimableFees(creator, WBNB);
        uint256 treasuryBefore = locker.claimableFees(locker.PROTOCOL(), WBNB);
        uint256 deadBefore = IERC20(tkn).balanceOf(DEAD);

        locker.collectFees(id);

        uint256 creatorCredit = locker.claimableFees(creator, WBNB) - creatorBefore;
        uint256 protocolCredit = locker.claimableFees(locker.PROTOCOL(), WBNB) - treasuryBefore;
        uint256 total = creatorCredit + protocolCredit;

        assertGt(total, 0, "fees really accrued");
        // 80/20, within a wei of rounding.
        assertApproxEqAbs(protocolCredit, total / 5, 1, "protocol takes a fifth");
        assertApproxEqAbs(creatorCredit, (total * 4) / 5, 1, "creator takes four fifths");

        // The token side is unaffected by the split — still burned in full.
        assertGt(IERC20(tkn).balanceOf(DEAD) - deadBefore, 0, "token side still burned");
        assertEq(IERC20(tkn).balanceOf(treasury), 0, "treasury never receives the launched token");
    }

    /// Rounding must favour the creator, not us. `protocolQuote` floors and the
    /// creator takes the remainder, so at any bps the protocol can only ever be
    /// short by dust — never over.
    function test_RoundingRemainderGoesToTheCreator() public {
        (address tkn, address pl, uint256 id) = _launchAt(2000, 8021);
        _buy(pl, tkn, WBNB, trader, 3 ether);

        locker.collectFees(id);
        uint256 creatorCredit = locker.claimableFees(creator, WBNB);
        uint256 protocolCredit = locker.claimableFees(locker.PROTOCOL(), WBNB);
        uint256 total = creatorCredit + protocolCredit;

        assertEq(protocolCredit, (total * 2000) / 10_000, "protocol share is the floored product");
        assertEq(creatorCredit, total - protocolCredit, "creator receives the exact remainder");
    }

    /// Any split from 0 up to the cap is a transaction, not a deploy.
    ///
    /// `MAX_PROTOCOL_LP_FEE_BPS` is a `constant` — baked into bytecode, so
    /// changing the CEILING would need a redeploy. `protocolLpFeeBps` is
    /// ordinary storage, and the setter bounds it only from above. So the
    /// platform can move its share anywhere in 0–50% freely, and can never
    /// exceed 50% without shipping new contracts. That ceiling is the promise
    /// to creators; everything under it is an operational dial.
    function test_AnySplitUpToTheCapIsSettable() public {
        uint16[4] memory shares = [uint16(0), 2000, 3000, 5000]; // 100/0, 80/20, 70/30, 50/50

        for (uint256 i = 0; i < shares.length; i++) {
            uint16 protocolBps = shares[i];
            (address tkn, address pl, uint256 id) = _launchAt(protocolBps, 9000 + i);

            _buy(pl, tkn, WBNB, trader, 10 ether);

            uint256 creatorBefore = locker.claimableFees(creator, WBNB);
            uint256 treasuryBefore = locker.claimableFees(locker.PROTOCOL(), WBNB);
            locker.collectFees(id);
            uint256 creatorCredit = locker.claimableFees(creator, WBNB) - creatorBefore;
            uint256 protocolCredit = locker.claimableFees(locker.PROTOCOL(), WBNB) - treasuryBefore;
            uint256 total = creatorCredit + protocolCredit;

            assertGt(total, 0, "fees accrued");
            assertEq(protocolCredit, (total * protocolBps) / 10_000, "protocol share is exactly the setting");
            assertEq(creatorCredit, total - protocolCredit, "creator takes the rest");

            (,, uint16 recorded) = locker.lockedPositions(id);
            assertEq(recorded, protocolBps, "and it is what the launch recorded");
        }
    }

    /// One basis point above the cap is refused. This is the line that would
    /// require new contracts to cross.
    function test_ASplitAboveTheCapIsRejected() public {
        address t = factory.treasury();
        uint256 fee = factory.launchFeeWei();
        vm.prank(owner);
        vm.expectRevert(CateFamilyFactory.ConfigOutOfBounds.selector);
        factory.scheduleConfig(t, fee, 5001);

        // And the locker refuses independently, so even a replacement factory
        // pointed at this locker could not assign more than half.
        assertEq(factory.MAX_PROTOCOL_LP_FEE_BPS(), 5000);
    }

    /// The change is forward-only. A token launched under 50/50 keeps 50/50
    /// even after the owner moves to 80/20 — which is the whole reason the UI
    /// has to read each launch's own recorded split rather than a constant.
    function test_ChangingTheSplitLeavesEarlierLaunchesAlone() public {
        // `token` from setUp() launched at the default 5000.
        _generateFees();

                _setProtocolLpFeeBps(factory, 2000);

        locker.collectFees(positionId);
        uint256 creatorCredit = locker.claimableFees(creator, WBNB);
        uint256 protocolCredit = locker.claimableFees(locker.PROTOCOL(), WBNB);

        assertApproxEqAbs(creatorCredit, protocolCredit, 1, "the earlier launch is still 50/50");

        (,, uint16 recorded) = locker.lockedPositions(positionId);
        assertEq(recorded, 5000, "its snapshot is untouched");
        assertEq(factory.protocolLpFeeBps(), 2000, "while the factory now says otherwise");
    }

    function test_ClaimMovesQuoteFeesToWallets() public {
        _generateFees();
        locker.collectFees(positionId);

        uint256 creatorCredit = locker.claimableFees(creator, WBNB);
        vm.prank(creator);
        uint256 claimed = locker.claimFees(WBNB, creator);

        assertEq(claimed, creatorCredit, "claim must pay the full credit");
        assertEq(IERC20(WBNB).balanceOf(creator), creatorCredit, "WBNB must land in the creator wallet");
        assertEq(locker.claimableFees(creator, WBNB), 0, "credit must be cleared");

        uint256 protocolCredit = locker.claimableFees(locker.PROTOCOL(), WBNB);
        vm.prank(treasury);
        locker.claimProtocolFees(WBNB, treasury);
        assertEq(IERC20(WBNB).balanceOf(treasury), protocolCredit, "protocol share must reach the treasury");
    }

    function test_ClaimRevertsWithNothingToClaim() public {
        vm.prank(creator);
        vm.expectRevert(CateFamilyLiquidityLocker.NothingToClaim.selector);
        locker.claimFees(WBNB, creator);
    }

    function test_OnlyFactoryCanAssignPositions() public {
        vm.prank(creator);
        vm.expectRevert(CateFamilyLiquidityLocker.OnlyCateFamilyFactory.selector);
        locker.assignPosition(positionId, token, creator, 5000);
    }

    function test_CreatorCanHandOverFeeRights() public {
        address newRecipient = makeAddr("newRecipient");
        vm.etch(newRecipient, "");

        vm.prank(creator);
        locker.setCreatorFeeRecipient(positionId, newRecipient);

        _generateFees();
        locker.collectFees(positionId);

        assertGt(locker.claimableFees(newRecipient, WBNB), 0, "new recipient must accrue fees");
        assertEq(locker.claimableFees(creator, WBNB), 0, "old recipient accrues nothing after handover");
    }

    function test_NonRecipientCannotStealFeeRights() public {
        vm.prank(trader);
        vm.expectRevert(CateFamilyLiquidityLocker.OnlyCreatorFeeRecipient.selector);
        locker.setCreatorFeeRecipient(positionId, trader);
    }

    function test_AnyoneCanTriggerCollection() public {
        _generateFees();
        vm.prank(makeAddr("randomCaller"));
        locker.collectFees(positionId);
        assertGt(locker.claimableFees(creator, WBNB), 0, "a third party can push fees into credits");
    }

    function test_ProtocolShareFollowsTreasuryChanges() public {
        address newTreasury = makeAddr("newTreasury");
        vm.etch(newTreasury, "");
                _setTreasury(factory, newTreasury);

        _generateFees();
        locker.collectFees(positionId);

        // Credit is keyed to the PROTOCOL slot, never to an address: the
        // current treasury claims all of it, the previous one nothing.
        uint256 credit = locker.claimableFees(locker.PROTOCOL(), WBNB);
        assertGt(credit, 0, "protocol fees accrue to the protocol slot");
        vm.prank(treasury);
        vm.expectRevert(CateFamilyLiquidityLocker.OnlyTreasury.selector);
        locker.claimProtocolFees(WBNB, treasury);
        vm.prank(newTreasury);
        assertEq(locker.claimProtocolFees(WBNB, newTreasury), credit, "the live treasury claims everything");
    }

    // ---------------------------------------------------------- distributor

    function test_HolderRewardsBuyBackAndBurn() public {
        // Launch a second token whose creator fees are routed to holders from
        // block one, using the distributor's pre-computed address.
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(uint256(99));

        address predictedToken =
            factory.predictTokenAddress(creator, p.salt, p.name, p.symbol, p.totalSupply, p.metadataURI);
        address predictedDistributor = distributorFactory.predict(predictedToken);
        p.creatorFeeRecipient = predictedDistributor;

        vm.prank(creator);
        (address tkn, address pl,) = factory.launch(p);
        assertEq(tkn, predictedToken, "token prediction must hold");

        _buy(pl, tkn, WBNB, trader, 20 ether);
        _sell(pl, tkn, WBNB, trader, IERC20(tkn).balanceOf(trader) / 2);
        _buildOracleHistory(distributorFactory.create(tkn), pl, tkn);

        uint256 deadBefore = IERC20(tkn).balanceOf(DEAD);
        (uint256 quoteSpent, uint256 tokensBurned) = distributorFactory.distribute(tkn, 1);

        assertEq(distributorFactory.distributorOf(tkn), predictedDistributor, "CREATE2 address must match");
        assertGt(quoteSpent, 0, "creator fees must be spent buying back");
        assertGt(tokensBurned, 0, "buyback proceeds must be burned");
        // A distribution burns TWICE in one transaction: collectAllFees sends
        // the token-side pool fees to the dead address, then the buyback sends
        // its proceeds there too. So the dead-address delta strictly exceeds
        // the buyback amount alone.
        uint256 deadDelta = IERC20(tkn).balanceOf(DEAD) - deadBefore;
        assertGt(deadDelta, tokensBurned, "fee burn and buyback burn must both land at the dead address");
        assertEq(locker.claimableFees(creator, WBNB), 0, "creator keeps no claimable credit for this launch");
    }

    // -------------------------------------------------- sandwich protection

    /// @dev Launches a token whose creator fees route to holders, trades it so
    /// fees accrue, and returns the token, pool and distributor.
    function _holderRewardLaunch(uint256 salt) internal returns (address tkn, address pl, address distributor) {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(salt);
        address predictedToken =
            factory.predictTokenAddress(creator, p.salt, p.name, p.symbol, p.totalSupply, p.metadataURI);
        p.creatorFeeRecipient = distributorFactory.predict(predictedToken);

        vm.prank(creator);
        (tkn, pl,) = factory.launch(p);
        _buy(pl, tkn, WBNB, trader, 20 ether);
        _sell(pl, tkn, WBNB, trader, IERC20(tkn).balanceOf(trader) / 2);
        distributor = distributorFactory.create(tkn);
    }

    /// @notice A brand-new pool keeps one observation that every trade
    /// overwrites, so no honest TWAP exists yet. Distribution must refuse
    /// rather than fall back to an unprotected market buy.
    function test_DistributeRevertsWhileOracleHasNoHistory() public {
        (address tkn,, address distributor) = _holderRewardLaunch(1001);

        (bool ready,) = CateFamilyHolderDistributor(distributor).oracleReady();
        assertFalse(ready, "a fresh pool must not report a usable TWAP");

        vm.expectRevert(CateFamilyHolderDistributor.TwapUnavailable.selector);
        distributorFactory.distribute(tkn, 0);
    }

    function test_PrepareOracleMakesDistributionPossible() public {
        (address tkn, address pl, address distributor) = _holderRewardLaunch(1002);
        _buildOracleHistory(distributor, pl, tkn);

        (bool ready, uint32 window) = CateFamilyHolderDistributor(distributor).oracleReady();
        assertTrue(ready, "oracle must be usable once history exists");
        assertGe(window, CateFamilyHolderDistributor(distributor).TWAP_WINDOW_SHORT(), "window too short to trust");

        (, uint256 burned) = distributorFactory.distribute(tkn, 0);
        assertGt(burned, 0, "a fairly priced distribution goes through");
    }

    /// @notice THE ATTACK: a searcher front-runs the distribution with a large
    /// buy, expecting the buyback to execute against the inflated price and to
    /// unwind at a profit. The post-trade price then sits far outside the pool's
    /// own TWAP, and the distribution reverts instead of paying the attacker.
    function test_SandwichFrontRunMakesDistributionRevert() public {
        (address tkn, address pl, address distributor) = _holderRewardLaunch(1003);
        _buildOracleHistory(distributor, pl, tkn);

        (, int24 twapBefore) = _tickAndTwap(distributor, pl);

        // Front-run: walk the price far above its own average.
        address attacker = makeAddr("sandwicher");
        vm.etch(attacker, "");
        _buy(pl, tkn, WBNB, attacker, 400 ether);

        (int24 spotAfter,) = _tickAndTwap(distributor, pl);
        assertGt(
            int256(spotAfter),
            int256(twapBefore) + int256(CateFamilyHolderDistributor(distributor).MAX_TICK_DEVIATION()),
            "the front-run must actually push price outside the band, or this test proves nothing"
        );

        // Match on the selector only: the reported tick is the one AFTER the
        // distribution's own swap, which sits a little past the front-run spot.
        vm.expectPartialRevert(CateFamilyHolderDistributor.PriceOutsideTwapBand.selector);
        distributorFactory.distribute(tkn, 0);
    }

    /// @dev Returns the pool's current tick and the distributor's TWAP tick.
    function _tickAndTwap(address distributor, address pl) internal view returns (int24 spot, int24 twap) {
        (, spot,,,,,) = IPancakeV3Pool(pl).slot0();
        // oracleReady exposes the window; recompute the average the same way
        // the distributor does by reading the pool directly.
        (bool ready, uint32 window) = CateFamilyHolderDistributor(distributor).oracleReady();
        if (!ready) return (spot, spot);
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        (int56[] memory cumulatives,) = IPancakeV3Pool(pl).observe(secondsAgos);
        int56 delta = cumulatives[1] - cumulatives[0];
        twap = int24(delta / int56(uint56(window)));
        if (delta < 0 && (delta % int56(uint56(window)) != 0)) twap--;
    }

    /// @notice A distribution never spends more than a slice of the pool's own
    /// depth, so a big accrued balance cannot become one enormous market buy.
    function test_DistributeCapsSpendAgainstPoolDepth() public {
        (address tkn, address pl, address distributor) = _holderRewardLaunch(1004);
        _buildOracleHistory(distributor, pl, tkn);

        uint256 cap = CateFamilyHolderDistributor(distributor).spendCap();

        (uint256 quoteSpent,) = distributorFactory.distribute(tkn, 0);
        assertLe(quoteSpent, cap, "a distribution must stay inside the depth cap");
        assertGt(quoteSpent, 0, "but it must still do something");
    }

    /// @notice Leftover fees are not lost when the cap bites — they stay in the
    /// distributor and go out on the next call.
    function test_CappedRemainderRollsIntoTheNextDistribution() public {
        (address tkn, address pl, address distributor) = _holderRewardLaunch(1005);
        _buildOracleHistory(distributor, pl, tkn);

        distributorFactory.distribute(tkn, 0);
        uint256 leftover = IERC20(WBNB).balanceOf(distributor);

        if (leftover > 0) {
            vm.warp(block.timestamp + CateFamilyHolderDistributor(distributor).MIN_DISTRIBUTION_INTERVAL());
            (uint256 secondSpend,) = distributorFactory.distribute(tkn, 0);
            assertGt(secondSpend, 0, "the remainder must be spendable on a later call");
        }
        assertLe(IERC20(WBNB).balanceOf(distributor), leftover, "the balance must not grow on its own");
    }

    function test_DistributorRevertsWithNothingToDistribute() public {
        address d = distributorFactory.create(token);
        vm.expectRevert(CateFamilyHolderDistributor.NothingToDistribute.selector);
        CateFamilyHolderDistributor(d).distribute(0);
    }

    function test_DistributorIsDeterministicAndIdempotent() public {
        address predicted = distributorFactory.predict(token);
        address first = distributorFactory.create(token);
        address second = distributorFactory.create(token);
        assertEq(first, predicted, "predict must match create");
        assertEq(first, second, "create must be idempotent");
    }

    function test_DistributorEnforcesSlippageFloor() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = bytes32(uint256(123));
        address predictedToken =
            factory.predictTokenAddress(creator, p.salt, p.name, p.symbol, p.totalSupply, p.metadataURI);
        p.creatorFeeRecipient = distributorFactory.predict(predictedToken);

        vm.prank(creator);
        (address tkn, address pl,) = factory.launch(p);
        _buy(pl, tkn, WBNB, trader, 20 ether);
        _buildOracleHistory(distributorFactory.create(tkn), pl, tkn);

        vm.expectRevert();
        distributorFactory.distribute(tkn, type(uint256).max);
    }

    // ------------------------------------------- TWAP band, both orderings

    /// @dev Same salt search as `GraduationTest`: find a token that sorts on the
    /// requested side of WBNB. The distributor's sandwich guard branches on
    /// exactly that, and until this was added every distributor test happened to
    /// land on one side — so half of `_requireWithinTwapBand` had never run.
    function _saltForOrdering(bool wantTokenFirst) internal view returns (bytes32) {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        for (uint256 i = 2000; i < 2512; i++) {
            bytes32 salt = bytes32(i);
            address predicted =
                factory.predictTokenAddress(creator, salt, p.name, p.symbol, p.totalSupply, p.metadataURI);
            if ((predicted < WBNB) == wantTokenFirst) return salt;
        }
        revert("no salt found for that ordering");
    }

    function _holderRewardLaunchOrdered(bool tokenFirst)
        internal
        returns (address tkn, address pl, address distributor)
    {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.salt = _saltForOrdering(tokenFirst);
        address predictedToken =
            factory.predictTokenAddress(creator, p.salt, p.name, p.symbol, p.totalSupply, p.metadataURI);
        p.creatorFeeRecipient = distributorFactory.predict(predictedToken);

        vm.prank(creator);
        (tkn, pl,) = factory.launch(p);
        assertEq(tkn < WBNB, tokenFirst, "salt did not produce the intended ordering");

        _buy(pl, tkn, WBNB, trader, 20 ether);
        _sell(pl, tkn, WBNB, trader, IERC20(tkn).balanceOf(trader) / 2);
        distributor = distributorFactory.create(tkn);
    }

    /// The guard checks only the ADVERSE direction, and which direction that is
    /// depends on token ordering. Getting the branch backwards would not fail
    /// loudly — it would silently stop protecting one half of all launches,
    /// while every test still passed. So both halves are run here.
    function test_SandwichIsBlockedWhenTheTokenSortsFirst() public {
        _assertSandwichBlocked(true);
    }

    function test_SandwichIsBlockedWhenTheTokenSortsSecond() public {
        _assertSandwichBlocked(false);
    }

    function _assertSandwichBlocked(bool tokenFirst) internal {
        (address tkn, address pl, address distributor) = _holderRewardLaunchOrdered(tokenFirst);
        assertEq(
            CateFamilyHolderDistributor(distributor).tokenIsToken0(),
            tokenFirst,
            "the distributor agrees with the pool about ordering"
        );
        _buildOracleHistory(distributor, pl, tkn);

        address sandwicher = makeAddr(tokenFirst ? "sandwicher-a" : "sandwicher-b");
        vm.etch(sandwicher, "");
        _buy(pl, tkn, WBNB, sandwicher, 400 ether);

        vm.expectRevert();
        distributorFactory.distribute(tkn, 0);
    }

    /// The mirror image: a front-run in the direction that makes the buyback
    /// CHEAPER must NOT revert. Without this, a guard that simply rejected any
    /// deviation would look identical to a correct one — and would hand a free
    /// denial-of-service to anyone willing to move the price either way.
    function test_FavourablePriceMoveStillDistributes() public {
        (address tkn, address pl, address distributor) = _holderRewardLaunchOrdered(true);
        _buildOracleHistory(distributor, pl, tkn);

        // Sell into the pool: the launched token gets cheaper, so the buyback
        // executes better than the average rather than worse.
        _sell(pl, tkn, WBNB, trader, IERC20(tkn).balanceOf(trader) / 2);

        (, uint256 burned) = distributorFactory.distribute(tkn, 0);
        assertGt(burned, 0, "a favourable move must not block the distribution");
    }
}
