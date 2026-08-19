#!/usr/bin/env bash
# Build a short-lived, checksummed Safe Transaction Builder batch for one
# Pharaoh vault reward cycle. The exact calls are fork-simulated before the
# JSON is written. Nothing is broadcast by this script.

set -euo pipefail

RPC="${RPC:-${AVAX_RPC:-${AVAX_MAINNET_RPC_URL:-https://api.avax.network/ext/bc/C/rpc}}}"
TARGET="${TARGET:-}"
readonly SAFE="0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12"
readonly COMPOUNDER="0xe7fCeE8d52B5340168eb33804c49BE086cE04cB0"
readonly EXPECTED_COMPOUNDER_CODEHASH="0xbdf6e858119981209156b7d7619201a9b8aed2c5ab6fb5d04611b60cfd89b1c5"
readonly PHAR="0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7"
readonly WAVAX="0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7"
readonly USDC="0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"
readonly SWAP_ROUTER="0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c"
readonly QUOTER="0xB7297301b7CC659BB96D51754643A0Df6eEA2138"
readonly FACTORY="0xAE6E5c62328ade73ceefD42228528b70c8157D0d"
readonly PHAR_WAVAX_POOL="0xb78DA03566B6537aCC22F6a4ba070AbCF6eDebF6"
readonly WAVAX_USDC_POOL="0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534"
readonly USDC_VAULT="0x855bF832f26a294d28500db59eE941dE3d654129"
readonly WAVAX_VAULT="0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8"
readonly USDC_PROXY_ADMIN="0x2DD4191B2944396B5853f4219E829f01636F65cf"
readonly WAVAX_PROXY_ADMIN="0x34CbBdfcBcc72e8bf70CbF6c7245fdb2725b94dC"
readonly CURRENT_IMPLEMENTATION="0x165E1f072e7bEeDf94f14F732838354cA20bA45d"
readonly CURRENT_IMPLEMENTATION_CODEHASH="0x4fa61d2d9ce0a7e8f1aebf96fd007fad0aa17f969be476eddd6d6f344fb22e4b"
readonly SWAP_ROUTER_CODEHASH="0xc73f3d2a21cdace7e104858002a8be4442e2dc9d234f39c3f01320a962219032"
readonly QUOTER_CODEHASH="0xf520476b52f99d9a1ff89c6187193eb240c6cb1d11d2e6466ebcbbdf7a753bd2"
readonly PHAR_WAVAX_POOL_CODEHASH="0x8574735b0859cec219b9019a9b80cae444288ef8b884ae74f7ca7d21b4244363"
readonly WAVAX_USDC_POOL_CODEHASH="0xc09ba0e43ec861307c9abaf85e482e9562c1fb0597d782070c93aa12ddfd9ac6"
readonly ERC1967_IMPLEMENTATION_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
readonly ERC1967_ADMIN_SLOT="0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"

# The first harvested Safe inventory was attributed by the two
# RewardsHarvested events in transaction 0x16c0...3e47. These exact amounts
# let the first generated cycle preserve the originating-vault attribution.
readonly HISTORICAL_USDC_PHAR="10884615830873552"
readonly HISTORICAL_WAVAX_PHAR="50490341236400479"
readonly HISTORICAL_TOTAL_PHAR="61374957067274031"

MIN_REWARD_VALUE_USDC_RAW="${MIN_REWARD_VALUE_USDC_RAW:-100000}"
SLIPPAGE_BPS="${SLIPPAGE_BPS:-500}"
DEADLINE_SECONDS="${DEADLINE_SECONDS:-1800}"
MAX_UINT256="115792089237316195423570985008687907853269984665640564039457584007913129639935"

for command in cast forge jq bc; do
  command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }
done

case "$TARGET" in
  usdc)
    TARGET_VAULT="$USDC_VAULT"
    TARGET_LABEL="USDC/USDt"
    ;;
  wavax)
    TARGET_VAULT="$WAVAX_VAULT"
    TARGET_LABEL="sAVAX/WAVAX"
    ;;
  *)
    echo "TARGET must be either usdc or wavax" >&2
    exit 1
    ;;
esac

