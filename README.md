# CateFamily Contracts

Solidity contracts for the CateFamily token launchpad on BNB Smart Chain.

Two ways to launch a token, both ending in locked PancakeSwap V3 liquidity:

- **Bonding curve.** 80% of the supply sells along a curve held by the launchpad. When it
  sells out the token graduates: the raise, less the protocol cut, plus the reserved 20%
  become a PancakeSwap V3 position that is locked permanently.
- **Instant liquidity.** The whole supply opens as one or more V3 positions in a single
  transaction, priced from the first block, locked at launch.

Either way the supply itself is the liquidity, it is locked the moment it is minted, and
most of the pool's trading fees are routed back to the token's creator.

## Layout

| Path | What is in it |
|---|---|
| `src/` | The contracts |
| `test/` | Foundry tests |
| `deployments/` | Addresses of the live BNB Chain deployment |
| `lib/` | Vendored dependencies, pinned so builds reproduce exactly |

### The contracts

| Contract | Responsibility |
|---|---|
| `CateFamilyCurveLaunchpad.sol` | The bonding curve: creation, buys, sells, graduation, protocol fees, and the per-asset allow-list of quote tokens |
| `CateFamilyCurveToken.sol` | The token minted by a curve launch. Transfers unlock at graduation |
| `CateFamilyFactory.sol` | Instant-liquidity launches against a single quote asset |
| `CateFamilyMultiPairFactory.sol` | One launch opening up to five pools at once |
| `CateFamilyToken.sol` | The token minted by the factories. No owner, no mint, no pause, no transfer hooks |
| `CateFamilyLiquidityLocker.sol` | Holds the locked LP positions and splits collected fees between creator and protocol |
| `CateFamilyGraduation.sol` | Moves a sold-out curve into its PancakeSwap pool |
| `CateFamilyFeeSplitter.sol` | Splits a creator's fee share across several wallets |
| `CateFamilyDistributorFactory.sol` | Optional buyback-and-burn distribution of a creator's fees to holders |
| `CateFamilyFeeRouter.sol` | Routes the platform's cut of routed trades |
| `CateFamilyImageStore.sol` | Stores token artwork and metadata on chain as contract bytecode |

Supporting code lives in `src/interfaces/` and `src/lib/`.

## Design choices worth knowing

- **Tokens have no privileged roles.** No owner, no minter, no pauser, no blocklist, no
  transfer hooks and no transfer tax. Nobody, including the platform, can freeze a holder
  or seize a balance. This also means every router and aggregator can trade them.
- **Liquidity is locked permanently at launch.** The locker holds the positions; there is
  no withdrawal path. Only fees can be collected.
- **Fee shares are fixed per position when it is created.** Changing platform settings
  never alters the terms of a token that already launched.
- **Configuration changes are timelocked.** Fees, launch settings and the curve's quote
  allow-list are scheduled, then applied 48 hours later by anyone. Only pausing is
  immediate.
- **Graduation is permissionless.** Once a curve sells out, anyone may call `graduate`.
  If a sold-out curve is not graduated within 24 hours, sells reopen so funds are never
  stuck.
- **Metadata is on chain.** Artwork and links are written as contract bytecode and
  addressed by an `onchain://` URI, so nothing depends on external hosting.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/).

```bash
forge build
```

The test suite forks BNB Smart Chain, so it needs an RPC endpoint and runs against real
PancakeSwap contracts:

```bash
export FORK_RPC=https://bsc-dataseed.bnbchain.org
forge test
```

Public endpoints rate-limit heavy runs. If tests fail on RPC errors rather than assertions,
use a paid endpoint or reduce parallelism:

```bash
forge test -j 2
```

The invariant suite includes a liveness check that needs a long enough call sequence to
exercise fee collection. At the default depth a random run can finish without ever
collecting a fee, and the check then fails with "fees were never collected" even though
nothing is wrong. Run it deeper:

```bash
rm -rf cache/invariant/failures
FOUNDRY_INVARIANT_DEPTH=120 forge test
```

With that setting the full suite passes.

Compiler settings are pinned in `foundry.toml`: Solidity 0.8.26, optimizer with 800 runs,
via-IR, EVM version Cancun. These exact settings are required to reproduce the deployed
bytecode.

## Deployments

`deployments/56.curve.json` holds the addresses of the bonding-curve system on BNB Smart
Chain.

## Licence

MIT, except `src/lib/TickMath.sol`, which is a port of Uniswap V3 / PancakeSwap V3 TickMath
and keeps its original GPL-2.0-or-later licence. Each file carries its own SPDX identifier.
