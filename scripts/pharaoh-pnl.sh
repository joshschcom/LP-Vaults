#!/usr/bin/env bash
# Read-only monitoring for the deployed Pharaoh canary positions.
#
# Besides ERC-4626 accounting, this script simulates redeeming the Safe's
# complete share balance with eth_call. The simulation collects current fees,
# removes liquidity, and swaps the paired token without changing chain state.
# This gives a more useful executable-value estimate than totalAssets(), which
# intentionally excludes uncollected fees.
#
# Usage:
#   ./scripts/pharaoh-pnl.sh
#   ./scripts/pharaoh-pnl.sh --snapshot
#   BLOCK=12345678 ./scripts/pharaoh-pnl.sh
#
# Cost basis defaults to the funded 30 USDC and 1.75 WAVAX stages. Override it
# after any additional deposit, withdrawal, or share transfer.

set -euo pipefail

RPC="${RPC:-${AVAX_RPC:-${AVAX_MAINNET_RPC_URL:-https://api.avax.network/ext/bc/C/rpc}}}"
readonly SAFE="0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12"
readonly USDC_VAULT="0x855bF832f26a294d28500db59eE941dE3d654129"
readonly WAVAX_VAULT="0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8"
readonly USDC_PROXY_ADMIN="0x2DD4191B2944396B5853f4219E829f01636F65cf"
readonly WAVAX_PROXY_ADMIN="0x34CbBdfcBcc72e8bf70CbF6c7245fdb2725b94dC"
readonly PHAR="0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7"
readonly XPHAR="0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A"
readonly WAVAX="0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7"
readonly USDC="0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"
readonly PHARAOH_REWARD_COMPOUNDER="0xe7fCeE8d52B5340168eb33804c49BE086cE04cB0"
readonly PHARAOH_REWARD_COMPOUNDER_CODEHASH="0xbdf6e858119981209156b7d7619201a9b8aed2c5ab6fb5d04611b60cfd89b1c5"
readonly CURRENT_IMPLEMENTATION="0x165E1f072e7bEeDf94f14F732838354cA20bA45d"
readonly CURRENT_IMPLEMENTATION_CODEHASH="0x4fa61d2d9ce0a7e8f1aebf96fd007fad0aa17f969be476eddd6d6f344fb22e4b"
readonly PHARAOH_SWAP_ROUTER="0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c"
readonly PHARAOH_SWAP_ROUTER_CODEHASH="0xc73f3d2a21cdace7e104858002a8be4442e2dc9d234f39c3f01320a962219032"
readonly PHARAOH_QUOTER="0xB7297301b7CC659BB96D51754643A0Df6eEA2138"
readonly PHARAOH_QUOTER_CODEHASH="0xf520476b52f99d9a1ff89c6187193eb240c6cb1d11d2e6466ebcbbdf7a753bd2"
readonly PHARAOH_FACTORY="0xAE6E5c62328ade73ceefD42228528b70c8157D0d"
readonly PHAR_WAVAX_POOL="0xb78DA03566B6537aCC22F6a4ba070AbCF6eDebF6"
readonly PHAR_WAVAX_POOL_CODEHASH="0x8574735b0859cec219b9019a9b80cae444288ef8b884ae74f7ca7d21b4244363"
readonly WAVAX_USDC_POOL="0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534"
readonly WAVAX_USDC_POOL_CODEHASH="0xc09ba0e43ec861307c9abaf85e482e9562c1fb0597d782070c93aa12ddfd9ac6"
readonly ERC1967_IMPLEMENTATION_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
readonly ERC1967_ADMIN_SLOT="0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
PHAR_COMPOUND_MIN_USDC_RAW="${PHAR_COMPOUND_MIN_USDC_RAW:-100000}"
USDC_COST_BASIS_RAW="${USDC_COST_BASIS_RAW:-30000000}"
WAVAX_COST_BASIS_RAW="${WAVAX_COST_BASIS_RAW:-1750000000000000000}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-./data}"
MONITOR_FAILURES=0

for command in cast bc; do
  command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }
done
for value_name in PHAR_COMPOUND_MIN_USDC_RAW USDC_COST_BASIS_RAW WAVAX_COST_BASIS_RAW; do
  value="${!value_name}"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value_name must be a nonnegative integer" >&2
    exit 1
  fi
