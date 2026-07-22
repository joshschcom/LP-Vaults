#!/usr/bin/env bash
# Track LFJ vault share price over time to estimate realized APY.
#
# The vault has no on-chain APY() function. Yield comes from LFJ swap fees
# accruing in the LP position, which shows up as rising totalAssets per share.
#
# Usage:
#   ./scripts/apy-snapshot.sh                    # print + append snapshot
#   ./scripts/apy-snapshot.sh --compare          # compare latest vs previous snapshot
#   BLOCK=12345678 ./scripts/apy-snapshot.sh     # historical snapshot at block
#
# Requires: cast, awk

set -euo pipefail

RPC="${RPC:-${AVAX_MAINNET_RPC_URL:-https://api.avax.network/ext/bc/C/rpc}}"
PROXY="${PROXY:-0x81C0533c8132Bc20c3A53f599925AB01c7dA2B3A}"
SNAPSHOT_FILE="${SNAPSHOT_FILE:-./data/lfj-vault-snapshots.csv}"
ONE_SHARE=1000000  # 1 share at 6-dec USDC precision

COMPARE=false
BLOCK_FLAG=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compare) COMPARE=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--compare]"
      echo "  Snapshots: timestamp, block, totalAssets, totalSupply, assetsPerShare"
      echo "  APY is estimated from share price change between snapshots."
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -n "${BLOCK:-}" ]]; then
  BLOCK_FLAG=(--block "$BLOCK")
fi

mkdir -p "$(dirname "$SNAPSHOT_FILE")"

normalize_num() {
  echo "$1" | awk '{print $1}'
}

vault_call() {
  cast call "$PROXY" "$@" --rpc-url "$RPC" "${BLOCK_FLAG[@]}"
}

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if [[ -n "${BLOCK:-}" ]]; then
  CURRENT_BLOCK="$BLOCK"
else
  CURRENT_BLOCK=$(cast block-number --rpc-url "$RPC")
fi

TOTAL_ASSETS=$(normalize_num "$(vault_call 'totalAssets()(uint256)')")
TOTAL_SUPPLY=$(normalize_num "$(vault_call 'totalSupply()(uint256)')")
PAUSED=$(vault_call 'paused()(bool)')
NEEDS_REB=$(vault_call 'needsRebalance()(bool)')

if [[ "$TOTAL_SUPPLY" == "0" ]]; then
  ASSETS_PER_SHARE="0"
  SHARE_PRICE_USDC="0"
else
  ASSETS_PER_SHARE=$(vault_call "convertToAssets(uint256)(uint256)" "$ONE_SHARE")
  ASSETS_PER_SHARE=$(echo "$ASSETS_PER_SHARE" | awk '{print $1}')
  # Human-readable: micro-USDC / 1e6
  SHARE_PRICE_USDC=$(awk "BEGIN {printf \"%.8f\", $ASSETS_PER_SHARE / 1000000}")
fi

echo "=== LFJ Vault APY Snapshot ==="
echo "Proxy:            $PROXY"
echo "Block:              $CURRENT_BLOCK"
echo "Timestamp:          $TIMESTAMP"
echo "totalAssets:        $TOTAL_ASSETS ($(awk "BEGIN {printf \"%.6f\", $TOTAL_ASSETS / 1000000}") USDC)"
echo "totalSupply:        $TOTAL_SUPPLY shares"
echo "assetsPerShare:     $ASSETS_PER_SHARE micro-USDC"
echo "sharePrice:         $SHARE_PRICE_USDC USDC"
echo "paused:             $PAUSED"
echo "needsRebalance:     $NEEDS_REB"
echo ""

if [[ ! -f "$SNAPSHOT_FILE" ]]; then
  echo "timestamp,block,totalAssets,totalSupply,assetsPerShare,sharePriceUsdc,paused,needsRebalance" > "$SNAPSHOT_FILE"
fi

echo "$TIMESTAMP,$CURRENT_BLOCK,$TOTAL_ASSETS,$TOTAL_SUPPLY,$ASSETS_PER_SHARE,$SHARE_PRICE_USDC,$PAUSED,$NEEDS_REB" >> "$SNAPSHOT_FILE"
echo "Appended to $SNAPSHOT_FILE"

if [[ "$COMPARE" == true ]]; then
  LINES=$(wc -l < "$SNAPSHOT_FILE" | tr -d ' ')
  if [[ "$LINES" -lt 3 ]]; then
    echo ""
    echo "Need at least 2 snapshots to estimate APY. Run this script again later."
    exit 0
  fi

  PREV=$(tail -n 2 "$SNAPSHOT_FILE" | head -n 1)
  CURR=$(tail -n 1 "$SNAPSHOT_FILE")

  PREV_TS=$(echo "$PREV" | cut -d, -f1)
  PREV_PRICE=$(echo "$PREV" | cut -d, -f6)
  CURR_TS=$(echo "$CURR" | cut -d, -f1)
  CURR_PRICE=$(echo "$CURR" | cut -d, -f6)

  if [[ "$PREV_PRICE" == "0" || "$CURR_PRICE" == "0" ]]; then
    echo "Cannot compute APY — share price was 0 in one of the snapshots (empty vault?)."
    exit 0
  fi

  PREV_EPOCH=$(date -d "$PREV_TS" +%s)
  CURR_EPOCH=$(date -d "$CURR_TS" +%s)
  SECONDS=$((CURR_EPOCH - PREV_EPOCH))

  if [[ "$SECONDS" -le 0 ]]; then
    echo "Snapshots too close in time to estimate APY."
    exit 0
  fi

  DAYS=$(awk "BEGIN {printf \"%.8f\", $SECONDS / 86400}")
  GROWTH=$(awk "BEGIN {printf \"%.12f\", $CURR_PRICE / $PREV_PRICE}")
  EXPONENT=$(awk "BEGIN {printf \"%.12f\", 365 / $DAYS}")
  APY=$(awk "BEGIN {printf \"%.8f\", exp(log($GROWTH) * $EXPONENT)}")
  APY_PCT=$(awk "BEGIN {printf \"%.4f\", ($APY - 1) * 100}")

  echo ""
  echo "=== Estimated APY (share price method) ==="
  echo "Previous: $PREV_TS  sharePrice=$PREV_PRICE USDC"
  echo "Current:  $CURR_TS  sharePrice=$CURR_PRICE USDC"
  echo "Period:   $DAYS days"
  echo "Est. APY: ${APY_PCT}% (annualized from share price change)"
  echo ""
  echo "Note: This is realized vault APY from LFJ fees minus swap/rebalance costs."
  echo "      It excludes off-chain LFJ UI metrics and any future gauge rewards."
fi

echo ""
echo "--- External APY references ---"
echo "LFJ pair volume/fees: https://www.geckoterminal.com/avax/pools/0x8573f98175d816d520248b5facf40d309b1c9cee"
echo "Historical share price at block:"
echo "  BLOCK=12345678 ./scripts/apy-snapshot.sh"