if ! [[ "$MIN_REWARD_VALUE_USDC_RAW" =~ ^[0-9]+$ ]] || [[ "$MIN_REWARD_VALUE_USDC_RAW" == "0" ]]; then
  echo "MIN_REWARD_VALUE_USDC_RAW must be a positive integer" >&2
  exit 1
fi
if ! [[ "$SLIPPAGE_BPS" =~ ^[0-9]+$ ]] || (( SLIPPAGE_BPS == 0 || SLIPPAGE_BPS > 2000 )); then
  echo "SLIPPAGE_BPS must be between 1 and 2000" >&2
  exit 1
fi
if ! [[ "$DEADLINE_SECONDS" =~ ^[0-9]+$ ]] || (( DEADLINE_SECONDS < 300 || DEADLINE_SECONDS > 3600 )); then
  echo "DEADLINE_SECONDS must be between 300 and 3600" >&2
  exit 1
fi

normalize_num() {
  echo "$1" | awk '{print $1}'
}

lower() {
  tr '[:upper:]' '[:lower:]' <<< "$1"
}

require_equal() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$(lower "$actual")" != "$(lower "$expected")" ]]; then
    echo "$label mismatch: expected $expected, got $actual" >&2
    exit 1
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

token_balance() {
  normalize_num "$(cast call "$1" 'balanceOf(address)(uint256)' "$2" --rpc-url "$RPC" --block "$CURRENT_BLOCK")"
}

token_allowance() {
  normalize_num "$(cast call "$1" 'allowance(address,address)(uint256)' "$2" "$3" --rpc-url "$RPC" --block "$CURRENT_BLOCK")"
}

