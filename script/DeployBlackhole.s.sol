// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2}        from "forge-std/Script.sol";
import {IERC20}                  from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BlackholeStableVault}    from "../contracts/BlackholeStableVault.sol";
import {IBlackholeRouter}        from "../contracts/interfaces/IBlackholeRouter.sol";
import {IBlackholePair}          from "../contracts/interfaces/IBlackholePair.sol";

/// @notice Deploy BlackholeStableVault.
///
///  Avalanche mainnet (once Blackhole contract addresses are known):
///    forge script script/DeployBlackhole.s.sol:DeployBlackholeMainnet \
///      --rpc-url avax --broadcast --verify \
///      --private-key $PRIVATE_KEY
///
///  How to find Blackhole addresses (they are not publicly documented):
///    A) Snowscan name-tag search: https://snowscan.xyz → search "Blackhole"
///    B) Trace a recent Blackhole swap on Snowscan → follow internal calls to RouterV2
///    C) Contact: kenneth [at] blackhole.xyz / discord.gg/blackholedex
///    D) Ask Joey/Matt at Avalanche Foundation — they have the relationship
///
///  After finding, verify:
///    - router.addLiquidity(...) exists with the expected signature
///    - router.getAmountOut(...) exists
///    - pair = factory.getPair(USDC, EURC, true) returns non-zero
///    - pair.stable() == true
///    - pair.symbol() contains "sAMM"

contract DeployBlackholeMainnet is Script {

    // ── Avalanche C-Chain token addresses (verified) ─────────────────────────
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E; // 6 dec
    address constant EURC = 0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD; // 6 dec

    // ── TODO: fill these before deploying ────────────────────────────────────
    address constant BLACKHOLE_ROUTER   = address(0); // PLACEHOLDER
    address constant EURC_USDC_PAIR     = address(0); // PLACEHOLDER — stable=true sAMM

    function run() external {
        require(BLACKHOLE_ROUTER != address(0), "set BLACKHOLE_ROUTER");
        require(EURC_USDC_PAIR   != address(0), "set EURC_USDC_PAIR");

        address deployer = vm.envAddress("DEPLOYER");

        vm.startBroadcast();

        BlackholeStableVault vault = new BlackholeStableVault(
            IERC20(USDC),
            IERC20(EURC),
            IBlackholeRouter(BLACKHOLE_ROUTER),
            IBlackholePair(EURC_USDC_PAIR)
        );

        // Conservative launch settings
        vault.setDepositCap(500_000e6); // 500k USDC
        vault.setSlippage(30);           // 0.3%

        vm.stopBroadcast();

        console2.log("BlackholeStableVault (Mainnet):", address(vault));
        console2.log("  USDC:   ", address(vault.USDC()));
        console2.log("  EURC:   ", address(vault.EURC()));
        console2.log("  router: ", address(vault.router()));
        console2.log("  pair:   ", address(vault.pair()));
    }
}
