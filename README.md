# LP Vaults

ERC-4626 vault strategies for Avalanche liquidity.

The v1 launch focus is now Pharaoh concentrated liquidity:

- Pharaoh USDt/USDC, with USDC as the ERC-4626 asset.
- Pharaoh sAVAX/WAVAX, with WAVAX as the ERC-4626 asset.

Blackhole, LFJ, WBTC/BTC.b, and USDC/AUSD are out of scope for this first lending-market rollout. The older LFJ and Blackhole code remains in the repository as legacy code, but `DeployPharaoh.s.sol` does not deploy either integration.

`PharaohLiquidityVault` is deployed behind an OpenZeppelin `TransparentUpgradeableProxy`. Lending markets and users must use the proxy address, not the implementation. The multisig owns each generated `ProxyAdmin`. New proxies initialize paused.

## Pharaoh Mainnet Configuration

- Avalanche C-Chain RPC: `https://api.avax.network/ext/bc/C/rpc`
- Owner Safe: `0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12`
- Keeper: `0x94696d767e65a75581145646960FA0eC886cE5d2`
- Reviewed v2 implementation: `0x87C2C3bE37B2D71Ca85D2D950F0eed4532410CEa`
- Legacy implementation: `0x3E931977EE59B23bD42F6b82b7Dc16128942A5a5`
- USDC vault proxy: `0x855bF832f26a294d28500db59eE941dE3d654129`
- USDC vault ProxyAdmin: `0x2DD4191B2944396B5853f4219E829f01636F65cf`
- USDC ratio oracle: `0xe6060635dfdDd495ca22b828e144AB8411c8a431`
- WAVAX vault proxy: `0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8`
- WAVAX vault ProxyAdmin: `0x34CbBdfcBcc72e8bf70CbF6c7245fdb2725b94dC`
- sAVAX rate oracle: `0x2002aFd6C713a6075d66DaE758Dc466787faCeEF`
- Pharaoh factory: `0xAE6E5c62328ade73ceefD42228528b70c8157D0d`
- Pharaoh position manager: `0x0B4478e810D48B5882D4019D435A2f864Bab4F39`
- Pharaoh swap router: `0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c`
- PHAR: `0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7`
- xPHAR: `0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A`
- USDt: `0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7`
- USDC: `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`
- USDt/USDC pool: `0x9bFE3108Cc16D17a9Ec65545a0f50B2CA1C970c0`
- sAVAX: `0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE`
- WAVAX: `0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7`
- sAVAX/WAVAX pool: `0x65B9016c376604Fe0aF38c1E336Ffcec0F8ecBbD`
- Chainlink USDC/USD: `0xF096872672F44d6EBA71458D74fe67F9a77a23B9`
- Chainlink USDT/USD: `0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a`
- Chainlink AVAX/USD: `0x0A77230d17318075983913bC2145DB16C7366156`

Both assets are `token1` in their selected pool. The USDC vault uses the ratio of the two Chainlink USD feeds. The WAVAX vault values sAVAX through BENQI's protocol exchange rate.

Both proxies were atomically upgraded to the reviewed v2 implementation in Avalanche transaction `0xff6646778497fcf21b817d956c7eda9c0800fa836a978dc388e7184df2ae65b1` at block `92556750`. The Safe batch called each `ProxyAdmin.upgradeAndCall` with `initializeV2RiskParameters(oracleDeviationBps, slippageBps, haircutBps)` as calldata. The resulting risk settings are:

- USDC/USDt: 30-tick spot/TWAP bound, 30-bps oracle bound, 100-bps swap tolerance, and 100-bps paired-value haircut.
- sAVAX/WAVAX: 100-tick spot/TWAP bound, 100-bps oracle bound, 300-bps swap tolerance, and 300-bps paired-value haircut.

The implementation rejects configurations whose swap tolerance does not cover the oracle bound, a conservative conversion of the tick bound, and an execution buffer; the valuation haircut must also cover the full swap tolerance. The upgrade receipt contains both proxy `Upgraded` events and the Safe `ExecutionSuccess` event. Post-upgrade canaries were executed successfully:

- 10 USDC: Safe transaction `0x1266f9fd0811ded7ef7ca5478c67ecea4d15b1e98b9d72ed3f48e4d95bbd9ebc`.
- 1 WAVAX: Safe transaction `0xd1c73fcfab833db41dc1f904ec488eb472badad96310eb6b286cc8885c77c6f6`.

Both vaults are active and in range, all outstanding shares are owned by the Safe, asset allowances are zero, and each final deposit cap is one raw unit so public deposits remain closed. Continue the time-series canary monitoring before listing the shares in a lending market.

### Partial-exit hotfix (live)

Post-canary fork testing found that the previous `0x87C2...10CEa` implementation's partial asset-only redemption called Pharaoh's deployed `exactOutputSingle` route. The verified upstream router packs that route in the wrong field order, derives a non-contract pool address, and reverts. A sole holder's full redemption still worked because it used the separate `exactInputSingle` path, but the staged-tranche round trip and any multi-holder or lending-market use require partial exits.

The live hotfix removes the exact-output dependency. It uses an oracle-derived, slippage-capped exact-input amount and requires the router to deliver the complete asset shortfall; otherwise the entire redemption reverts without burning shares. At pinned pre-upgrade block `92626200`, the fork suite upgraded both live proxies locally without changing storage, then passed the 10-USDC/1-WAVAX partial canaries and the originally proposed 100-USDC/5-WAVAX deposit-and-partial-redemption sequences. The runtime is 24,153 bytes, 423 bytes below EIP-170.

The reviewed implementation was deployed and Sourcify-verified at `0x37E28a2C9FA3bBdab81efA69D5D480f5107a3770` in Avalanche transaction `0xc001b1d8a79a9fe47016b61e6011f07bb2d2fd4a41f101b6bd8452618defc43c`, block `92630151`. Its runtime codehash is `0x416f2a818693b20948fc44e9955ec7a370be051599b1eef6ca1fad932f3626ef`. Almanax and Ozone/Cecuro both completed with zero actionable findings. The Safe atomically upgraded both proxies in transaction `0xb07fd420d0b94a278b84fa16b3a54914dd4714360ab63c7fdb50bf6411a555c3`, block `92634831`. Both vaults remained active with their positions, shares, risk parameters, and one-raw-unit deposit caps unchanged.

The guarded deployment simulation used was:

```bash
make deploy-pharaoh-hotfix-dry-run \
  AVAX_RPC=https://api.avax.network/ext/bc/C/rpc \
  DEPLOYER=0x94696d767e65a75581145646960FA0eC886cE5d2
```

The implementation was deployed with the encrypted keystore using:

```bash
make deploy-pharaoh-hotfix-mainnet \
  AVAX_RPC=https://api.avax.network/ext/bc/C/rpc \
  DEPLOYER=0x94696d767e65a75581145646960FA0eC886cE5d2 \
  SIGNER_ARGS='--account robinhood-deployer --verifier sourcify'

make prepare-pharaoh-hotfix \
  AVAX_RPC=https://api.avax.network/ext/bc/C/rpc \
  NEW_IMPLEMENTATION=0x37E28a2C9FA3bBdab81efA69D5D480f5107a3770
```

The implementation deployment itself changed no proxy state. The Safe subsequently executed the two `ProxyAdmin.upgradeAndCall(proxy, implementation, 0x)` calls atomically with native value zero. `safe/Pharaoh-partial-exit-hotfix-43114.json` is now a retained historical artifact and must not be re-executed. The post-upgrade fork passed 8/8 at block `92634917` and the PnL check remained healthy before the staged files were marked ready.

The guarded single-use commands used for the implementation deployment were:

```bash
make deploy-pharaoh-upgrade-dry-run \
  AVAX_RPC=https://api.avax.network/ext/bc/C/rpc \
  DEPLOYER=0x94696d767e65a75581145646960FA0eC886cE5d2

make deploy-pharaoh-upgrade-mainnet \
  AVAX_RPC=https://api.avax.network/ext/bc/C/rpc \
  DEPLOYER=0x94696d767e65a75581145646960FA0eC886cE5d2 \
  SIGNER_ARGS='--account robinhood-deployer --verifier sourcify'
```

The target deployed no proxies and changed no vault state. Before the Safe transaction, the payloads were reproduced and validated from the deployed bytecode with:

```bash
make prepare-pharaoh-upgrade \
  AVAX_RPC=https://api.avax.network/ext/bc/C/rpc \
  NEW_IMPLEMENTATION=0x87C2C3bE37B2D71Ca85D2D950F0eed4532410CEa
```

The executed, checksummed Safe Transaction Builder file is retained at `safe/Pharaoh-v2-upgrade-43114.json`. The deployment and preparation targets now intentionally reject reuse because their pre-upgrade guard requires both proxies to reference the legacy implementation. Never call either proxy directly and never separate an implementation upgrade from its migration initializer.

## Lending-Market Accounting

`totalAssets()` values:

- Idle ERC-4626 assets at face value.
- Idle paired tokens through the independent oracle.
- NFT position principal at the 30-minute Pharaoh TWAP, then through the independent oracle.
- A configurable haircut on all paired-token value.

Uncollected fees and non-pair incentive tokens are excluded. Entry and exit operations collect fees before calculating shares, preventing a depositor from capturing previously accrued fees. Deposits, swaps, liquidity changes, and redemptions fail closed when spot diverges too far from TWAP or TWAP diverges from the independent oracle.

Asset-denominated `deposit()` is the supported entry point. Exact-share `mint()` is intentionally disabled (`maxMint() == 0`) because the net contribution is only known after swap and LP execution.

Pharaoh's position manager can transfer PHAR and xPHAR to the vault automatically when liquidity changes. These and any other unpriced tokens held by the vault are excluded from `totalAssets()`. The v2 implementation deliberately omits reward forwarding and xPHAR conversion to preserve a small, reviewable core below EIP-170; harvest those balances before upgrading if the original implementation has accrued them. A dedicated, reviewed reward-conversion module is required before incentives are included in PnL or public-launch assumptions.

For collateral valuation, lending markets should use the vault proxy's standard ERC-4626 `convertToAssets()` path and preserve their own collateral-factor and liquidation haircuts. `totalAssets()` enforces the spot/TWAP/independent-oracle bounds. Oracle staleness, unsafe price divergence, or insufficient Pharaoh observation history intentionally makes valuation revert rather than silently use spot. The lending integration must treat that revert as an oracle outage and have a tested market-pause/guardian procedure; fail-closed valuation trades availability for manipulation resistance.

`PeridotPharaohShareOracle` is the prepared Peridot adapter. It delegates every unregistered market to Peridot's existing oracle and dynamically prices only registered Pharaoh vault shares from conservative `convertToAssets()` accounting plus the asset's Chainlink USD feed. It returns zero for a registered vault when the vault price check or Chainlink read is unsafe. Crucially, it uses Compound/Peridot's `10^(36-underlyingDecimals)` oracle scaling: a six-decimal USDC vault share is priced around `1e30`, while an 18-decimal WAVAX vault share is priced around the AVAX/USD value at `1e18` scale. Do not replace the live Peridot oracle or list a market until the actual Avalanche Peridottroller, base oracle, rate model, admin, and guardian addresses have been independently verified on-chain.

`emergencyExit()` removes the NFT liquidity but deliberately does not bypass the price checks in the standard asset-only `redeem()` or convert the paired token. If Pharaoh lacks enough external liquidity, or a pool/TWAP/oracle check fails, holders can instead call `redeemInKind()` to burn shares for proportional WAVAX/USDC and sAVAX/USDt balances without a swap or price-feed dependency. Integrations must explicitly support that two-token emergency payout; it is a liveness escape hatch, not ERC-4626's asset-only redemption path.

## Common Commands

Build:

```bash
make build
```

Run the Pharaoh unit tests:

```bash
make test-pharaoh
```

Run the live Pharaoh fork suite:

```bash
make test-pharaoh-fork AVAX_RPC=https://your-avalanche-rpc
```

Grow both Pharaoh observation buffers to 64 slots (two Avalanche mainnet transactions):

```bash
make grow-pharaoh-observations \
  AVAX_RPC=https://your-avalanche-rpc \
  SIGNER_ARGS='--account your-foundry-keystore'
```

`SIGNER_ARGS` can instead contain your normal `cast send` hardware-wallet options. Never put a literal private key in shell history. After at least 30 minutes, verify both pools:

```bash
make check-pharaoh-observations AVAX_RPC=https://your-avalanche-rpc
```

Dry-run both Pharaoh vault deployments:

```bash
make deploy-pharaoh-dry-run \
  AVAX_RPC=https://your-avalanche-rpc \
  DEPLOYER=0xYourDeployer \
  MULTISIG=0xYourMultisig \
  KEEPER=0xYourKeeper
```

Broadcast with an encrypted Foundry keystore after the exact dry run has passed:

```bash
make deploy-pharaoh-mainnet \
  AVAX_RPC=https://your-avalanche-rpc \
  DEPLOYER=0xYourDeployer \
  MULTISIG=0xYourMultisig \
  KEEPER=0xYourKeeper \
  USDC_DEPOSIT_CAP=100000000000 \
  WAVAX_DEPOSIT_CAP=15000000000000000000000 \
  SIGNER_ARGS='--account your-foundry-keystore'
```

The example caps encode 100,000 USDC and 15,000 WAVAX; they are not a recommendation for current pool depth. `SIGNER_ARGS` keeps a raw private key out of shell history.

The default launch caps are 250,000 USDC and 500 WAVAX. Override `USDC_DEPOSIT_CAP` and `WAVAX_DEPOSIT_CAP` with raw token units.

Monitor both deployed vaults without changing chain state:

```bash
make pharaoh-status AVAX_RPC=https://api.avax.network/ext/bc/C/rpc
```

Append the same data to ignored CSV files under `data/`:

```bash
make pharaoh-pnl-snapshot AVAX_RPC=https://api.avax.network/ext/bc/C/rpc
```

The monitor reports conservative ERC-4626 accounting and also simulates redeeming all Safe-owned shares with `eth_call`. The latter includes currently claimable LP fees and the executable paired-token swap without burning shares or moving funds. Its default cost bases are the planned 10-USDC and 1-WAVAX canaries. Override `USDC_COST_BASIS_RAW` or `WAVAX_COST_BASIS_RAW` after any additional capital flow or share transfer. Reported PnL excludes Safe/keeper gas and unpriced PHAR/xPHAR rewards.

For the initial canary, do not leave the deployed 100,000-USDC and 15,000-WAVAX caps publicly available. In one atomic Safe batch per vault: approve exactly the seed amount, unpause, deposit to the Safe, then call `setDepositCap(1)`. A cap of one raw unit is below the resulting managed value, so further deposits remain closed while the vault stays unpaused and the keeper can rebalance. Raise the cap only after pool-depth testing and multisig hardening.

### Safe Transaction Builder canaries