check_vault() {
  local label="$1"
  local vault="$2"
  local expected_asset="$3"
  local expected_admin="$4"

  require_equal "$label owner" \
    "$(cast call "$vault" 'owner()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$SAFE"
  require_equal "$label asset" \
    "$(cast call "$vault" 'asset()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$expected_asset"
  require_equal "$label router" \
    "$(cast call "$vault" 'swapRouter()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$SWAP_ROUTER"
  require_equal "$label paused state" \
    "$(cast call "$vault" 'paused()(bool)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "false"
  require_equal "$label closed cap" \
    "$(normalize_num "$(cast call "$vault" 'depositCap()(uint256)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")" "1"
  require_equal "$label implementation" \
    "$(storage_address "$vault" "$ERC1967_IMPLEMENTATION_SLOT")" "$CURRENT_IMPLEMENTATION"
  require_equal "$label ProxyAdmin" \
    "$(storage_address "$vault" "$ERC1967_ADMIN_SLOT")" "$expected_admin"
  require_equal "$label ProxyAdmin owner" \
    "$(cast call "$expected_admin" 'owner()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$SAFE"

  local supply safe_shares
  supply=$(normalize_num "$(cast call "$vault" 'totalSupply()(uint256)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  safe_shares=$(normalize_num "$(cast call "$vault" 'balanceOf(address)(uint256)' "$SAFE" --rpc-url "$RPC" --block "$CURRENT_BLOCK")")
  if [[ "$supply" == "0" || "$safe_shares" != "$supply" ]]; then
    echo "$label shares are not exclusively Safe-owned" >&2
    exit 1
  fi
  if [[ "$(normalize_num "$(cast call "$vault" 'tokenId()(uint256)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")" == "0" ]]; then
    echo "$label has no active Pharaoh position" >&2
    exit 1
  fi
  cast call "$vault" 'totalAssets()(uint256)' --rpc-url "$RPC" --block "$CURRENT_BLOCK" >/dev/null
}

check_pool() {
  local label="$1"
  local pool="$2"
  local expected_codehash="$3"
  local expected_token0="$4"
  local expected_token1="$5"
  local expected_spacing="$6"

  require_equal "$label codehash" "$(codehash_at_block "$pool")" "$expected_codehash"
  require_equal "$label token0" \
    "$(cast call "$pool" 'token0()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$expected_token0"
  require_equal "$label token1" \
    "$(cast call "$pool" 'token1()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$expected_token1"
  require_equal "$label spacing" \
    "$(normalize_num "$(cast call "$pool" 'tickSpacing()(int24)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")" \
    "$expected_spacing"
  if [[ "$(normalize_num "$(cast call "$pool" 'liquidity()(uint128)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")" == "0" ]]; then
    echo "$label has no active liquidity" >&2
    exit 1
  fi
}

quote_wavax_per_phar() {
  local output
  output=$(cast call \
    "$QUOTER" \
    'quoteExactInputSingle((address,address,uint256,int24,uint160))(uint256,uint160,uint32,uint256)' \
    "($PHAR,$WAVAX,1000000000000000000,5,0)" \
    --rpc-url "$RPC" \
    --block "$CURRENT_BLOCK")
  echo "$output" | sed -n '1p' | awk '{print $1}'
}

quote_usdc_per_phar() {
  quote_usdc_for_phar 1000000000000000000
}

quote_usdc_for_phar() {
  local phar_in="$1"
  local path="0x${PHAR#0x}000005${WAVAX#0x}00000a${USDC#0x}"
  local output
  output=$(cast call \
    "$QUOTER" \
    'quoteExactInput(bytes,uint256)(uint256,uint160[],uint32[],uint256)' \
    "$path" \
    "$phar_in" \
    --rpc-url "$RPC" \
    --block "$CURRENT_BLOCK")
  echo "$output" | sed -n '1p' | awk '{print $1}'
}

chain_id=$(normalize_num "$(cast chain-id --rpc-url "$RPC")")
if [[ "$chain_id" != "43114" ]]; then
  echo "wrong chain: expected 43114, got $chain_id" >&2
  exit 1
fi

CURRENT_BLOCK="${BLOCK:-$(cast block-number --rpc-url "$RPC")}"
if ! [[ "$CURRENT_BLOCK" =~ ^[0-9]+$ ]]; then
  echo "BLOCK must resolve to a decimal block number" >&2
  exit 1
fi
block_timestamp_raw=$(cast block "$CURRENT_BLOCK" --json --rpc-url "$RPC" | jq -r '.timestamp')
if [[ "$block_timestamp_raw" == 0x* ]]; then
  BLOCK_TIMESTAMP=$(cast to-dec "$block_timestamp_raw")
else
  BLOCK_TIMESTAMP="$block_timestamp_raw"
fi
if ! [[ "$BLOCK_TIMESTAMP" =~ ^[0-9]+$ ]]; then
  echo "block timestamp must resolve to a decimal integer" >&2
  exit 1
fi
DEADLINE=$((BLOCK_TIMESTAMP + DEADLINE_SECONDS))
CREATED_AT=$((BLOCK_TIMESTAMP * 1000))
OUTPUT="${OUTPUT:-/tmp/Pharaoh-${TARGET}-reward-cycle-43114-${CURRENT_BLOCK}.json}"
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
  echo "refusing to overwrite existing output: $OUTPUT" >&2
  exit 1
fi

require_equal "compounder codehash" "$(codehash_at_block "$COMPOUNDER")" "$EXPECTED_COMPOUNDER_CODEHASH"
require_equal "vault implementation codehash" \
  "$(codehash_at_block "$CURRENT_IMPLEMENTATION")" "$CURRENT_IMPLEMENTATION_CODEHASH"
require_equal "router codehash" "$(codehash_at_block "$SWAP_ROUTER")" "$SWAP_ROUTER_CODEHASH"
require_equal "quoter codehash" "$(codehash_at_block "$QUOTER")" "$QUOTER_CODEHASH"
require_equal "compounder Safe" \
  "$(cast call "$COMPOUNDER" 'safe()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$SAFE"
require_equal "compounder PHAR" \
  "$(cast call "$COMPOUNDER" 'phar()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$PHAR"
require_equal "compounder WAVAX" \
  "$(cast call "$COMPOUNDER" 'wavax()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$WAVAX"
require_equal "compounder USDC" \
  "$(cast call "$COMPOUNDER" 'usdc()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$USDC"
require_equal "compounder router" \
  "$(cast call "$COMPOUNDER" 'swapRouter()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$SWAP_ROUTER"
require_equal "compounder USDC vault" \
  "$(cast call "$COMPOUNDER" 'usdcVault()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$USDC_VAULT"
require_equal "compounder WAVAX vault" \
  "$(cast call "$COMPOUNDER" 'wavaxVault()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$WAVAX_VAULT"
require_equal "PHAR/WAVAX spacing" \
  "$(normalize_num "$(cast call "$COMPOUNDER" 'pharWavaxTickSpacing()(int24)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")" "5"
require_equal "WAVAX/USDC spacing" \
  "$(normalize_num "$(cast call "$COMPOUNDER" 'wavaxUsdcTickSpacing()(int24)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")")" "10"

require_equal "PHAR/WAVAX factory route" \
  "$(cast call "$FACTORY" 'getPool(address,address,int24)(address)' "$PHAR" "$WAVAX" 5 --rpc-url "$RPC" --block "$CURRENT_BLOCK")" \
  "$PHAR_WAVAX_POOL"
require_equal "WAVAX/USDC factory route" \
  "$(cast call "$FACTORY" 'getPool(address,address,int24)(address)' "$WAVAX" "$USDC" 10 --rpc-url "$RPC" --block "$CURRENT_BLOCK")" \
  "$WAVAX_USDC_POOL"
pool_deployer=$(cast call "$FACTORY" 'ramsesV3PoolDeployer()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")
require_equal "router deployer" \
  "$(cast call "$SWAP_ROUTER" 'deployer()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$pool_deployer"
require_equal "quoter deployer" \
  "$(cast call "$QUOTER" 'deployer()(address)' --rpc-url "$RPC" --block "$CURRENT_BLOCK")" "$pool_deployer"
check_pool "PHAR/WAVAX pool" "$PHAR_WAVAX_POOL" "$PHAR_WAVAX_POOL_CODEHASH" "$PHAR" "$WAVAX" "5"
check_pool "WAVAX/USDC pool" "$WAVAX_USDC_POOL" "$WAVAX_USDC_POOL_CODEHASH" "$WAVAX" "$USDC" "10"
check_vault "USDC vault" "$USDC_VAULT" "$USDC" "$USDC_PROXY_ADMIN"
check_vault "WAVAX vault" "$WAVAX_VAULT" "$WAVAX" "$WAVAX_PROXY_ADMIN"

for token in "$PHAR" "$WAVAX" "$USDC"; do
  balance=$(token_balance "$token" "$COMPOUNDER")
  if [[ "$balance" != "0" ]]; then
    echo "compounder holds token $token: $balance" >&2
    exit 1
  fi
done
safe_allowance=$(token_allowance "$PHAR" "$SAFE" "$COMPOUNDER")
router_allowance=$(token_allowance "$PHAR" "$COMPOUNDER" "$SWAP_ROUTER")
if [[ "$safe_allowance" != "0" || "$router_allowance" != "0" ]]; then
  echo "unexpected PHAR allowance: Safe=$safe_allowance router=$router_allowance" >&2
  exit 1
fi

wavax_rate=$(quote_wavax_per_phar)
usdc_rate=$(quote_usdc_per_phar)
if [[ "$wavax_rate" == "0" || "$usdc_rate" == "0" ]]; then
  echo "Pharaoh returned a zero quote" >&2
  exit 1
fi
minimum_wavax_rate=$(bc <<< "($wavax_rate * (10000 - $SLIPPAGE_BPS)) / 10000")
minimum_usdc_rate=$(bc <<< "($usdc_rate * (10000 - $SLIPPAGE_BPS)) / 10000")
minimum_fresh_phar=$(bc <<< "(($MIN_REWARD_VALUE_USDC_RAW * 1000000000000000000) + $usdc_rate - 1) / $usdc_rate")

pending_output=$(cast call \
  "$TARGET_VAULT" \
  'harvestRewards(bool,uint256)(uint256,uint256)' \
  true \
  0 \
  --from "$SAFE" \
  --rpc-url "$RPC" \
  --block "$CURRENT_BLOCK")
pending_phar=$(echo "$pending_output" | sed -n '1p' | awk '{print $1}')
if [[ "$pending_phar" == "0" ]]; then
  pending_value="0"
else
  pending_value=$(quote_usdc_for_phar "$pending_phar")
fi
if [[ "$(bc <<< "$pending_value < $MIN_REWARD_VALUE_USDC_RAW")" == "1" ]]; then
  echo "reward cycle is below the configured economic threshold" >&2
  echo "  target: $TARGET_LABEL" >&2
  echo "  estimated fresh PHAR: $pending_phar" >&2
  echo "  estimated value: $pending_value raw USDC" >&2
  echo "  required value: $MIN_REWARD_VALUE_USDC_RAW raw USDC" >&2
  exit 1
fi

safe_phar=$(token_balance "$PHAR" "$SAFE")
CARRY_VAULT="0x0000000000000000000000000000000000000000"
CARRY_PHAR_IN="0"
CARRY_MINIMUM_RATE="0"
TARGET_EXISTING_PHAR="0"

if [[ "$safe_phar" == "$HISTORICAL_TOTAL_PHAR" ]]; then
  if [[ "$TARGET" == "usdc" ]]; then
    CARRY_VAULT="$WAVAX_VAULT"
    CARRY_PHAR_IN="$HISTORICAL_WAVAX_PHAR"
    CARRY_MINIMUM_RATE="$minimum_wavax_rate"
    TARGET_EXISTING_PHAR="$HISTORICAL_USDC_PHAR"
  else
    CARRY_VAULT="$USDC_VAULT"
    CARRY_PHAR_IN="$HISTORICAL_USDC_PHAR"
    CARRY_MINIMUM_RATE="$minimum_usdc_rate"
    TARGET_EXISTING_PHAR="$HISTORICAL_WAVAX_PHAR"
  fi
elif [[ "$safe_phar" != "0" ]]; then
  echo "Safe holds unrelated or unexpected PHAR: $safe_phar" >&2
  echo "expected either zero or the attributed historical total $HISTORICAL_TOTAL_PHAR" >&2
  exit 1
fi

MINIMUM_PHAR_IN=$(bc <<< "$TARGET_EXISTING_PHAR + $minimum_fresh_phar")
if [[ "$TARGET" == "usdc" ]]; then
  MINIMUM_ASSET_OUT_PER_PHAR="$minimum_usdc_rate"
else
  MINIMUM_ASSET_OUT_PER_PHAR="$minimum_wavax_rate"
fi

echo "Fork-simulating the exact Safe call order at block $CURRENT_BLOCK..."
TARGET_VAULT="$TARGET_VAULT" \
EXPECTED_SAFE_PHAR="$safe_phar" \
MINIMUM_PHAR_IN="$MINIMUM_PHAR_IN" \
MINIMUM_ASSET_OUT_PER_PHAR="$MINIMUM_ASSET_OUT_PER_PHAR" \
DEADLINE="$DEADLINE" \
CARRY_VAULT="$CARRY_VAULT" \
CARRY_PHAR_IN="$CARRY_PHAR_IN" \
CARRY_MINIMUM_ASSET_OUT_PER_PHAR="$CARRY_MINIMUM_RATE" \
forge script \
  script/SimulatePharaohRewardCompound.s.sol:SimulatePharaohRewardCompound \
  --rpc-url "$RPC" \
  --fork-block-number "$CURRENT_BLOCK" \
  -vvv

approve_data=$(cast calldata 'approve(address,uint256)' "$COMPOUNDER" "$MAX_UINT256")
harvest_data=$(cast calldata 'harvestRewards(bool,uint256)' true 0)
compound_data=$(cast calldata \
  'compound(address,uint256,uint256,uint256,uint256)' \
  "$TARGET_VAULT" \
  "$MINIMUM_PHAR_IN" \
  "$MAX_UINT256" \
  "$MINIMUM_ASSET_OUT_PER_PHAR" \
  "$DEADLINE")
revoke_data=$(cast calldata 'approve(address,uint256)' "$COMPOUNDER" 0)
CARRY_DATA=""
if [[ "$CARRY_PHAR_IN" != "0" ]]; then
  CARRY_DATA=$(cast calldata \
    'compound(address,uint256,uint256,uint256,uint256)' \
    "$CARRY_VAULT" \
    "$CARRY_PHAR_IN" \
    "$CARRY_PHAR_IN" \
    "$CARRY_MINIMUM_RATE" \
    "$DEADLINE")
fi

description="Fresh-quote Pharaoh $TARGET_LABEL reward cycle prepared at block $CURRENT_BLOCK. The batch grants a temporary PHAR allowance, preserves any attributed historical carry, harvests liquid PHAR while retaining xPHAR, compounds through the pinned Pharaoh route into the originating vault, and revokes the allowance. Minimum fresh reward value is $MIN_REWARD_VALUE_USDC_RAW raw USDC, slippage is $SLIPPAGE_BPS bps, and deadline is $DEADLINE. Every call uses native value zero and CALL operation. Exact call order passed a finalized-block fork simulation before this file was written."

output_dir=$(dirname "$OUTPUT")
mkdir -p "$output_dir"
tmp_file=$(mktemp "$output_dir/.pharaoh-reward-batch.XXXXXX")
final_file=$(mktemp "$output_dir/.pharaoh-reward-batch-final.XXXXXX")
trap 'rm -f "$tmp_file" "$final_file"' EXIT

jq -n \
  --arg chainId "43114" \
  --argjson createdAt "$CREATED_AT" \
  --arg name "Pharaoh $TARGET_LABEL reward compound" \
  --arg description "$description" \
  --arg safe "$SAFE" \
  --arg phar "$PHAR" \
  --arg compounder "$COMPOUNDER" \
  --arg targetVault "$TARGET_VAULT" \
  --arg approveData "$approve_data" \
  --arg carryData "$CARRY_DATA" \
  --arg harvestData "$harvest_data" \
  --arg compoundData "$compound_data" \
  --arg revokeData "$revoke_data" \
  '{
    version: "1.0",
    chainId: $chainId,
    createdAt: $createdAt,
    meta: {
      name: $name,
      description: $description,
      txBuilderVersion: "2.0.1",
      createdFromSafeAddress: $safe,
      createdFromOwnerAddress: "",
      checksum: ""
    },
    transactions: (
      [{to: $phar, value: "0", data: $approveData}]
      + (if $carryData == "" then [] else [{to: $compounder, value: "0", data: $carryData}] end)
      + [
          {to: $targetVault, value: "0", data: $harvestData},
          {to: $compounder, value: "0", data: $compoundData},
          {to: $phar, value: "0", data: $revokeData}
        ]
    )
  }' > "$tmp_file"

serialize_filter='def serialize:
  . as $v |
  if type == "array" then
    "[" + (map(serialize) | join(",")) + "]"
  elif type == "object" then
    ($v | keys | sort) as $keys |
    "{" + ($keys | tojson) + ($keys | map(($v[.] | serialize) + ",") | join("")) + "}"
  else
    tojson
  end;
  (.meta |= (del(.checksum) | .name = null)) | serialize'

checksum=$(jq -j "$serialize_filter" "$tmp_file" | cast keccak)
jq --arg checksum "$checksum" '.meta.checksum = $checksum' "$tmp_file" > "$final_file"

actual_checksum=$(jq -j "$serialize_filter" "$final_file" | cast keccak)
if [[ "$actual_checksum" != "$checksum" ]]; then
  echo "generated Safe checksum mismatch" >&2
  exit 1
fi

# Hard-linking a temporary file in the destination directory is atomic and
# refuses an existing path, including one created after the early guard.
ln "$final_file" "$OUTPUT"

echo "Prepared checksummed Safe batch: $OUTPUT"
echo "Target vault:                  $TARGET_VAULT"
echo "Estimated fresh PHAR:          $pending_phar"
echo "Minimum PHAR accepted:         $MINIMUM_PHAR_IN"
echo "Minimum asset/PHAR rate:       $MINIMUM_ASSET_OUT_PER_PHAR"
echo "Deadline:                      $DEADLINE"
echo "Safe checksum:                 $checksum"
if [[ "$CARRY_PHAR_IN" != "0" ]]; then
  echo "Historical carry PHAR:         $CARRY_PHAR_IN -> $CARRY_VAULT"
fi
echo "Import and execute before the deadline only after reviewing every decoded call."
