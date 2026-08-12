// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {PharaohLiquidityVault} from "../contracts/PharaohLiquidityVault.sol";

/// @notice Shared, pinned configuration for the reviewed Pharaoh v2 upgrade.
abstract contract PharaohUpgradeConfig is Script {
    uint256 internal constant AVALANCHE_CHAIN_ID = 43_114;

    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address internal constant LEGACY_IMPLEMENTATION = 0x3E931977EE59B23bD42F6b82b7Dc16128942A5a5;

    PharaohLiquidityVault internal constant USDC_VAULT =
        PharaohLiquidityVault(0x855bF832f26a294d28500db59eE941dE3d654129);
    ProxyAdmin internal constant USDC_PROXY_ADMIN = ProxyAdmin(0x2DD4191B2944396B5853f4219E829f01636F65cf);

    PharaohLiquidityVault internal constant WAVAX_VAULT =
        PharaohLiquidityVault(0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8);
    ProxyAdmin internal constant WAVAX_PROXY_ADMIN = ProxyAdmin(0x34CbBdfcBcc72e8bf70CbF6c7245fdb2725b94dC);

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    error Upgrade__WrongChain(uint256 actualChainId);
    error Upgrade__UnexpectedImplementation(address vault, address actualImplementation);
    error Upgrade__UnexpectedProxyAdmin(address vault, address actualAdmin);
    error Upgrade__UnexpectedOwner(address target, address actualOwner);
    error Upgrade__VaultNotPaused(address vault);
    error Upgrade__VaultNotEmpty(address vault, uint256 totalSupply, uint256 tokenId);
    error Upgrade__NoImplementationCode(address implementation);
    error Upgrade__WrongImplementationCode(address implementation, bytes32 expectedHash, bytes32 actualHash);

    struct UpgradeCalls {
        bytes usdcMigration;
        bytes usdcUpgrade;
        bytes wavaxMigration;
        bytes wavaxUpgrade;
    }

    function buildUpgradeCalls(address newImplementation) public pure returns (UpgradeCalls memory calls) {
        calls.usdcMigration =
            abi.encodeCall(PharaohLiquidityVault.initializeV2RiskParameters, (uint16(30), uint16(100), uint16(100)));
        calls.usdcUpgrade = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(payable(address(USDC_VAULT))), newImplementation, calls.usdcMigration)
        );

        calls.wavaxMigration =
            abi.encodeCall(PharaohLiquidityVault.initializeV2RiskParameters, (uint16(100), uint16(300), uint16(300)));
        calls.wavaxUpgrade = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(payable(address(WAVAX_VAULT))), newImplementation, calls.wavaxMigration)
        );
    }

    function _assertPreUpgradeState() internal view {
        if (block.chainid != AVALANCHE_CHAIN_ID) revert Upgrade__WrongChain(block.chainid);

        _assertVault(USDC_VAULT, USDC_PROXY_ADMIN);
        _assertVault(WAVAX_VAULT, WAVAX_PROXY_ADMIN);
    }

    function _assertVault(PharaohLiquidityVault vault, ProxyAdmin expectedAdmin) private view {
        address actualImplementation = _addressSlot(address(vault), ERC1967_IMPLEMENTATION_SLOT);
        if (actualImplementation != LEGACY_IMPLEMENTATION) {
            revert Upgrade__UnexpectedImplementation(address(vault), actualImplementation);
        }

        address actualAdmin = _addressSlot(address(vault), ERC1967_ADMIN_SLOT);
        if (actualAdmin != address(expectedAdmin)) revert Upgrade__UnexpectedProxyAdmin(address(vault), actualAdmin);

        address adminOwner = expectedAdmin.owner();
        if (adminOwner != SAFE) revert Upgrade__UnexpectedOwner(address(expectedAdmin), adminOwner);

        address vaultOwner = vault.owner();
        if (vaultOwner != SAFE) revert Upgrade__UnexpectedOwner(address(vault), vaultOwner);
        if (!vault.paused()) revert Upgrade__VaultNotPaused(address(vault));

        uint256 supply = vault.totalSupply();
        uint256 positionId = vault.tokenId();
        if (supply != 0 || positionId != 0) revert Upgrade__VaultNotEmpty(address(vault), supply, positionId);
    }

    function _assertImplementation(address implementation) internal view {
        if (implementation.code.length == 0) revert Upgrade__NoImplementationCode(implementation);

        bytes32 expectedHash = keccak256(type(PharaohLiquidityVault).runtimeCode);
        bytes32 actualHash = implementation.codehash;
        if (actualHash != expectedHash) {
            revert Upgrade__WrongImplementationCode(implementation, expectedHash, actualHash);
        }
    }

    function _logPackage(address implementation, UpgradeCalls memory calls) internal view {
        console2.log("Avalanche chain ID:", block.chainid);
        console2.log("Safe:", SAFE);
        console2.log("New PharaohLiquidityVault implementation:", implementation);
        console2.log("Implementation runtime codehash:");
        console2.logBytes32(implementation.codehash);

        console2.log("USDC ProxyAdmin target:", address(USDC_PROXY_ADMIN));
        console2.log("USDC proxy argument:", address(USDC_VAULT));
        console2.log("USDC initializeV2RiskParameters calldata:");
        console2.logBytes(calls.usdcMigration);
        console2.log("USDC ProxyAdmin.upgradeAndCall calldata:");
        console2.logBytes(calls.usdcUpgrade);

        console2.log("WAVAX ProxyAdmin target:", address(WAVAX_PROXY_ADMIN));
        console2.log("WAVAX proxy argument:", address(WAVAX_VAULT));
        console2.log("WAVAX initializeV2RiskParameters calldata:");
        console2.logBytes(calls.wavaxMigration);
        console2.log("WAVAX ProxyAdmin.upgradeAndCall calldata:");
        console2.logBytes(calls.wavaxUpgrade);

        console2.log("Every Safe call must use value 0 and CALL operation 0.");
    }

    function _addressSlot(address target, bytes32 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(target, slot))));
    }
}

/// @notice Deploys only the reviewed PharaohLiquidityVault implementation.
/// @dev This does not deploy replacement proxies or change either live vault.
contract DeployPharaohUpgrade is PharaohUpgradeConfig {
    function run() external returns (PharaohLiquidityVault implementation) {
        address deployer = vm.envAddress("DEPLOYER");
        _assertPreUpgradeState();

        vm.startBroadcast(deployer);
        implementation = new PharaohLiquidityVault();
        vm.stopBroadcast();

        _assertImplementation(address(implementation));
        _logPackage(address(implementation), buildUpgradeCalls(address(implementation)));
    }
}

/// @notice Recreates and validates the Safe payloads for an already deployed implementation.
contract PreparePharaohUpgrade is PharaohUpgradeConfig {
    function run() external view returns (UpgradeCalls memory calls) {
        address implementation = vm.envAddress("NEW_IMPLEMENTATION");
        _assertPreUpgradeState();
        _assertImplementation(implementation);

        calls = buildUpgradeCalls(implementation);
        _logPackage(implementation, calls);
    }
}