done
if [[ "$(bc <<< "$PHAR_COMPOUND_MIN_USDC_RAW <= 0")" == "1" ]]; then
  echo "PHAR_COMPOUND_MIN_USDC_RAW must be positive" >&2
  exit 1
fi
PHAR_COMPOUND_MIN_USDC_RAW=$(bc <<< "$PHAR_COMPOUND_MIN_USDC_RAW / 1")
USDC_COST_BASIS_RAW=$(bc <<< "$USDC_COST_BASIS_RAW / 1")
WAVAX_COST_BASIS_RAW=$(bc <<< "$WAVAX_COST_BASIS_RAW / 1")

WRITE_SNAPSHOT=false
case "${1:-}" in
  "") ;;
  --snapshot) WRITE_SNAPSHOT=true ;;
  --help|-h)
    echo "Usage: $0 [--snapshot]"
    echo "Environment: RPC, BLOCK, USDC_COST_BASIS_RAW, WAVAX_COST_BASIS_RAW,"
    echo "             SNAPSHOT_DIR,"
    echo "             PHAR_COMPOUND_MIN_USDC_RAW"
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    exit 1
    ;;
esac

normalize_num() {
  echo "$1" | awk '{print $1}'
}

human_amount() {
  local raw="$1"
  local decimals="$2"
  awk -v raw="$raw" -v decimals="$decimals" 'BEGIN {
    scale = 1
    for (i = 0; i < decimals; i++) scale *= 10
    printf "%.8f", raw / scale
  }'
}

lower() {
  tr '[:upper:]' '[:lower:]' <<< "$1"
}

monitor_invariant() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$(lower "$actual")" == "$(lower "$expected")" ]]; then
    echo "OK    $label: $actual"
  else
    echo "ALERT $label: expected $expected, got $actual"
    MONITOR_FAILURES=$((MONITOR_FAILURES + 1))
  fi
}

monitor_nonzero() {
  local label="$1"
  local actual="$2"
  if [[ "$actual" != "0" ]]; then
    echo "OK    $label: $actual"
  else
    echo "ALERT $label: expected nonzero, got 0"
    MONITOR_FAILURES=$((MONITOR_FAILURES + 1))
  fi
}

monitor_recoverable_balance() {
  local label="$1"
  local actual="$2"
  if [[ "$actual" == "0" ]]; then
    echo "OK    $label: 0"
  else
    echo "WARN  $label: $actual (recoverable dust; does not block bounded batches)"
  fi
}

codehash_at_block() {
  local runtime_code
  runtime_code=$(cast code "$1" --rpc-url "$RPC" --block "$CURRENT_BLOCK")
  cast keccak "$runtime_code"
}

storage_address() {
  local raw
  raw=$(cast storage "$1" "$2" --rpc-url "$RPC" --block "$CURRENT_BLOCK")
  cast to-check-sum-address "0x${raw: -40}"
}

vault_call() {
  local vault="$1"
  shift
  cast call "$vault" "$@" --rpc-url "$RPC" --block "$CURRENT_BLOCK"
}

NOW_EPOCH=$(date -u +%s)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CHAIN_ID=$(normalize_num "$(cast chain-id --rpc-url "$RPC")")
if [[ "$CHAIN_ID" != "43114" ]]; then
  echo "wrong chain: expected Avalanche 43114, got $CHAIN_ID" >&2
  exit 1
fi
if [[ -n "${BLOCK:-}" ]]; then
  CURRENT_BLOCK="$BLOCK"
else
  CURRENT_BLOCK=$(cast block-number --rpc-url "$RPC")
fi
if ! [[ "$CURRENT_BLOCK" =~ ^[0-9]+$ ]]; then
  echo "BLOCK must resolve to a decimal block number" >&2
  exit 1
fi

