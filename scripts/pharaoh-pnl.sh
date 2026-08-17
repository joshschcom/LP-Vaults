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
SAFE="${SAFE:-0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12}"
USDC_VAULT="${USDC_VAULT:-0x855bF832f26a294d28500db59eE941dE3d654129}"
WAVAX_VAULT="${WAVAX_VAULT:-0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8}"
PHAR="${PHAR:-0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7}"
XPHAR="${XPHAR:-0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A}"
WAVAX="${WAVAX:-0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7}"
USDC="${USDC:-0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E}"
PHARAOH_QUOTER="${PHARAOH_QUOTER:-0xB7297301b7CC659BB96D51754643A0Df6eEA2138}"
USDC_COST_BASIS_RAW="${USDC_COST_BASIS_RAW:-30000000}"
WAVAX_COST_BASIS_RAW="${WAVAX_COST_BASIS_RAW:-1750000000000000000}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-./data}"

WRITE_SNAPSHOT=false
case "${1:-}" in
  "") ;;
  --snapshot) WRITE_SNAPSHOT=true ;;
  --help|-h)
    echo "Usage: $0 [--snapshot]"
    echo "Environment: RPC, SAFE, USDC_VAULT, WAVAX_VAULT, BLOCK,"
    echo "             USDC_COST_BASIS_RAW, WAVAX_COST_BASIS_RAW, SNAPSHOT_DIR"
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

vault_call() {
  local vault="$1"
  shift
  cast call "$vault" "$@" --rpc-url "$RPC" --block "$CURRENT_BLOCK"
}

NOW_EPOCH=$(date -u +%s)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if [[ -n "${BLOCK:-}" ]]; then
  CURRENT_BLOCK="$BLOCK"
else
  CURRENT_BLOCK=$(cast block-number --rpc-url "$RPC")
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

echo "The simulated redemption is an eth_call: it does not burn shares or move funds."
echo "Vault PnL excludes gas and PHAR/xPHAR until rewards are converted and donated as underlying."
echo "The PHAR quote is an executable Pharaoh spot estimate, not an accounting oracle or collateral price."
echo "Update cost basis after any capital flow."
