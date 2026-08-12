# Pharaoh Safe batches

All JSON files target Avalanche C-Chain (`43114`) and Safe
`0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12`. Validate their canonical Safe
checksums with `make check-pharaoh-safe-batches` before import.

- `Pharaoh-v2-upgrade-43114.json` and both canary files are retained historical
  execution artifacts.
- Both `stage` files are deliberately marked **BLOCKED**. Do not execute them
  until the partial-exit candidate has passed the final external scans, its
  implementation has been deployed and verified, both proxies have been
  upgraded by the Safe, and a fresh finalized-block fork test passes.
- The partial-exit upgrade file cannot be created safely before the final
  implementation address exists. Generate and validate its two
  `ProxyAdmin.upgradeAndCall(proxy, implementation, 0x)` calls with
  `make prepare-pharaoh-hotfix` after deployment. Every call must use native
  value zero.

Transaction Builder files are an aid, not authorization. Verify the network,
Safe, complete target addresses, decoded functions, arguments, call order, and
native values in the Safe web interface before signing.