monitor_vault() {
  local label="$1"
  local symbol="$2"
  local vault="$3"
  local decimals="$4"
  local one_share="$5"
  local cost_basis="$6"
  local snapshot_file="$7"

  local paused cap supply safe_shares token_id share_price pool
  paused=$(vault_call "$vault" 'paused()(bool)')
  cap=$(normalize_num "$(vault_call "$vault" 'depositCap()(uint256)')")
  supply=$(normalize_num "$(vault_call "$vault" 'totalSupply()(uint256)')")
  safe_shares=$(normalize_num "$(vault_call "$vault" 'balanceOf(address)(uint256)' "$SAFE")")
  token_id=$(normalize_num "$(vault_call "$vault" 'tokenId()(uint256)')")
  pool=$(normalize_num "$(vault_call "$vault" 'pool()(address)')")

  local lower_tick="n/a"
  local upper_tick="n/a"
  local spot_tick="n/a"
  local in_range="n/a"
  if [[ "$token_id" != "0" ]]; then
    lower_tick=$(normalize_num "$(vault_call "$vault" 'positionTickLower()(int24)')")
    upper_tick=$(normalize_num "$(vault_call "$vault" 'positionTickUpper()(int24)')")
    local slot0_output
    slot0_output=$(vault_call "$pool" 'slot0()(uint160,int24,uint16,uint16,uint16,uint24,bool)')
    spot_tick=$(echo "$slot0_output" | sed -n '2p' | awk '{print $1}')
    if [[ "$spot_tick" -gt "$lower_tick" && "$spot_tick" -lt "$upper_tick" ]]; then
      in_range="true"
    else
      in_range="false"
    fi
  fi

  local total_assets="unavailable"
  local total_assets_error=""
  local call_output
  if call_output=$(vault_call "$vault" 'totalAssets()(uint256)' 2>&1); then
    total_assets=$(normalize_num "$call_output")
  else
    total_assets_error="$call_output"
  fi

  share_price="0"
  if [[ "$supply" != "0" ]]; then
    if call_output=$(vault_call "$vault" 'convertToAssets(uint256)(uint256)' "$one_share" 2>&1); then
      share_price=$(normalize_num "$call_output")
    else
      share_price="unavailable"
    fi
  fi

  local simulated_redeem="0"
  local redeem_error=""
  local redeem_ok=false
  if [[ "$safe_shares" != "0" ]]; then
    call_output=$(cast call \
      "$vault" \
      'redeem(uint256,address,address)(uint256)' \
      "$safe_shares" \
      "$SAFE" \
      "$SAFE" \
      --from "$SAFE" \
      --rpc-url "$RPC" \
      --block "$CURRENT_BLOCK" 2>&1) && redeem_ok=true || redeem_ok=false
    if [[ "$redeem_ok" == true ]]; then
      simulated_redeem=$(normalize_num "$call_output")
    else
      simulated_redeem="unavailable"
      redeem_error="$call_output"
    fi
  fi

  echo "=== $label Pharaoh Vault ==="
  echo "Vault:                $vault"
  echo "Safe:                 $SAFE"
  echo "Block:                $CURRENT_BLOCK"
  echo "Timestamp:            $TIMESTAMP"
  echo "paused:               $paused"
  echo "depositCap:           $cap raw"
  echo "tokenId:              $token_id"
  echo "position ticks:       $lower_tick .. $upper_tick (spot $spot_tick, in range: $in_range)"
  echo "totalSupply:          $supply"
  echo "Safe shares:          $safe_shares"

  if [[ "$total_assets" == "unavailable" ]]; then
    echo "totalAssets:          unavailable (price/oracle check reverted)"
    echo "  ${total_assets_error%%$'\n'*}"
  else
    echo "totalAssets:          $(human_amount "$total_assets" "$decimals") $symbol ($total_assets raw)"
  fi

  if [[ "$share_price" == "unavailable" ]]; then
    echo "assets per share:     unavailable"
  else
    echo "assets per 1 share:   $(human_amount "$share_price" "$decimals") $symbol"
  fi

  local pnl_pct=""
  local pnl_human=""
  if [[ "$simulated_redeem" == "unavailable" ]]; then
    echo "simulated redemption: unavailable"
    echo "  ${redeem_error%%$'\n'*}"
  elif [[ "$safe_shares" == "0" ]]; then
    echo "simulated redemption: no Safe-owned shares"
  else
    echo "simulated redemption: $(human_amount "$simulated_redeem" "$decimals") $symbol ($simulated_redeem raw)"
    echo "cost basis:           $(human_amount "$cost_basis" "$decimals") $symbol ($cost_basis raw)"
    pnl_human=$(awk -v value="$simulated_redeem" -v cost="$cost_basis" -v decimals="$decimals" 'BEGIN {
      scale = 1
      for (i = 0; i < decimals; i++) scale *= 10
      printf "%+.8f", (value - cost) / scale
    }')
    pnl_pct=$(awk -v value="$simulated_redeem" -v cost="$cost_basis" 'BEGIN {
      if (cost == 0) print "n/a"; else printf "%+.6f", ((value / cost) - 1) * 100
    }')
    echo "executable PnL:       $pnl_human $symbol ($pnl_pct%)"
  fi

  if [[ "$WRITE_SNAPSHOT" == true ]]; then
    mkdir -p "$SNAPSHOT_DIR"
    local path="$SNAPSHOT_DIR/$snapshot_file"
    if [[ ! -f "$path" ]]; then
      echo "timestamp,epoch,block,vault,totalAssets,totalSupply,safeShares,assetsPerShare,simulatedRedeem,costBasisRaw,pnlPct,paused,tokenId,lowerTick,upperTick,spotTick,inRange" > "$path"
    fi
    echo "$TIMESTAMP,$NOW_EPOCH,$CURRENT_BLOCK,$vault,$total_assets,$supply,$safe_shares,$share_price,$simulated_redeem,$cost_basis,$pnl_pct,$paused,$token_id,$lower_tick,$upper_tick,$spot_tick,$in_range" >> "$path"
    echo "Snapshot:             $path"
  fi
  echo ""
}

