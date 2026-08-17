# Pharaoh Safe batches

All JSON files target Avalanche C-Chain (`43114`) and Safe
`0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12`. Validate their canonical Safe
checksums with `make check-pharaoh-safe-batches` before import.

- `Pharaoh-v2-upgrade-43114.json` and both canary files are retained historical
  execution artifacts.
- Both `stage` files are post-upgrade ready after the finalized-block fork
  passed 13/13 at block `92637472`, with the smaller amounts tested against live
  state. Do not execute either file until the Safe holds that file's exact
  staged asset amount: 20 USDC or 0.75 WAVAX, respectively.
- `Pharaoh-partial-exit-hotfix-43114.json` atomically upgrades both proxies to
  verified implementation `0x37E28a2C9FA3bBdab81efA69D5D480f5107a3770`.
  Its two `ProxyAdmin.upgradeAndCall(proxy, implementation, 0x)` calls must
  both use native value zero. This historical batch executed successfully in
  transaction `0xb07fd420d0b94a278b84fa16b3a54914dd4714360ab63c7fdb50bf6411a555c3`.

Transaction Builder files are an aid, not authorization. Verify the network,
Safe, complete target addresses, decoded functions, arguments, call order, and
native values in the Safe web interface before signing.
