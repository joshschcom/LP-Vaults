#!/usr/bin/env bash
# Post-deployment verification for LFJStableVault (Transparent proxy).
#
# Usage:
#   ./scripts/post-deploy-check.sh
#   PROXY=0x... OWNER=0x... KEEPER=0x... ./scripts/post-deploy-check.sh
#
# Requires: cast

set -euo pipefail

RPC="${RPC:-${AVAX_MAINNET_RPC_URL:-https://api.avax.network/ext/bc/C/rpc}}"

# Defaults from address.MD — override via env if needed
PROXY="${PROXY:-0x81C0533c8132Bc20c3A53f599925AB01c7dA2B3A}"
IMPL="${IMPL:-0x6D208789f0a978aF789A3C8Ba515749598940716}"
ADMIN="${ADMIN:-0xD031640b3549896DE25325479a27cFf4A766F8d8}"
OWNER="${OWNER:-0xCED23360932B80d18fdEAEAa573202E80A584804}"
KEEPER="${KEEPER:-}"  # optional: set to verify rebalancer address

USDC="${USDC:-0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E}"
AUSD="${AUSD:-0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a}"
PAIR="${PAIR:-0x8573F98175D816d520248B5fACF40D309B1c9ceE}"
ROUTER="${ROUTER:-0x18556DA13313f3532c54711497A8FedAC273220E}"

# Expected launch config (from DeployMainnet initialize)
EXPECTED_DEPOSIT_CAP="${EXPECTED_DEPOSIT_CAP:-500000000000}"
EXPECTED_BIN_RANGE="${EXPECTED_BIN_RANGE:-2}"
EXPECTED_SLIPPAGE_BPS="${EXPECTED_SLIPPAGE_BPS:-30}"
EXPECTED_BIN_STEP="${EXPECTED_BIN_STEP:-1}"
EXPECTED_PAIR_VERSION="${EXPECTED_PAIR_VERSION:-3}"
EXPECTED_ASSET_IS_TOKEN_X="${EXPECTED_ASSET_IS_TOKEN_X:-false}"
EXPECTED_PRICE_ORACLE="${EXPECTED_PRICE_ORACLE:-${LFJ_PRICE_ORACLE:-}}"
EXPECTED_VALUATION_HAIRCUT_BPS="${EXPECTED_VALUATION_HAIRCUT_BPS:-200}"

IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ADMIN_SLOT="0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass=0
fail=0
warn=0

vault_call() {
  cast call "$PROXY" "$@" --rpc-url "$RPC"
}

admin_call() {
  cast call "$ADMIN" "$1" --rpc-url "$RPC"
}

normalize_addr() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

check_eq() {
  local label="$1"
  local got="$2"
  local want="$3"
  if [[ "$(normalize_addr "$got")" == "$(normalize_addr "$want")" ]]; then
    echo -e "${GREEN}OK${NC}   $label = $got"
    pass=$((pass + 1))
  else
    echo -e "${RED}FAIL${NC} $label = $got (expected $want)"
    fail=$((fail + 1))
  fi
}

check_bool() {
  local label="$1"
  local got="$2"
  local want="$3"
  if [[ "$got" == "$want" ]]; then
    echo -e "${GREEN}OK${NC}   $label = $got"
    pass=$((pass + 1))
  else
    echo -e "${RED}FAIL${NC} $label = $got (expected $want)"
    fail=$((fail + 1))
  fi
}

normalize_num() {
  # cast may append " [5e11]" for large uints — keep the integer part only
  echo "$1" | awk '{print $1}'
}

check_num() {
  local label="$1"
  local got="$2"
  local want="$3"
  got=$(normalize_num "$got")
  want=$(normalize_num "$want")
  if [[ "$got" == "$want" ]]; then
    echo -e "${GREEN}OK${NC}   $label = $got"
    pass=$((pass + 1))
  else
    echo -e "${RED}FAIL${NC} $label = $got (expected $want)"
    fail=$((fail + 1))
  fi
}

info() {
  echo -e "${YELLOW}INFO${NC} $1"
}

slot_to_address() {
  local slot="$1"
  local raw
  raw=$(cast storage "$PROXY" "$slot" --rpc-url "$RPC")
  echo "0x$(echo "$raw" | tail -c 41)"
}