monitor_vault \
  "USDC/USDt" \
  "USDC" \
  "$USDC_VAULT" \
  6 \
  1000000 \
  "$USDC_COST_BASIS_RAW" \
  "pharaoh-usdc-pnl.csv"

monitor_vault \
  "sAVAX/WAVAX" \
  "WAVAX" \
  "$WAVAX_VAULT" \
  18 \
  1000000000000000000 \
  "$WAVAX_COST_BASIS_RAW" \
  "pharaoh-wavax-pnl.csv"

monitor_rewards() {
  local safe_phar usdc_vault_phar wavax_vault_phar safe_xphar usdc_vault_xphar wavax_vault_xphar
  safe_phar=$(normalize_num "$(cast call "$PHAR" 'balanceOf(address)(uint256)' "$SAFE" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  usdc_vault_phar=$(normalize_num "$(cast call "$PHAR" 'balanceOf(address)(uint256)' "$USDC_VAULT" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  wavax_vault_phar=$(normalize_num "$(cast call "$PHAR" 'balanceOf(address)(uint256)' "$WAVAX_VAULT" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  safe_xphar=$(normalize_num "$(cast call "$XPHAR" 'balanceOf(address)(uint256)' "$SAFE" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  usdc_vault_xphar=$(normalize_num "$(cast call "$XPHAR" 'balanceOf(address)(uint256)' "$USDC_VAULT" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  wavax_vault_xphar=$(normalize_num "$(cast call "$XPHAR" 'balanceOf(address)(uint256)' "$WAVAX_VAULT" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")

  local wavax_quote="0"
  local usdc_quote="0"
  local quote_status="available"
  if [[ "$safe_phar" != "0" ]]; then
    local call_output
    if call_output=$(cast call \
      "$PHARAOH_QUOTER" \
      'quoteExactInputSingle((address,address,uint256,int24,uint160))(uint256,uint160,uint32,uint256)' \
      "($PHAR,$WAVAX,$safe_phar,5,0)" \
      --rpc-url "$RPC" \
      --block "$CURRENT_BLOCK" 2>&1); then
      wavax_quote=$(echo "$call_output" | sed -n '1p' | awk '{print $1}')
    else
      quote_status="unavailable"
    fi

    local usdc_path="0x${PHAR#0x}000005${WAVAX#0x}00000a${USDC#0x}"
    if call_output=$(cast call \
      "$PHARAOH_QUOTER" \
      'quoteExactInput(bytes,uint256)(uint256,uint160[],uint32[],uint256)' \
      "$usdc_path" \
      "$safe_phar" \
      --rpc-url "$RPC" \
      --block "$CURRENT_BLOCK" 2>&1); then
      usdc_quote=$(echo "$call_output" | sed -n '1p' | awk '{print $1}')
    else
      quote_status="unavailable"
    fi
  fi

  local usdc_pending_phar="unavailable"
  local wavax_pending_phar="unavailable"
  local usdc_pending_value="unavailable"
  local wavax_pending_value="unavailable"
  local pending_output
  if pending_output=$(cast call \
    "$USDC_VAULT" \
    'harvestRewards(bool,uint256)(uint256,uint256)' \
    true \
    0 \
    --from "$SAFE" \
    --rpc-url "$RPC" \
    --block "$CURRENT_BLOCK" 2>&1); then
    usdc_pending_phar=$(echo "$pending_output" | sed -n '1p' | awk '{print $1}')
  fi
  if pending_output=$(cast call \
    "$WAVAX_VAULT" \
    'harvestRewards(bool,uint256)(uint256,uint256)' \
    true \
    0 \
    --from "$SAFE" \
    --rpc-url "$RPC" \
    --block "$CURRENT_BLOCK" 2>&1); then
    wavax_pending_phar=$(echo "$pending_output" | sed -n '1p' | awk '{print $1}')
  fi

  local usdc_path="0x${PHAR#0x}000005${WAVAX#0x}00000a${USDC#0x}"
  local pending_quote
  if [[ "$usdc_pending_phar" != "unavailable" && "$usdc_pending_phar" != "0" ]]; then
    if pending_quote=$(cast call \
      "$PHARAOH_QUOTER" \
      'quoteExactInput(bytes,uint256)(uint256,uint160[],uint32[],uint256)' \
      "$usdc_path" \
      "$usdc_pending_phar" \
      --rpc-url "$RPC" \
      --block "$CURRENT_BLOCK" 2>&1); then
      usdc_pending_value=$(echo "$pending_quote" | sed -n '1p' | awk '{print $1}')
    fi
  elif [[ "$usdc_pending_phar" == "0" ]]; then
    usdc_pending_value="0"
  fi
  if [[ "$wavax_pending_phar" != "unavailable" && "$wavax_pending_phar" != "0" ]]; then
    if pending_quote=$(cast call \
      "$PHARAOH_QUOTER" \
      'quoteExactInput(bytes,uint256)(uint256,uint160[],uint32[],uint256)' \
      "$usdc_path" \
      "$wavax_pending_phar" \
      --rpc-url "$RPC" \
      --block "$CURRENT_BLOCK" 2>&1); then
      wavax_pending_value=$(echo "$pending_quote" | sed -n '1p' | awk '{print $1}')
    fi
  elif [[ "$wavax_pending_phar" == "0" ]]; then
    wavax_pending_value="0"
  fi

  echo "=== External Pharaoh Reward Inventory ==="
  echo "Safe PHAR:            $(human_amount "$safe_phar" 18) PHAR ($safe_phar raw)"
  echo "USDC vault PHAR:      $(human_amount "$usdc_vault_phar" 18) PHAR ($usdc_vault_phar raw)"
  echo "WAVAX vault PHAR:     $(human_amount "$wavax_vault_phar" 18) PHAR ($wavax_vault_phar raw)"
  echo "Safe xPHAR:           $(human_amount "$safe_xphar" 18) xPHAR ($safe_xphar raw)"
  echo "USDC vault xPHAR:     $(human_amount "$usdc_vault_xphar" 18) xPHAR ($usdc_vault_xphar raw)"
  echo "WAVAX vault xPHAR:    $(human_amount "$wavax_vault_xphar" 18) xPHAR ($wavax_vault_xphar raw)"
  if [[ "$quote_status" == "available" ]]; then
    echo "Safe PHAR quote:      $(human_amount "$wavax_quote" 18) WAVAX ($wavax_quote raw)"
    echo "Safe PHAR value:      ~$(human_amount "$usdc_quote" 6) USDC ($usdc_quote raw)"
  else
    echo "Safe PHAR quote:      unavailable"
  fi
  if [[ "$usdc_pending_phar" == "unavailable" ]]; then
    echo "USDC pending PHAR:    unavailable"
  else
    echo "USDC pending PHAR:    $(human_amount "$usdc_pending_phar" 18) PHAR ($usdc_pending_phar raw)"
  fi
  if [[ "$wavax_pending_phar" == "unavailable" ]]; then
    echo "WAVAX pending PHAR:   unavailable"
  else
    echo "WAVAX pending PHAR:   $(human_amount "$wavax_pending_phar" 18) PHAR ($wavax_pending_phar raw)"
  fi
  echo "Compound threshold:  $(human_amount "$PHAR_COMPOUND_MIN_USDC_RAW" 6) USDC ($PHAR_COMPOUND_MIN_USDC_RAW raw)"
  if [[ "$usdc_pending_value" != "unavailable" ]]; then
    if [[ "$(bc <<< "$usdc_pending_value >= $PHAR_COMPOUND_MIN_USDC_RAW")" == "1" ]]; then
      echo "USDC reward cycle:    READY (~$(human_amount "$usdc_pending_value" 6) USDC)"
    else
      echo "USDC reward cycle:    WAIT (~$(human_amount "$usdc_pending_value" 6) USDC)"
    fi
  else
    echo "USDC reward cycle:    quote unavailable"
  fi
  if [[ "$wavax_pending_value" != "unavailable" ]]; then
    if [[ "$(bc <<< "$wavax_pending_value >= $PHAR_COMPOUND_MIN_USDC_RAW")" == "1" ]]; then
      echo "WAVAX reward cycle:   READY (~$(human_amount "$wavax_pending_value" 6) USDC)"
    else
      echo "WAVAX reward cycle:   WAIT (~$(human_amount "$wavax_pending_value" 6) USDC)"
    fi
  else
    echo "WAVAX reward cycle:   quote unavailable"
  fi

  if [[ "$WRITE_SNAPSHOT" == true ]]; then
    mkdir -p "$SNAPSHOT_DIR"
    local path="$SNAPSHOT_DIR/pharaoh-rewards.csv"
    if [[ ! -f "$path" ]]; then
      echo "timestamp,epoch,block,safe,safePhar,usdcVaultPhar,wavaxVaultPhar,safeXPhar,usdcVaultXPhar,wavaxVaultXPhar,quotedWavax,quotedUsdc" > "$path"
    fi
    echo "$TIMESTAMP,$NOW_EPOCH,$CURRENT_BLOCK,$SAFE,$safe_phar,$usdc_vault_phar,$wavax_vault_phar,$safe_xphar,$usdc_vault_xphar,$wavax_vault_xphar,$wavax_quote,$usdc_quote" >> "$path"
    echo "Snapshot:             $path"
  fi
  echo ""
}

monitor_rewards

monitor_compounder() {
  local runtime_codehash implementation_codehash router_codehash quoter_codehash
  local phar_wavax_pool_codehash wavax_usdc_pool_codehash
  runtime_codehash=$(codehash_at_block "$PHARAOH_REWARD_COMPOUNDER")
  implementation_codehash=$(codehash_at_block "$CURRENT_IMPLEMENTATION")
  router_codehash=$(codehash_at_block "$PHARAOH_SWAP_ROUTER")
  quoter_codehash=$(codehash_at_block "$PHARAOH_QUOTER")
  phar_wavax_pool_codehash=$(codehash_at_block "$PHAR_WAVAX_POOL")
  wavax_usdc_pool_codehash=$(codehash_at_block "$WAVAX_USDC_POOL")

  local compounder_phar compounder_wavax compounder_usdc safe_allowance router_allowance
  compounder_phar=$(normalize_num "$(cast call "$PHAR" 'balanceOf(address)(uint256)' "$PHARAOH_REWARD_COMPOUNDER" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  compounder_wavax=$(normalize_num "$(cast call "$WAVAX" 'balanceOf(address)(uint256)' "$PHARAOH_REWARD_COMPOUNDER" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  compounder_usdc=$(normalize_num "$(cast call "$USDC" 'balanceOf(address)(uint256)' "$PHARAOH_REWARD_COMPOUNDER" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  safe_allowance=$(normalize_num "$(cast call "$PHAR" 'allowance(address,address)(uint256)' "$SAFE" "$PHARAOH_REWARD_COMPOUNDER" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  router_allowance=$(normalize_num "$(cast call "$PHAR" 'allowance(address,address)(uint256)' "$PHARAOH_REWARD_COMPOUNDER" "$PHARAOH_SWAP_ROUTER" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")

  local pool_deployer usdc_supply wavax_supply usdc_safe_shares wavax_safe_shares
  local usdc_token_id wavax_token_id phar_wavax_liquidity wavax_usdc_liquidity
  pool_deployer=$(cast call "$PHARAOH_FACTORY" 'ramsesV3PoolDeployer()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")
  usdc_supply=$(normalize_num "$(cast call "$USDC_VAULT" 'totalSupply()(uint256)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  wavax_supply=$(normalize_num "$(cast call "$WAVAX_VAULT" 'totalSupply()(uint256)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  usdc_safe_shares=$(normalize_num "$(cast call "$USDC_VAULT" 'balanceOf(address)(uint256)' "$SAFE" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  wavax_safe_shares=$(normalize_num "$(cast call "$WAVAX_VAULT" 'balanceOf(address)(uint256)' "$SAFE" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  usdc_token_id=$(normalize_num "$(cast call "$USDC_VAULT" 'tokenId()(uint256)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  wavax_token_id=$(normalize_num "$(cast call "$WAVAX_VAULT" 'tokenId()(uint256)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  phar_wavax_liquidity=$(normalize_num "$(cast call "$PHAR_WAVAX_POOL" 'liquidity()(uint128)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  wavax_usdc_liquidity=$(normalize_num "$(cast call "$WAVAX_USDC_POOL" 'liquidity()(uint128)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")

  echo "=== Pharaoh Reward Compounder Invariants ==="
  echo "Compounder:           $PHARAOH_REWARD_COMPOUNDER"
  monitor_invariant "runtime codehash" "$runtime_codehash" "$PHARAOH_REWARD_COMPOUNDER_CODEHASH"
  monitor_invariant "vault implementation codehash" "$implementation_codehash" "$CURRENT_IMPLEMENTATION_CODEHASH"
  monitor_invariant "router codehash" "$router_codehash" "$PHARAOH_SWAP_ROUTER_CODEHASH"
  monitor_invariant "quoter codehash" "$quoter_codehash" "$PHARAOH_QUOTER_CODEHASH"
  monitor_invariant "PHAR/WAVAX pool codehash" "$phar_wavax_pool_codehash" "$PHAR_WAVAX_POOL_CODEHASH"
  monitor_invariant "WAVAX/USDC pool codehash" "$wavax_usdc_pool_codehash" "$WAVAX_USDC_POOL_CODEHASH"
  monitor_invariant "Safe" "$(cast call "$PHARAOH_REWARD_COMPOUNDER" 'safe()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$SAFE"
  monitor_invariant "PHAR" "$(cast call "$PHARAOH_REWARD_COMPOUNDER" 'phar()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$PHAR"
  monitor_invariant "WAVAX" "$(cast call "$PHARAOH_REWARD_COMPOUNDER" 'wavax()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$WAVAX"
  monitor_invariant "USDC" "$(cast call "$PHARAOH_REWARD_COMPOUNDER" 'usdc()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$USDC"
  monitor_invariant "router" "$(cast call "$PHARAOH_REWARD_COMPOUNDER" 'swapRouter()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$PHARAOH_SWAP_ROUTER"
  monitor_invariant "USDC vault" "$(cast call "$PHARAOH_REWARD_COMPOUNDER" 'usdcVault()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$USDC_VAULT"
  monitor_invariant "WAVAX vault" "$(cast call "$PHARAOH_REWARD_COMPOUNDER" 'wavaxVault()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$WAVAX_VAULT"
  monitor_invariant "PHAR/WAVAX spacing" "$(normalize_num "$(cast call "$PHARAOH_REWARD_COMPOUNDER" 'pharWavaxTickSpacing()(int24)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")" "5"
  monitor_invariant "WAVAX/USDC spacing" "$(normalize_num "$(cast call "$PHARAOH_REWARD_COMPOUNDER" 'wavaxUsdcTickSpacing()(int24)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")" "10"
  monitor_invariant "PHAR/WAVAX pool" "$(cast call "$PHARAOH_FACTORY" 'getPool(address,address,int24)(address)' "$PHAR" "$WAVAX" 5 --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$PHAR_WAVAX_POOL"
  monitor_invariant "WAVAX/USDC pool" "$(cast call "$PHARAOH_FACTORY" 'getPool(address,address,int24)(address)' "$WAVAX" "$USDC" 10 --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$WAVAX_USDC_POOL"
  monitor_invariant "router deployer" "$(cast call "$PHARAOH_SWAP_ROUTER" 'deployer()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$pool_deployer"
  monitor_invariant "quoter deployer" "$(cast call "$PHARAOH_QUOTER" 'deployer()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$pool_deployer"
  monitor_invariant "PHAR/WAVAX token0" "$(cast call "$PHAR_WAVAX_POOL" 'token0()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$PHAR"
  monitor_invariant "PHAR/WAVAX token1" "$(cast call "$PHAR_WAVAX_POOL" 'token1()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$WAVAX"
  monitor_invariant "PHAR/WAVAX spacing" "$(normalize_num "$(cast call "$PHAR_WAVAX_POOL" 'tickSpacing()(int24)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")" "5"
  monitor_invariant "WAVAX/USDC token0" "$(cast call "$WAVAX_USDC_POOL" 'token0()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$WAVAX"
  monitor_invariant "WAVAX/USDC token1" "$(cast call "$WAVAX_USDC_POOL" 'token1()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$USDC"
  monitor_invariant "WAVAX/USDC spacing" "$(normalize_num "$(cast call "$WAVAX_USDC_POOL" 'tickSpacing()(int24)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")" "10"
  monitor_nonzero "PHAR/WAVAX active liquidity" "$phar_wavax_liquidity"
  monitor_nonzero "WAVAX/USDC active liquidity" "$wavax_usdc_liquidity"
  monitor_invariant "USDC vault owner" "$(cast call "$USDC_VAULT" 'owner()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$SAFE"
  monitor_invariant "WAVAX vault owner" "$(cast call "$WAVAX_VAULT" 'owner()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$SAFE"
  monitor_invariant "USDC vault asset" "$(cast call "$USDC_VAULT" 'asset()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$USDC"
  monitor_invariant "WAVAX vault asset" "$(cast call "$WAVAX_VAULT" 'asset()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$WAVAX"
  monitor_invariant "USDC vault router" "$(cast call "$USDC_VAULT" 'swapRouter()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$PHARAOH_SWAP_ROUTER"
  monitor_invariant "WAVAX vault router" "$(cast call "$WAVAX_VAULT" 'swapRouter()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$PHARAOH_SWAP_ROUTER"
  monitor_invariant "USDC vault paused" "$(cast call "$USDC_VAULT" 'paused()(bool)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "false"
  monitor_invariant "WAVAX vault paused" "$(cast call "$WAVAX_VAULT" 'paused()(bool)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "false"
  monitor_invariant "USDC vault cap" "$(normalize_num "$(cast call "$USDC_VAULT" 'depositCap()(uint256)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")" "1"
  monitor_invariant "WAVAX vault cap" "$(normalize_num "$(cast call "$WAVAX_VAULT" 'depositCap()(uint256)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")" "1"
  monitor_invariant "USDC vault implementation" "$(storage_address "$USDC_VAULT" "$ERC1967_IMPLEMENTATION_SLOT")" "$CURRENT_IMPLEMENTATION"
  monitor_invariant "WAVAX vault implementation" "$(storage_address "$WAVAX_VAULT" "$ERC1967_IMPLEMENTATION_SLOT")" "$CURRENT_IMPLEMENTATION"
  monitor_invariant "USDC vault ProxyAdmin" "$(storage_address "$USDC_VAULT" "$ERC1967_ADMIN_SLOT")" "$USDC_PROXY_ADMIN"
  monitor_invariant "WAVAX vault ProxyAdmin" "$(storage_address "$WAVAX_VAULT" "$ERC1967_ADMIN_SLOT")" "$WAVAX_PROXY_ADMIN"
  monitor_invariant "USDC ProxyAdmin owner" "$(cast call "$USDC_PROXY_ADMIN" 'owner()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$SAFE"
  monitor_invariant "WAVAX ProxyAdmin owner" "$(cast call "$WAVAX_PROXY_ADMIN" 'owner()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$SAFE"
  monitor_nonzero "USDC vault position tokenId" "$usdc_token_id"
  monitor_nonzero "WAVAX vault position tokenId" "$wavax_token_id"
  monitor_nonzero "USDC vault share supply" "$usdc_supply"
  monitor_nonzero "WAVAX vault share supply" "$wavax_supply"
  monitor_invariant "USDC shares owned by Safe" "$usdc_safe_shares" "$usdc_supply"
  monitor_invariant "WAVAX shares owned by Safe" "$wavax_safe_shares" "$wavax_supply"
  monitor_recoverable_balance "compounder PHAR balance" "$compounder_phar"
  monitor_recoverable_balance "compounder WAVAX balance" "$compounder_wavax"
  monitor_recoverable_balance "compounder USDC balance" "$compounder_usdc"
  monitor_invariant "Safe PHAR allowance" "$safe_allowance" "0"
  monitor_invariant "router PHAR allowance" "$router_allowance" "0"
  echo ""
}

monitor_compounder

echo "The simulated redemption is an eth_call: it does not burn shares or move funds."
echo "Vault PnL excludes gas and PHAR/xPHAR until rewards are converted and donated as underlying."
echo "The PHAR quote is an executable Pharaoh spot estimate, not an accounting oracle or collateral price."
echo "Update cost basis after any capital flow."

if (( MONITOR_FAILURES != 0 )); then
  echo "$MONITOR_FAILURES compounder invariant(s) failed." >&2
  exit 1
fi
