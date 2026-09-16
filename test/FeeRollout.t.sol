// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CateFamilyTestBase} from "./Base.t.sol";
import {CateFamilyFactory} from "../src/CateFamilyFactory.sol";
import {CateFamilyMultiPairFactory} from "../src/CateFamilyMultiPairFactory.sol";
import {CateFamilyLiquidityLocker} from "../src/CateFamilyLiquidityLocker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The fee rollout, end to end, as the operator will actually perform it.
///
/// `SetFees.s.sol` schedules the config on both factories; `ApplyConfig.s.sol` applies it 48h later on
/// each of the two factories. This applies exactly those and then drives a real
/// launch through to a fee claim, so the config being shipped is proven as a
/// whole rather than one setter at a time.
///
/// It exists because both values have been at their deployment defaults since
/// day one — a zero launch fee and a 50/50 split — so the combination we are
/// moving to has never run anywhere outside this file.
contract FeeRolloutTest is CateFamilyTestBase {
    /// Exactly what the script will set on mainnet.
    uint256 internal constant NEW_LAUNCH_FEE = 0.005 ether;
    uint16 internal constant NEW_PROTOCOL_BPS = 2000;

    /// Mirrors SetFees.s.sol (schedule on both) followed, two days later, by
    /// ApplyConfig.s.sol (apply on both).
    function _applyRollout() internal {
        vm.startPrank(owner);
        factory.scheduleConfig(treasury, NEW_LAUNCH_FEE, NEW_PROTOCOL_BPS);
        multiPairFactory.scheduleConfig(treasury, NEW_LAUNCH_FEE, NEW_PROTOCOL_BPS);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + factory.CONFIG_DELAY());
        factory.applyConfig();
        multiPairFactory.applyConfig();
    }

    /// Both values land on both factories, and both are inside the bounds the
    /// bytecode already enforces — which is why none of this needs a redeploy.
    function test_TheConfigIsAcceptedByBothFactories() public {
        _applyRollout();

        assertEq(factory.launchFeeWei(), NEW_LAUNCH_FEE);
        assertEq(factory.protocolLpFeeBps(), NEW_PROTOCOL_BPS);
        assertEq(multiPairFactory.launchFeeWei(), NEW_LAUNCH_FEE);
        assertEq(multiPairFactory.protocolLpFeeBps(), NEW_PROTOCOL_BPS);

        assertLe(NEW_LAUNCH_FEE, factory.MAX_LAUNCH_FEE(), "inside the deployed launch-fee cap");
        assertLe(NEW_PROTOCOL_BPS, factory.MAX_PROTOCOL_LP_FEE_BPS(), "inside the deployed share cap");
    }

    /// The whole journey: pay to launch, buy in natively, trade, collect, claim.
    /// Every number a creator sees on the other side of this change.
    function test_LaunchTradeAndClaimUnderTheNewFees() public {
        _applyRollout();

        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.initialBuyQuoteAmount = 2 ether;
        p.initialBuyMinTokensOut = 1;

        uint256 treasuryBefore = treasury.balance;

        vm.prank(creator);
        (address tkn, address pl, uint256[] memory ids) = factory.launch{value: NEW_LAUNCH_FEE + 2 ether}(p);

        // 1. The creation fee reached the treasury, and only the fee.
        assertEq(treasury.balance - treasuryBefore, NEW_LAUNCH_FEE, "creation fee paid");
        assertEq(address(factory).balance, 0, "factory holds no native dust");
        assertGt(IERC20(tkn).balanceOf(creator), 0, "the first buy landed");

        // 2. The launch recorded 20% for the protocol, permanently.
        (,, uint16 recorded) = locker.lockedPositions(ids[0]);
        assertEq(recorded, NEW_PROTOCOL_BPS, "the split is snapshotted at launch");

        // 3. Real trading, real fees.
        _buy(pl, tkn, WBNB, trader, 30 ether);
        _sell(pl, tkn, WBNB, trader, IERC20(tkn).balanceOf(trader) / 2);
        locker.collectAllFees(tkn);

        uint256 creatorCredit = locker.claimableFees(creator, WBNB);
        uint256 protocolCredit = locker.claimableFees(locker.PROTOCOL(), WBNB);
        uint256 total = creatorCredit + protocolCredit;
        assertGt(total, 0, "fees accrued");
        assertApproxEqAbs(creatorCredit, (total * 4) / 5, 1, "creator keeps four fifths");
        assertApproxEqAbs(protocolCredit, total / 5, 1, "protocol takes one fifth");

        // 4. Both sides can actually withdraw what they were credited.
        vm.prank(creator);
        assertEq(locker.claimFees(WBNB, creator), creatorCredit, "creator claims in full");
        vm.prank(treasury);
        assertEq(locker.claimProtocolFees(WBNB, treasury), protocolCredit, "treasury claims in full");
    }

    /// A multi-pair launch pays the same creation fee, as exact equality —
    /// there is no first buy on that factory to absorb a surplus.
    function test_MultiPairPaysTheSameCreationFee() public {
        _applyRollout();

        CateFamilyMultiPairFactory.LaunchParams memory p;
        p.name = "Multi";
        p.symbol = "MULTI";
        p.metadataURI = "";
        p.totalSupply = DEFAULT_SUPPLY;
        p.salt = bytes32(uint256(991));
        p.maxLaunchFeeWei = NEW_LAUNCH_FEE;
        p.pairs = new CateFamilyMultiPairFactory.PairConfig[](2);
        p.pairs[0] = CateFamilyMultiPairFactory.PairConfig({
            quoteToken: WBNB, fee: FEE_1PCT, initialTick: TICK_10_BNB_MCAP, supplyBps: 5000
        });
        p.pairs[1] = CateFamilyMultiPairFactory.PairConfig({
            quoteToken: USDT, fee: FEE_1PCT, initialTick: -122000, supplyBps: 5000
        });

        uint256 before = treasury.balance;
        vm.prank(creator);
        (address tkn,, uint256[] memory ids) = multiPairFactory.launch{value: NEW_LAUNCH_FEE}(p);

        assertEq(treasury.balance - before, NEW_LAUNCH_FEE, "one creation fee, not one per pool");
        (,, uint16 recorded) = multiPairFactory.locker().lockedPositions(ids[0]);
        assertEq(recorded, NEW_PROTOCOL_BPS, "the new split applies here too");
        assertTrue(tkn != address(0));
    }

    /// A creator who signed before the change is protected by their own
    /// consent value: the launch reverts rather than quietly charging more.
    /// This is why the frontend must ship before the script runs.
    function test_ACreatorWhoConsentedToNoFeeIsNotCharged() public {
        CateFamilyFactory.LaunchParams memory p = _defaultParams(WBNB, TICK_10_BNB_MCAP);
        p.maxLaunchFeeWei = 0; // what a page built before the change would send

        _applyRollout();

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(CateFamilyFactory.LaunchFeeAboveCap.selector, NEW_LAUNCH_FEE, 0));
        factory.launch(p);
    }
}
