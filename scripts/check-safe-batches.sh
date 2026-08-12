#!/usr/bin/env bash
# Validate every retained Safe Transaction Builder file against Safe's canonical
# sorted-key Keccak checksum algorithm.

set -euo pipefail

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v cast >/dev/null || { echo "cast is required" >&2; exit 1; }

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

status=0
for path in safe/*.json; do
  expected=$(jq -r '.meta.checksum' "$path")
  actual=$(jq -j "$serialize_filter" "$path" | cast keccak)
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL $path"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    status=1
  else
    echo "OK   $path"
  fi
done

exit "$status"