Use [Safe Transaction Builder](https://help.safe.global/articles/4180673514-transaction-builder) on Avalanche. Every call has native `value = 0`. Keep the order shown and execute each four-call set as one batch.

USDC batch:

| Order | Target | Function | Arguments |
| --- | --- | --- | --- |
| 1 | USDC `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` | `approve(address,uint256)` | vault `0x855bF832f26a294d28500db59eE941dE3d654129`, `10000000` |
| 2 | USDC vault `0x855bF832f26a294d28500db59eE941dE3d654129` | `unpause()` | none |
| 3 | USDC vault `0x855bF832f26a294d28500db59eE941dE3d654129` | `deposit(uint256,address)` | `10000000`, Safe `0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12` |
| 4 | USDC vault `0x855bF832f26a294d28500db59eE941dE3d654129` | `setDepositCap(uint256)` | `1` |

WAVAX batch:

| Order | Target | Function | Arguments |
| --- | --- | --- | --- |
| 1 | WAVAX `0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7` | `approve(address,uint256)` | vault `0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8`, `1000000000000000000` |
| 2 | WAVAX vault `0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8` | `unpause()` | none |
| 3 | WAVAX vault `0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8` | `deposit(uint256,address)` | `1000000000000000000`, Safe `0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12` |
| 4 | WAVAX vault `0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8` | `setDepositCap(uint256)` | `1` |

Do not execute if Safe shows a different full target address, decoded function, receiver, amount, network, or nonzero native value. After each batch, run `make pharaoh-status` and confirm the Safe owns all shares, `tokenId` is nonzero, `paused` is false, `depositCap` is `1`, and the position is in range.

### Proposed staged deposits

**Post-upgrade gate passed; Safe funding remains required.** The fresh fork at block `92637472` passed 13/13 live-state, partial-exit, staged-round-trip, live-pool swap, storage, risk-migration, and lending-oracle tests. Read-only live calls also successfully simulated partial redemptions from both upgraded proxies. The smaller next controlled step is 20 USDC and 0.75 WAVAX. These are capital additions, not public cap increases. Each checksummed Transaction Builder file uses four calls in one atomic Safe transaction:

1. Approve exactly the staged asset amount.
2. Temporarily set the cap to zero (the vault's unlimited sentinel) inside the atomic batch so ordinary fee accrual cannot consume fixed headroom.
3. Deposit the staged amount with the Safe as receiver.
4. Restore the cap to one raw unit.

The zero-cap sentinel is safe only as part of this exact atomic Safe batch: no
external transaction can interleave, and failure of the deposit or final cap
restore reverts every call, including the temporary unlimited setting. Never
submit these four calls as separate Safe transactions.

The prepared post-upgrade files are `safe/Pharaoh-USDC-stage-20-43114.json` and `safe/Pharaoh-WAVAX-stage-0.75-43114.json`. Validate all retained Safe files with:

```bash
make check-pharaoh-safe-batches
```

The guarded funding script swaps exactly 5 deployer USDC to WAVAX through the active direct Pharaoh pool. It requires at least 0.75 WAVAX and at least 97% of the fresh Chainlink-derived fair output, then transfers exactly 20 USDC and 0.75 WAVAX to the Safe. It refuses to run unless both Safe asset balances and relevant allowances are zero, the vault supplies still equal the exact pre-stage canary supplies with every share owned by the Safe, both vaults are live on the expected hotfix with one-raw-unit caps, and the expected pool/router/feed configuration is healthy. The supply pins make the script permanently non-replayable after either staged deposit. Dry-run it first, then broadcast with the encrypted keystore:

```bash
make fund-pharaoh-small-stage-dry-run \
  AVAX_RPC=https://api.avax.network/ext/bc/C/rpc \
  DEPLOYER=0x94696d767e65a75581145646960FA0eC886cE5d2

make fund-pharaoh-small-stage-mainnet \
  AVAX_RPC=https://api.avax.network/ext/bc/C/rpc \
  DEPLOYER=0x94696d767e65a75581145646960FA0eC886cE5d2 \
  SIGNER_ARGS='--account robinhood-deployer'
```

Do not execute either Safe batch until the funding transactions are confirmed and the Safe shows exactly 20 USDC and 0.75 WAVAX. Execute USDC and WAVAX as separate Safe batches, then immediately run the status and snapshot commands. After both execute, use total cost bases of 30 USDC and 1.75 WAVAX:

```bash
USDC_COST_BASIS_RAW=30000000 \
WAVAX_COST_BASIS_RAW=1750000000000000000 \
make pharaoh-pnl-snapshot \
  AVAX_RPC=https://api.avax.network/ext/bc/C/rpc
```

The finalized-block fork suite reproduces each exact approve/cap/deposit/close sequence and a partial redemption. Do not execute a batch if the live position is out of range, a fresh snapshot cannot simulate redemption, the Safe balance is insufficient, or either fork test fails at a newly pinned finalized block.

## Pharaoh Launch Checklist

Before listing either proxy in a lending market:

- Run the full unit suite and current-state mainnet fork suite.
- Build with the pinned Foundry settings and confirm `PharaohLiquidityVault` remains below the 24,576-byte EIP-170 runtime limit. The partial-exit candidate is 24,153 bytes, leaving 423 bytes of margin.
- Run an external smart-contract audit; this repository is not an audit.
- Confirm the multisig owns the vault and generated `ProxyAdmin`.
- If the owner is described as a multisig, confirm it has multiple owners and a threshold greater than one before assigning production ownership.
- Confirm the keeper is a dedicated operations address.
- Confirm `asset()`, `pairedToken()`, `pool()`, oracle, and cap on each proxy.
- The deployment sets each pool's `observationCardinalityNext` from its original one-slot configuration to 64.
- Confirm `observationCardinalityNext == 64`, then wait for a subsequent pool swap/write to activate the expanded ring and confirm `observationCardinality == 64`. A successful `observe([1800, 0])` while cardinality is still 1 does not prove the expanded ring is active.
- Wait at least 30 minutes after buffer activation and verify `observe([1800, 0])` succeeds on both pools.
- Use a multisig batch to approve the asset, unpause, make a multisig-owned seed deposit, and reduce the cap below managed assets atomically.
- Fund the multisig with the seed USDC/WAVAX first. Safe web users can build the atomic calls with Transaction Builder; verify every target, value, and calldata before signing.
- Keep public deposits closed during the 10-USDC/1-WAVAX canary; the deployed caps are not justified by current pool depth.
- Define and test the multisig process for exiting automatically claimed xPHAR, converting PHAR and other incentives, and donating the proceeds back to the vault.
- Test the lending market's oracle-outage and liquidation-pause behavior when `convertToAssets()` intentionally reverts.
- Add the proxy, never the implementation, as the lending-market underlying/collateral asset.

## Legacy LFJ Mainnet Addresses

- LFJ V2.2 router: `0x18556DA13313f3532c54711497A8FedAC273220E`
- AUSD: `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a`
- USDC: `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`
- LFJ AUSD/USDC pair: `0x8573F98175D816d520248B5fACF40D309B1c9ceE`
- Pair order: `tokenX = AUSD`, `tokenY = USDC`

LFJ remains out of scope for the current launch. The retained v2 implementation now requires an independent `IStableVaultOracle` and a conservative paired-token valuation haircut. Router spot quotes are used only for execution and must satisfy the oracle floor. Unsolicited AUSD transfers are excluded from NAV and the deposit cap; governance can either accept them with `acceptPairedDonation()` or recover only the unaccounted excess with `sweepUnaccountedPaired()`.

Do not deploy LFJ until a production AUSD/USDC oracle has been independently verified and its haircut has been calibrated against post-liquidity-removal price impact. `LFJ_PRICE_ORACLE` must report `asset() == USDC` and `pairedToken() == AUSD`.

The public Avalanche RPC can sometimes leave Foundry waiting after tests print `[PASS]`. Pinning the fork block usually makes runs more repeatable:

```bash
make test-lfj-fork-pinned
```

Equivalent raw command:

```bash
BLOCK=$(cast block-number --rpc-url https://api.avax.network/ext/bc/C/rpc)

forge test \
  --fork-url https://api.avax.network/ext/bc/C/rpc \
  --fork-block-number "$BLOCK" \
  --match-contract LFJStableVaultMainnetForkTest \
  -vvv
```

Dry-run the LFJ mainnet deployment against Avalanche RPC:

```bash
make deploy-lfj-proxy-dry-run \
  DEPLOYER=0xYourDeployer \
  MULTISIG=0xYourMultisig \
  KEEPER=0xYourKeeper \
  LFJ_PRICE_ORACLE=0xYourVerifiedOracle
```

Broadcast the LFJ mainnet deployment:

```bash
make deploy-lfj-proxy-mainnet \
  DEPLOYER=0xYourDeployer \
  MULTISIG=0xYourMultisig \
  KEEPER=0xYourKeeper \
  LFJ_PRICE_ORACLE=0xYourVerifiedOracle \
  SIGNER_ARGS='--account your-foundry-keystore'
```

## LFJ Deployment Checklist

Before broadcasting:

- Confirm `DeployMainnet` uses the live AUSD/USDC pair and exact LFJ pair ordering.
- Confirm `MULTISIG` is the intended vault owner and `ProxyAdmin` owner.
- Confirm `KEEPER` is the intended rebalance operator.
- Confirm the oracle is independent of LFJ spot, fresh, and bound to USDC/AUSD.
- Confirm launch settings:
  - Deposit cap: `500_000e6`
  - Bin range: `2`
  - Slippage: `30` bps
  - Valuation haircut: `200` bps, or a more conservative tested value
- Run `make build`.
- Run `make test-lfj-fork-pinned`.
- Run `make deploy-lfj-proxy-dry-run DEPLOYER=... MULTISIG=... KEEPER=... LFJ_PRICE_ORACLE=...`.

After deployment:

- Run `make check-lfj` (or `./scripts/post-deploy-check.sh`).
- Save and publish the proxy, implementation, and ProxyAdmin addresses.
- Verify the implementation and proxy on SnowTrace/SnowScan.
- Confirm proxy `asset() == USDC`.
- Confirm proxy `tokenX() == AUSD` and `tokenY() == USDC`.
- Confirm proxy `BIN_STEP() == 1`.
- Confirm proxy `priceOracle()` is the reviewed oracle and `valuationHaircutBps()` is expected.
- Confirm proxy `owner() == MULTISIG`.
- Confirm proxy `rebalancer() == KEEPER`.
- Start with the conservative deposit cap and raise only after live monitoring.

## Post-Deploy Verification

```bash
make check-lfj
```

Or with overrides:

```bash
PROXY=0x81C0533c8132Bc20c3A53f599925AB01c7dA2B3A \
OWNER=0xCED23360932B80d18fdEAEAa573202E80A584804 \
KEEPER=0xYourKeeper \
./scripts/post-deploy-check.sh
```

## APY Tracking

The vault has **no on-chain `apy()` function**. Yield comes from LFJ swap fees accumulating in the LP position. That shows up as a rising share price: `convertToAssets(1 share)` increases over time.

Take a snapshot now, then again after 24h+:

```bash
make apy-snapshot
# later...
make apy-snapshot
make apy-compare
```

Manual `cast` check for current share price:

```bash
PROXY=0x81C0533c8132Bc20c3A53f599925AB01c7dA2B3A
RPC=https://api.avax.network/ext/bc/C/rpc

cast call $PROXY "totalAssets()(uint256)" --rpc-url $RPC
cast call $PROXY "totalSupply()(uint256)" --rpc-url $RPC
cast call $PROXY "convertToAssets(uint256)(uint256)" 1000000 --rpc-url $RPC
```

Historical snapshot at a specific block:

```bash
BLOCK=12345678 ./scripts/apy-snapshot.sh
```

External pair-level fee APY (pool APY, not vault-specific):

- [GeckoTerminal AUSD/USDC on LFJ](https://www.geckoterminal.com/avax/pools/0x8573f98175d816d520248b5facf40d309b1c9cee)

Vault APY will be lower than raw pool APY after vault swap/rebalance costs and when the vault is not 100% of pool liquidity.

## Proxy Emergency Process

The transparent proxy separates user calls from upgrade authority:

- Users call the proxy address.
- The proxy delegates to the current `LFJStableVault` implementation.
- The generated `ProxyAdmin` owns upgrade authority.
- The `MULTISIG` owns `ProxyAdmin`.

For an emergency implementation upgrade:

1. Pause the existing vault and deploy the new `LFJStableVault` implementation.
2. Verify the implementation source and storage layout.
3. From the Safe, call `ProxyAdmin.upgradeAndCall(proxy, newImplementation, initializeV2Calldata)` as one atomic operation, where `initializeV2Calldata` encodes `initializeV2(oracle, haircutBps, accountedPaired)`. Do not pass empty calldata. `accountedPaired` must be the reviewed pre-upgrade strategy balance, excluding unsolicited transfers. The migration initializer authorizes only the vault owner or the proxy's stored `ProxyAdmin`. The new-proxy `initializeWithOracle()` uses initializer version 1, so it cannot be raced on a legacy proxy that already initialized version 1 even if governance mistakenly separates the upgrade and migration calls.
4. Confirm vault state is preserved: total supply, user shares, tracked bins, cap, slippage, rebalancer, and owner. Also confirm the oracle, haircut, and `accountedIdlePaired()` migration value.

Upgradeability is a trust assumption: the multisig can change vault logic. The multisig should use hardware wallets and can later transfer `ProxyAdmin` ownership to a timelock if slower governance becomes acceptable.

## LFJ Ops Notes

`LFJStableVault` deploys deposits into bins around the active LFJ price bin. Keepers should monitor `needsRebalance()` and call `rebalance()` when the active bin moves outside the vault's deposited range.

The vault values the non-asset side with the independent oracle and a conservative haircut. A swap executes only when the LFJ quote after slippage is at least that same oracle floor. Strategy-created idle AUSD is tracked and redeemable; unsolicited AUSD is excluded from share value and cannot consume the cap.

Emergency behavior:

- `pause()` blocks new deposits.
- Redemptions remain available while paused.
- `emergencyWithdrawLP()` is owner-only, pauses the vault, removes all LFJ liquidity, clears tracked bins, and leaves AUSD/USDC idle in the vault.
