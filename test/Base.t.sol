// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CateFamilyFactory} from "../src/CateFamilyFactory.sol";
import {CateFamilyMultiPairFactory} from "../src/CateFamilyMultiPairFactory.sol";
import {CateFamilyDistributorFactory, CateFamilyHolderDistributor} from "../src/CateFamilyDistributorFactory.sol";
import {CateFamilyLiquidityLocker} from "../src/CateFamilyLiquidityLocker.sol";
import {CateFamilyImageStore} from "../src/CateFamilyImageStore.sol";
import {TickMath} from "../src/lib/TickMath.sol";
import {
    IPancakeV3Factory,
    IPancakeV3Pool,
    IPancakeV3SwapCallback,
    INonfungiblePositionManager
} from "../src/interfaces/IPancakeV3.sol";

/// @dev Minimal router so tests can trade directly against a launch pool and
/// generate real swap fees for the locker to collect.
contract PoolSwapper is IPancakeV3SwapCallback {
    function swap(address pool, bool zeroForOne, int256 amountIn, address payer)
        external
        returns (int256 amount0, int256 amount1)
    {
        (amount0, amount1) = IPancakeV3Pool(pool).swap(
            msg.sender,
            zeroForOne,
            amountIn,
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            abi.encode(payer, IPancakeV3Pool(pool).token0(), IPancakeV3Pool(pool).token1())
        );
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        (address payer, address token0, address token1) = abi.decode(data, (address, address, address));
        if (amount0Delta > 0) IERC20(token0).transferFrom(payer, msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(token1).transferFrom(payer, msg.sender, uint256(amount1Delta));
    }
}

/// @dev Throwaway pair token, so a test can open a virgin Pancake pool at an
/// arbitrary tick without launching anything.
contract DummyERC20 is ERC20 {
    constructor() ERC20("Dummy", "DUM") {
        _mint(msg.sender, 1e27);
    }
}

abstract contract CateFamilyTestBase is Test {
    // ---- BNB Smart Chain mainnet deployments -----------------------------
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant POSITION_MANAGER = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address internal constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint24 internal constant FEE_1PCT = 10000; // tickSpacing 200 — the CateFamily default
    int24 internal constant TICK_SPACING_1PCT = 200;

    uint256 internal constant DEFAULT_SUPPLY = 1_000_000_000 ether;
    /// @dev 1.0001^-184200 ~= 1.0e-8 WBNB per token -> ~10 BNB starting market cap.
    int24 internal constant TICK_10_BNB_MCAP = -184200;
    /// @dev 1.0001^-122000 ~= 5.0e-6 USDT per token -> ~$5,000 starting market cap.
    int24 internal constant TICK_5K_USD_MCAP = -122000;

    CateFamilyFactory internal factory;
    CateFamilyMultiPairFactory internal multiPairFactory;
    CateFamilyDistributorFactory internal distributorFactory;
    CateFamilyLiquidityLocker internal locker;
    CateFamilyImageStore internal imageStore;
    PoolSwapper internal swapper;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    /// @dev The distribution bot: default keeper of every distributor registry.
    address internal keeper = makeAddr("keeper");
    address internal trader = makeAddr("trader");

    function setUp() public virtual {
        // Forks BNB Smart Chain so every launch runs against the real
        // PancakeSwap V3 deployment. Defaults to the archive endpoint in
        // foundry.toml; point FORK_RPC at a local anvil fork to run offline.
        //
        // The endpoint must serve historical state: several public BSC nodes
        // prune within a few hundred blocks, which surfaces as opaque
        // "EvmError: Revert" failures the moment a test touches an account the
        // fork has not cached yet.
        vm.createSelectFork(vm.envOr("FORK_RPC", string("http://127.0.0.1:8545")));

        factory = new CateFamilyFactory(
            IPancakeV3Factory(PANCAKE_V3_FACTORY),
            INonfungiblePositionManager(POSITION_MANAGER),
            WBNB,
            owner,
            treasury,
            0, // launch fee: free, matching the reference deployment
            5000 // protocol LP fee: 50/50 split
        );
        locker = factory.locker();

        multiPairFactory = new CateFamilyMultiPairFactory(
            IPancakeV3Factory(PANCAKE_V3_FACTORY),
            INonfungiblePositionManager(POSITION_MANAGER),
            WBNB,
            owner,
            treasury,
            0,
            5000
        );

        // Production shape: a keeper from day one. Suites that want the open
        // trigger opt in with `_openDistributions()`.
        distributorFactory = new CateFamilyDistributorFactory(factory, keeper);
        imageStore = new CateFamilyImageStore();
        swapper = new PoolSwapper();

        // Label-derived addresses can collide with contracts that already exist
        // on the forked chain (makeAddr("treasury") lands on a live BNB
        // forwarder). Clear any code so these behave as the plain EOAs the
        // tests assume.
        vm.etch(owner, "");
        vm.etch(treasury, "");
        vm.etch(creator, "");
        vm.etch(trader, "");
        vm.deal(treasury, 0);
        vm.deal(creator, 1000 ether);
        vm.deal(trader, 1000 ether);

        vm.label(WBNB, "WBNB");
        vm.label(USDT, "USDT");
        vm.label(address(factory), "CateFamilyFactory");
        vm.label(address(locker), "Locker");
    }

    // ------------------------------------------------------------- helpers

    /// @dev Configuration changes are scheduled and applied after CONFIG_DELAY
    /// (audit fix H-01). These do the whole dance so a test reads as before.
    function _configure(CateFamilyFactory f, address treasury_, uint256 fee, uint16 bps) internal {
        vm.prank(owner);
        f.scheduleConfig(treasury_, fee, bps);
        vm.warp(vm.getBlockTimestamp() + f.CONFIG_DELAY());
        f.applyConfig();
    }

    function _configure(CateFamilyMultiPairFactory f, address treasury_, uint256 fee, uint16 bps) internal {
        vm.prank(owner);
        f.scheduleConfig(treasury_, fee, bps);
        vm.warp(vm.getBlockTimestamp() + f.CONFIG_DELAY());
        f.applyConfig();
    }

    function _setLaunchFee(CateFamilyFactory f, uint256 fee) internal {
        _configure(f, f.treasury(), fee, f.protocolLpFeeBps());
    }

    function _setLaunchFee(CateFamilyMultiPairFactory f, uint256 fee) internal {
        _configure(f, f.treasury(), fee, f.protocolLpFeeBps());
    }

    function _setProtocolLpFeeBps(CateFamilyFactory f, uint16 bps) internal {
        _configure(f, f.treasury(), f.launchFeeWei(), bps);
    }

    function _setProtocolLpFeeBps(CateFamilyMultiPairFactory f, uint16 bps) internal {
        _configure(f, f.treasury(), f.launchFeeWei(), bps);
    }

    /// @dev Opens the holder-distribution trigger to everyone, as the factory
    /// owner. The production default is a keeper; tests that exercise the
    /// permissionless mode say so by calling this.
    function _openDistributions() internal {
        vm.prank(owner);
        distributorFactory.scheduleDefaultKeeper(address(1)); // CateFamilyHolderDistributor.PERMISSIONLESS
        vm.warp(vm.getBlockTimestamp() + distributorFactory.CONFIG_DELAY());
        distributorFactory.applyDefaultKeeper();
    }

    function _setTreasury(CateFamilyFactory f, address treasury_) internal {
        _configure(f, treasury_, f.launchFeeWei(), f.protocolLpFeeBps());
    }

    function _setTreasury(CateFamilyMultiPairFactory f, address treasury_) internal {
        _configure(f, treasury_, f.launchFeeWei(), f.protocolLpFeeBps());
    }

    function _defaultParams(address quoteToken, int24 initialTick)
        internal
        pure
        returns (CateFamilyFactory.LaunchParams memory p)
    {
        p.name = "CateFamily Test";
        p.symbol = "CAPTEST";
        p.metadataURI = "onchain://56/0x0000000000000000000000000000000000000001";
        p.totalSupply = DEFAULT_SUPPLY;
        p.quoteToken = quoteToken;
        p.fee = FEE_1PCT;
        p.initialTick = initialTick;
        p.positions = new CateFamilyFactory.LiquidityPosition[](0);
        p.creatorFeeRecipient = address(0);
        p.initialBuyQuoteAmount = 0;
        p.initialBuyMinTokensOut = 0;
        p.initialBuyRecipient = address(0);
        p.salt = bytes32(uint256(1));
        p.maxLaunchFeeWei = 5 ether;
    }

    /// @dev Buys `quoteAmount` worth of `token` out of its pool as `buyer`.
    function _buy(address pool, address token, address quoteToken, address buyer, uint256 quoteAmount) internal {
        deal(quoteToken, buyer, quoteAmount);
        vm.startPrank(buyer);
        IERC20(quoteToken).approve(address(swapper), type(uint256).max);
        bool zeroForOne = quoteToken < token; // selling quote for token
        swapper.swap(pool, zeroForOne, int256(quoteAmount), buyer);
        vm.stopPrank();
    }

    /// @dev Sells `tokenAmount` of `token` back into its pool as `seller`.
    function _sell(address pool, address token, address quoteToken, address seller, uint256 tokenAmount) internal {
        vm.startPrank(seller);
        IERC20(token).approve(address(swapper), type(uint256).max);
        bool zeroForOne = token < quoteToken; // selling token for quote
        swapper.swap(pool, zeroForOne, int256(tokenAmount), seller);
        vm.stopPrank();
    }
}