echo "=== LFJ Vault Post-Deploy Check ==="
echo "RPC:   $RPC"
echo "Proxy: $PROXY"
echo ""

echo "--- Vault config ---"
check_eq "asset()" "$(vault_call 'asset()(address)')" "$USDC"
check_eq "owner()" "$(vault_call 'owner()(address)')" "$OWNER"
check_eq "tokenX()" "$(vault_call 'tokenX()(address)')" "$AUSD"
check_eq "tokenY()" "$(vault_call 'tokenY()(address)')" "$USDC"
check_bool "assetIsTokenX()" "$(vault_call 'assetIsTokenX()(bool)')" "$EXPECTED_ASSET_IS_TOKEN_X"
check_eq "lbRouter()" "$(vault_call 'lbRouter()(address)')" "$ROUTER"
check_eq "lbPair()" "$(vault_call 'lbPair()(address)')" "$PAIR"
check_num "BIN_STEP()" "$(vault_call 'BIN_STEP()(uint16)')" "$EXPECTED_BIN_STEP"
check_num "PAIR_VERSION()" "$(vault_call 'PAIR_VERSION()(uint8)')" "$EXPECTED_PAIR_VERSION"
check_num "depositCap()" "$(vault_call 'depositCap()(uint256)')" "$EXPECTED_DEPOSIT_CAP"
check_num "binRange()" "$(vault_call 'binRange()(uint256)')" "$EXPECTED_BIN_RANGE"
check_num "slippageBps()" "$(vault_call 'slippageBps()(uint256)')" "$EXPECTED_SLIPPAGE_BPS"

if [[ -n "$EXPECTED_PRICE_ORACLE" ]]; then
  check_eq "priceOracle()" "$(vault_call 'priceOracle()(address)')" "$EXPECTED_PRICE_ORACLE"
  check_num "valuationHaircutBps()" "$(vault_call 'valuationHaircutBps()(uint16)')" "$EXPECTED_VALUATION_HAIRCUT_BPS"
else
  info "price oracle not asserted (set EXPECTED_PRICE_ORACLE=0x...)"
fi

REBALANCER=$(vault_call 'rebalancer()(address)')
if [[ -n "$KEEPER" ]]; then
  check_eq "rebalancer()" "$REBALANCER" "$KEEPER"
else
  info "rebalancer() = $REBALANCER (set KEEPER=0x... to assert)"
fi

echo ""
echo "--- Runtime state ---"
PAUSED=$(vault_call 'paused()(bool)')
TOTAL_ASSETS=$(vault_call 'totalAssets()(uint256)')
TOTAL_SUPPLY=$(vault_call 'totalSupply()(uint256)')
NEEDS_REB=$(vault_call 'needsRebalance()(bool)')
info "paused() = $PAUSED"
info "totalAssets() = $TOTAL_ASSETS"
info "totalSupply() = $TOTAL_SUPPLY"
info "needsRebalance() = $NEEDS_REB"
info "getDepositedBins() = $(vault_call 'getDepositedBins()(uint24[])')"
if [[ -n "$EXPECTED_PRICE_ORACLE" ]]; then
  info "accountedIdlePaired() = $(vault_call 'accountedIdlePaired()(uint256)')"
  info "unaccountedPairedBalance() = $(vault_call 'unaccountedPairedBalance()(uint256)')"
fi

# Share price (USDC per 1 share, 6 decimals)
if [[ "$TOTAL_SUPPLY" != "0" ]]; then
  ONE_SHARE=1000000
  ASSETS_PER_SHARE=$(vault_call "convertToAssets(uint256)(uint256)" "$ONE_SHARE")
  info "convertToAssets(1e6) = $ASSETS_PER_SHARE micro-USDC per share"
else
  info "No shares minted yet — share price N/A"
fi

echo ""
echo "--- Proxy / admin ---"
check_eq "ProxyAdmin.owner()" "$(admin_call 'owner()(address)')" "$OWNER"
check_eq "proxy implementation slot" "$(slot_to_address "$IMPL_SLOT")" "$IMPL"
check_eq "proxy admin slot" "$(slot_to_address "$ADMIN_SLOT")" "$ADMIN"

echo ""
echo "--- Summary ---"
echo -e "Passed: ${GREEN}$pass${NC}  Failed: ${RED}$fail${NC}  Warnings/info: $warn"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
