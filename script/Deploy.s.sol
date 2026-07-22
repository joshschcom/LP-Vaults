// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20}           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {LFJStableVault}   from "../contracts/LFJStableVault.sol";
import {ILBRouter}        from "../contracts/interfaces/ILBRouter.sol";
import {ILBPair}          from "../contracts/interfaces/ILBPair.sol";

/// @notice Deploy LFJStableVault.
///
///  Fuji testnet (no AUSD — use USDC/USDT pair as proxy):
///    forge script script/Deploy.s.sol:DeployFuji \
///      --rpc-url fuji --broadcast --verify \
///      --private-key $PRIVATE_KEY
///
///  Avalanche mainnet:
///    forge script script/Deploy.s.sol:DeployMainnet \
///      --rpc-url avax --broadcast --verify \
///      --private-key $PRIVATE_KEY

abstract contract DeployLFJBase is Script {
    bytes32 internal constant ERC1967_ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function _proxyAdmin(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_ADMIN_SLOT))));
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Fuji
// ═══════════════════════════════════════════════════════════════════════════
contract DeployFuji is DeployLFJBase {

    // V2.2 — same addresses as mainnet (verified from LFJ docs)
    address constant LB_ROUTER = 0x18556DA13313f3532c54711497A8FedAC273220E;

    // LFJ Fuji test tokens (do NOT use Avalanche Foundation faucet tokens)
    address constant USDC = 0xB6076C93701D6a07266c31066B298AeC6dd65c2d;
    address constant USDT = 0xAb231A5744C8E6c45481754928cCfFFFD4aa0732;

    // V2.1 USDC/USDT 1bps pair — best stable proxy on Fuji
    // Note: this is a V2.1 pair but the V2.2 router supports it via Version.V2_1
    // For a true V2.2 test, create a new pair via LBFactory V2.2 first
    address constant USDC_USDT_PAIR = 0x5091b52d5a2f2dFd5b29B103481d6cAc1Be1eB07;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        address multisig = vm.envOr("MULTISIG", deployer);
        address keeper   = vm.envOr("KEEPER", deployer);

        vm.startBroadcast();

        LFJStableVault implementation = new LFJStableVault();
        bytes memory initData = abi.encodeCall(
            LFJStableVault.initialize,
            (
                IERC20(USDC), // ERC-4626 asset
                IERC20(USDC),
                IERC20(USDT),
                ILBRouter(LB_ROUTER),
                ILBPair(USDC_USDT_PAIR),
                ILBRouter.Version.V2_1, // Fuji proxy pair is V2.1
                keeper,
                multisig,
                50_000e6,
                2,
                50
            )
        );

        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), multisig, initData);
        LFJStableVault vault = LFJStableVault(address(proxy));

        vm.stopBroadcast();

        console2.log("LFJStableVault implementation (Fuji):", address(implementation));
        console2.log("LFJStableVault proxy (Fuji):", address(vault));
        console2.log("  proxyAdmin: ", _proxyAdmin(address(proxy)));
        console2.log("  owner:      ", vault.owner());
        console2.log("  asset:      ", vault.asset());
        console2.log("  tokenX:     ", address(vault.tokenX()));
        console2.log("  tokenY:     ", address(vault.tokenY()));
        console2.log("  binStep:    ", vault.BIN_STEP());
        console2.log("  rebalancer: ", vault.rebalancer());
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Avalanche Mainnet
// ═══════════════════════════════════════════════════════════════════════════
contract DeployMainnet is DeployLFJBase {

    // V2.2 mainnet (from LFJ docs)
    address constant LB_ROUTER = 0x18556DA13313f3532c54711497A8FedAC273220E;

    // Avalanche C-Chain token addresses
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E; // USDC (6 dec)
    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a; // Agora AUSD (6 dec)

    // LFJ V2.2 AUSD/USDC 1bps pair. Pair order is tokenX=AUSD, tokenY=USDC.
    address constant AUSD_USDC_PAIR = 0x8573F98175D816d520248B5fACF40D309B1c9ceE;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        address multisig = vm.envOr("MULTISIG", deployer);
        address keeper   = vm.envOr("KEEPER", deployer);

        vm.startBroadcast();

        LFJStableVault implementation = new LFJStableVault();
        bytes memory initData = abi.encodeCall(
            LFJStableVault.initialize,
            (
                IERC20(USDC), // ERC-4626 asset; USDC is tokenY in the live LFJ pair
                IERC20(AUSD),
                IERC20(USDC),
                ILBRouter(LB_ROUTER),
                ILBPair(AUSD_USDC_PAIR),
                ILBRouter.Version.V2_2, // mainnet USDC/AUSD pair is V2.2
                keeper,
                multisig,
                500_000e6,
                2,
                30
            )
        );

        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), multisig, initData);
        LFJStableVault vault = LFJStableVault(address(proxy));

        vm.stopBroadcast();

        console2.log("LFJStableVault implementation (Mainnet):", address(implementation));
        console2.log("LFJStableVault proxy (Mainnet):", address(vault));
        console2.log("  proxyAdmin: ", _proxyAdmin(address(proxy)));
        console2.log("  owner:      ", vault.owner());
        console2.log("  asset:      ", vault.asset());
        console2.log("  tokenX:     ", address(vault.tokenX()));
        console2.log("  tokenY:     ", address(vault.tokenY()));
    }
}
