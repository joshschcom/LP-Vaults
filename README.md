# AvaVaults

ERC-4626 vault strategies for Avalanche stablecoin liquidity.

The current launch focus is `LFJStableVault`, a USDC-denominated vault that deploys liquidity into the live LFJ V2.2 AUSD/USDC Liquidity Book pair.

`LFJStableVault` is deployed behind an OpenZeppelin `TransparentUpgradeableProxy`. Users and integrators should use the proxy address. The multisig owns the generated `ProxyAdmin`, which can upgrade the implementation in an emergency.

## LFJ Mainnet Addresses

- Avalanche C-Chain RPC: `https://api.avax.network/ext/bc/C/rpc`
- LFJ V2.2 router: `0x18556DA13313f3532c54711497A8FedAC273220E`
- AUSD: `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a`
- USDC: `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`
- LFJ AUSD/USDC pair: `0x8573F98175D816d520248B5fACF40D309B1c9ceE`
- Pair order: `tokenX = AUSD`, `tokenY = USDC`
- Vault asset: `USDC`
- Bin step: `1`

## Common Commands

Build:

```bash
make build
```

Run the LFJ Avalanche mainnet fork tests:

```bash
make test-lfj-fork
```

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
  KEEPER=0xYourKeeper
```

Broadcast the LFJ mainnet deployment:

```bash
make deploy-lfj-proxy-mainnet \
  DEPLOYER=0xYourDeployer \
  MULTISIG=0xYourMultisig \
  KEEPER=0xYourKeeper \
  PRIVATE_KEY=0xyour_private_key
```

## LFJ Deployment Checklist

Before broadcasting:

- Confirm `DeployMainnet` uses the live AUSD/USDC pair and exact LFJ pair ordering.
- Confirm `MULTISIG` is the intended vault owner and `ProxyAdmin` owner.
- Confirm `KEEPER` is the intended rebalance operator.
- Confirm launch settings:
  - Deposit cap: `500_000e6`
  - Bin range: `2`
  - Slippage: `30` bps
- Run `make build`.
- Run `make test-lfj-fork-pinned`.
- Run `make deploy-lfj-proxy-dry-run DEPLOYER=... MULTISIG=... KEEPER=...`.

After deployment:

- Run `make check-lfj` (or `./scripts/post-deploy-check.sh`).
- Save and publish the proxy, implementation, and ProxyAdmin addresses.
- Verify the implementation and proxy on SnowTrace/SnowScan.
- Confirm proxy `asset() == USDC`.
- Confirm proxy `tokenX() == AUSD` and `tokenY() == USDC`.
- Confirm proxy `BIN_STEP() == 1`.
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

1. Deploy the new `LFJStableVault` implementation.
2. Verify the implementation source.
3. From the multisig, call `ProxyAdmin.upgradeAndCall(proxy, newImplementation, "")`.
4. Confirm vault state is preserved: total supply, user shares, tracked bins, cap, slippage, rebalancer, and owner.

Upgradeability is a trust assumption: the multisig can change vault logic. The multisig should use hardware wallets and can later transfer `ProxyAdmin` ownership to a timelock if slower governance becomes acceptable.

## LFJ Ops Notes

`LFJStableVault` deploys deposits into bins around the active LFJ price bin. Keepers should monitor `needsRebalance()` and call `rebalance()` when the active bin moves outside the vault's deposited range.

The vault values the non-asset side conservatively in `totalAssets()` to account for the swap back into USDC on redeem. This helps avoid ERC-4626 withdrawals promising more USDC than the vault can liquidate after LFJ fees and slippage.

Emergency behavior:

- `pause()` blocks new deposits.
- Redemptions remain available while paused.
- `emergencyWithdrawLP()` is owner-only, pauses the vault, removes all LFJ liquidity, clears tracked bins, and leaves AUSD/USDC idle in the vault.
