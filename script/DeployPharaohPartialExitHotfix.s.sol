// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {PharaohLiquidityVault} from "../contracts/PharaohLiquidityVault.sol";

/// @notice Pinned configuration for replacing Pharaoh's unusable exact-output
///         partial-exit route with its deployed exact-input route.
abstract contract PharaohPartialExitHotfixConfig is Script {
    uint256 internal constant AVALANCHE_CHAIN_ID = 43_114;

    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address internal constant CURRENT_IMPLEMENTATION = 0x87C2C3bE37B2D71Ca85D2D950F0eed4532410CEa;

    PharaohLiquidityVault internal constant USDC_VAULT =
        PharaohLiquidityVault(0x855bF832f26a294d28500db59eE941dE3d654129);
    ProxyAdmin internal constant USDC_PROXY_ADMIN = ProxyAdmin(0x2DD4191B2944396B5853f4219E829f01636F65cf);

    PharaohLiquidityVault internal constant WAVAX_VAULT =
        PharaohLiquidityVault(0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8);
    ProxyAdmin internal constant WAVAX_PROXY_ADMIN = ProxyAdmin(0x34CbBdfcBcc72e8bf70CbF6c7245fdb2725b94dC);

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    error Hotfix__WrongChain(uint256 actualChainId);
    error Hotfix__UnexpectedImplementation(address vault, address actualImplementation);
    error Hotfix__UnexpectedProxyAdmin(address vault, address actualAdmin);
    error Hotfix__UnexpectedOwner(address target, address actualOwner);
    error Hotfix__UnexpectedLiveState(address vault);
    error Hotfix__UnexpectedRiskParameters(address vault);
    error Hotfix__NoImplementationCode(address implementation);
    error Hotfix__WrongImplementationCode(address implementation, bytes32 expectedHash, bytes32 actualHash);

    struct UpgradeCalls {
        bytes usdcUpgrade;
        bytes wavaxUpgrade;
    }

    function buildUpgradeCalls(address newImplementation) public pure returns (UpgradeCalls memory calls) {
        calls.usdcUpgrade = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(payable(address(USDC_VAULT))), newImplementation, bytes(""))
        );
        calls.wavaxUpgrade = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(payable(address(WAVAX_VAULT))), newImplementation, bytes(""))
        );
    }

    function _assertPreUpgradeState() internal view {
        if (block.chainid != AVALANCHE_CHAIN_ID) revert Hotfix__WrongChain(block.chainid);

        _assertVault(USDC_VAULT, USDC_PROXY_ADMIN, 30, 100, 100);
        _assertVault(WAVAX_VAULT, WAVAX_PROXY_ADMIN, 100, 300, 300);
    }

    function _assertVault(
        PharaohLiquidityVault vault,
        ProxyAdmin expectedAdmin,
        uint16 expectedOracleDeviation,
        uint16 expectedSlippage,
        uint16 expectedHaircut
    ) private view {
        address actualImplementation = _addressSlot(address(vault), ERC1967_IMPLEMENTATION_SLOT);
        if (actualImplementation != CURRENT_IMPLEMENTATION) {
            revert Hotfix__UnexpectedImplementation(address(vault), actualImplementation);
        }

        address actualAdmin = _addressSlot(address(vault), ERC1967_ADMIN_SLOT);
        if (actualAdmin != address(expectedAdmin)) {
            revert Hotfix__UnexpectedProxyAdmin(address(vault), actualAdmin);
        }
        if (expectedAdmin.owner() != SAFE) {
            revert Hotfix__UnexpectedOwner(address(expectedAdmin), expectedAdmin.owner());
        }
        if (vault.owner() != SAFE) revert Hotfix__UnexpectedOwner(address(vault), vault.owner());

        if (
            vault.paused() || vault.depositCap() != 1 || vault.totalSupply() == 0 || vault.tokenId() == 0
                || vault.balanceOf(SAFE) != vault.totalSupply()
                || IERC20(vault.asset()).allowance(SAFE, address(vault)) != 0
        ) revert Hotfix__UnexpectedLiveState(address(vault));

        if (
            vault.maxOracleDeviationBps() != expectedOracleDeviation || vault.slippageBps() != expectedSlippage
                || vault.valuationHaircutBps() != expectedHaircut
        ) revert Hotfix__UnexpectedRiskParameters(address(vault));
    }

    function _assertImplementation(address implementation) internal view {
        if (implementation.code.length == 0) revert Hotfix__NoImplementationCode(implementation);

        bytes32 expectedHash = keccak256(type(PharaohLiquidityVault).runtimeCode);
        bytes32 actualHash = implementation.codehash;
        if (actualHash != expectedHash) {
            revert Hotfix__WrongImplementationCode(implementation, expectedHash, actualHash);
        }
    }

    function _logPackage(address implementation, UpgradeCalls memory calls) internal view {
        console2.log("Avalanche chain ID:", block.chainid);
        console2.log("Safe:", SAFE);
        console2.log("Current Pharaoh implementation:", CURRENT_IMPLEMENTATION);
        console2.log("New partial-exit implementation:", implementation);
        console2.log("Implementation runtime codehash:");
        console2.logBytes32(implementation.codehash);

        console2.log("USDC ProxyAdmin target:", address(USDC_PROXY_ADMIN));
        console2.log("USDC proxy argument:", address(USDC_VAULT));
        console2.log("USDC ProxyAdmin.upgradeAndCall calldata (empty migration):");
        console2.logBytes(calls.usdcUpgrade);

        console2.log("WAVAX ProxyAdmin target:", address(WAVAX_PROXY_ADMIN));
        console2.log("WAVAX proxy argument:", address(WAVAX_VAULT));
        console2.log("WAVAX ProxyAdmin.upgradeAndCall calldata (empty migration):");
        console2.logBytes(calls.wavaxUpgrade);

        console2.log("Every Safe call must use value 0 and CALL operation 0.");
    }

    function _addressSlot(address target, bytes32 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(target, slot))));
    }
}

/// @notice Deploys only the reviewed partial-exit implementation.
/// @dev This does not change either live proxy or its active position.
contract DeployPharaohPartialExitHotfix is PharaohPartialExitHotfixConfig {
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

/// @notice Recreates and validates both Safe calls for a deployed hotfix.
contract PreparePharaohPartialExitHotfix is PharaohPartialExitHotfixConfig {
    function run() external view returns (UpgradeCalls memory calls) {
        address implementation = vm.envAddress("NEW_IMPLEMENTATION");
        _assertPreUpgradeState();
        _assertImplementation(implementation);

        calls = buildUpgradeCalls(implementation);
        _logPackage(implementation, calls);
    }
}
