// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CateFamilyTestBase} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CateFamilyMultiPairFactory} from "../src/CateFamilyMultiPairFactory.sol";
import {CateFamilyLiquidityLocker} from "../src/CateFamilyLiquidityLocker.sol";
import {IPancakeV3Pool, INonfungiblePositionManager} from "../src/interfaces/IPancakeV3.sol";

contract MultiPairTest is CateFamilyTestBase {
    CateFamilyLiquidityLocker internal mpLocker;

    function setUp() public override {
        super.setUp();
        mpLocker = multiPairFactory.locker();
    }

    /// @dev A full five-pool "bStock" spread: BNB, two stablecoins and two
    /// other BSC assets. Ticks only need to be valid and aligned here.
    function _fivePairs() internal pure returns (CateFamilyMultiPairFactory.PairConfig[] memory pairs) {
        pairs = new CateFamilyMultiPairFactory.PairConfig[](5);
        pairs[0] = CateFamilyMultiPairFactory.PairConfig(WBNB, FEE_1PCT, -184200, 4000);
        pairs[1] = CateFamilyMultiPairFactory.PairConfig(USDT, FEE_1PCT, -122000, 2000);
        pairs[2] = CateFamilyMultiPairFactory.PairConfig(USDC, FEE_1PCT, -122000, 2000);
        pairs[3] = CateFamilyMultiPairFactory.PairConfig(CAKE, FEE_1PCT, -131200, 1000);
        pairs[4] = CateFamilyMultiPairFactory.PairConfig(BTCB, FEE_1PCT, -237200, 1000);
    }

    function _params(CateFamilyMultiPairFactory.PairConfig[] memory pairs)
        internal
        pure
        returns (CateFamilyMultiPairFactory.LaunchParams memory p)
    {
        p.name = "CateFamily bStock";
        p.symbol = "CAPBS";
        p.metadataURI = "onchain://56/0x0000000000000000000000000000000000000002";
        p.totalSupply = DEFAULT_SUPPLY;
        p.pairs = pairs;
        p.creatorFeeRecipient = address(0);
        p.salt = bytes32(uint256(7));
        p.maxLaunchFeeWei = 5 ether;
    }

    function test_LaunchAcrossFivePools() public {
        CateFamilyMultiPairFactory.LaunchParams memory p = _params(_fivePairs());

        address predicted =
            multiPairFactory.predictTokenAddress(creator, p.salt, p.name, p.symbol, p.totalSupply, p.metadataURI);

        vm.prank(creator);
        (address token, address[] memory pools, uint256[] memory ids) = multiPairFactory.launch(p);

        assertEq(token, predicted, "CREATE2 prediction must match");
        assertEq(pools.length, 5, "five pools");
        assertEq(ids.length, 5, "five locked positions");
        assertEq(multiPairFactory.poolsOf(token).length, 5);

        (,, uint8 pairCount,) = multiPairFactory.launches(token);
        assertEq(pairCount, 5);

        // Every pool is distinct, holds its slice, and its LP NFT is locked.
        uint16[5] memory bps = [uint16(4000), 2000, 2000, 1000, 1000];
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = 0; j < i; j++) {
                assertTrue(pools[i] != pools[j], "pools must be distinct");
            }
            assertEq(INonfungiblePositionManager(POSITION_MANAGER).ownerOf(ids[i]), address(mpLocker));
            uint256 expected = (DEFAULT_SUPPLY * bps[i]) / 10_000;
            assertApproxEqRel(IERC20(token).balanceOf(pools[i]), expected, 0.001e18, "each pool holds its supply slice");
        }

        assertEq(IERC20(token).balanceOf(address(multiPairFactory)), 0, "factory retains nothing");
    }

    function test_FeesFromEveryPairPoolIntoOneClaimableBalance() public {
        // Two pools sharing WBNB as quote: fees must accumulate into a single
        // claimable WBNB balance for the creator.
        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](2);
        pairs[0] = CateFamilyMultiPairFactory.PairConfig(WBNB, FEE_1PCT, -184200, 5000);
        pairs[1] = CateFamilyMultiPairFactory.PairConfig(WBNB, 2500, -184200, 5000); // same quote, different tier

        vm.prank(creator);
        (address token, address[] memory pools,) = multiPairFactory.launch(_params(pairs));

        _buy(pools[0], token, WBNB, trader, 5 ether);
        _buy(pools[1], token, WBNB, trader, 5 ether);

        mpLocker.collectAllFees(token);

        uint256 credit = mpLocker.claimableFees(creator, WBNB);
        assertGt(credit, 0, "creator accrues fees from both pools in one balance");
        assertApproxEqAbs(credit, mpLocker.claimableFees(mpLocker.PROTOCOL(), WBNB), 2, "50/50 split holds per pool");

        vm.prank(creator);
        uint256 claimed = mpLocker.claimFees(WBNB, creator);
        assertEq(claimed, credit, "one claim sweeps fees from every pair");
    }

    function test_RevertsAboveFivePairs() public {
        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](6);
        pairs[0] = CateFamilyMultiPairFactory.PairConfig(WBNB, FEE_1PCT, -184200, 2000);
        pairs[1] = CateFamilyMultiPairFactory.PairConfig(USDT, FEE_1PCT, -122000, 2000);
        pairs[2] = CateFamilyMultiPairFactory.PairConfig(USDC, FEE_1PCT, -122000, 2000);
        pairs[3] = CateFamilyMultiPairFactory.PairConfig(CAKE, FEE_1PCT, -131200, 2000);
        pairs[4] = CateFamilyMultiPairFactory.PairConfig(BTCB, FEE_1PCT, -237200, 1000);
        pairs[5] = CateFamilyMultiPairFactory.PairConfig(WBNB, 2500, -184200, 1000);

        vm.prank(creator);
        vm.expectRevert(CateFamilyMultiPairFactory.InvalidPairCount.selector);
        multiPairFactory.launch(_params(pairs));
    }

    function test_RevertsOnZeroPairs() public {
        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](0);
        vm.prank(creator);
        vm.expectRevert(CateFamilyMultiPairFactory.InvalidPairCount.selector);
        multiPairFactory.launch(_params(pairs));
    }

    /// @dev Two pairs with the same quote AND fee tier resolve to one Pancake
    /// pool; the second would mint into a price it never agreed to.
    function test_RevertsOnDuplicateQuoteAndFeeTier() public {
        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](2);
        pairs[0] = CateFamilyMultiPairFactory.PairConfig(USDT, FEE_1PCT, -122000, 5000);
        pairs[1] = CateFamilyMultiPairFactory.PairConfig(USDT, FEE_1PCT, -130000, 5000);

        vm.prank(creator);
        vm.expectRevert(CateFamilyMultiPairFactory.DuplicatePair.selector);
        multiPairFactory.launch(_params(pairs));
    }

    function test_RevertsWhenSupplyBpsDoNotSumTo100Pct() public {
        CateFamilyMultiPairFactory.PairConfig[] memory pairs = new CateFamilyMultiPairFactory.PairConfig[](2);
        pairs[0] = CateFamilyMultiPairFactory.PairConfig(WBNB, FEE_1PCT, -184200, 5000);
        pairs[1] = CateFamilyMultiPairFactory.PairConfig(USDT, FEE_1PCT, -122000, 4000);

        vm.prank(creator);
        vm.expectRevert(CateFamilyMultiPairFactory.InvalidBps.selector);
        multiPairFactory.launch(_params(pairs));
    }

    function test_RevertsWhenNativeValueSentWithoutFee() public {
        vm.prank(creator);
        vm.expectRevert(CateFamilyMultiPairFactory.IncorrectNativeValue.selector);
        multiPairFactory.launch{value: 1 ether}(_params(_fivePairs()));
    }

    function test_MultiPairLaunchFeeReachesTreasury() public {
                _setLaunchFee(multiPairFactory, 0.1 ether);

        uint256 before = treasury.balance;
        vm.prank(creator);
        multiPairFactory.launch{value: 0.1 ether}(_params(_fivePairs()));
        assertEq(treasury.balance - before, 0.1 ether);
    }

    /// The multi-pair factory takes the fee as EXACT equality rather than the
    /// single-pair factory's "at least", because there is no first buy here to
    /// absorb a surplus. Overpaying by a wei is refused, not pocketed — there
    /// is no `receive()` on this contract and no sweep function anywhere, so a
    /// surplus it accepted would be stranded forever.
    function test_MultiPairFeeIsExactInBothDirections() public {
        uint256 fee = 0.005 ether;
                _setLaunchFee(multiPairFactory, fee);

        vm.prank(creator);
        vm.expectRevert(CateFamilyMultiPairFactory.IncorrectNativeValue.selector);
        multiPairFactory.launch{value: fee + 1}(_params(_fivePairs()));

        vm.prank(creator);
        vm.expectRevert(CateFamilyMultiPairFactory.IncorrectNativeValue.selector);
        multiPairFactory.launch{value: fee - 1}(_params(_fivePairs()));

        uint256 before = treasury.balance;
        vm.prank(creator);
        multiPairFactory.launch{value: fee}(_params(_fivePairs()));
        assertEq(treasury.balance - before, fee, "exactly the fee, nothing else");
        assertEq(address(multiPairFactory).balance, 0, "the factory holds no BNB");
    }

    /// Each factory keeps its own config, so setting one leaves the other at
    /// its old value. Worth pinning: rolling out a fee change means TWO
    /// transactions, and forgetting the second is silent.
    function test_TheTwoFactoriesHoldIndependentFeeConfig() public {
        _configure(factory, treasury, 0.005 ether, 2000);

        assertEq(multiPairFactory.launchFeeWei(), 0, "multi-pair still free");
        assertEq(multiPairFactory.protocolLpFeeBps(), 5000, "multi-pair still 50/50");

        _configure(multiPairFactory, treasury, 0.005 ether, 2000);

        assertEq(multiPairFactory.launchFeeWei(), 0.005 ether);
        assertEq(multiPairFactory.protocolLpFeeBps(), 2000);
    }

    function test_MultiPairPauseStopsLaunches() public {
        vm.prank(owner);
        multiPairFactory.setPaused(true);
        vm.prank(creator);
        vm.expectRevert(CateFamilyMultiPairFactory.LaunchesPaused.selector);
        multiPairFactory.launch(_params(_fivePairs()));
    }
}
