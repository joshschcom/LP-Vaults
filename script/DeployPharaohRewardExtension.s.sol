// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {PharaohLiquidityVault} from "../contracts/PharaohLiquidityVault.sol";
import {PharaohRewardExtension} from "../contracts/PharaohRewardExtension.sol";

/// @notice Pinned deployment and Safe payload preparation for the reward
///         extension layered over the live partial-exit implementation.
abstract contract PharaohRewardExtensionConfig is Script {
    uint256 internal constant AVALANCHE_CHAIN_ID = 43_114;

    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address internal constant KEEPER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address internal constant CURRENT_IMPLEMENTATION = 0x37E28a2C9FA3bBdab81efA69D5D480f5107a3770;
    bytes32 internal constant CURRENT_IMPLEMENTATION_CODEHASH =
        0x416f2a818693b20948fc44e9955ec7a370be051599b1eef6ca1fad932f3626ef;

    address internal constant POSITION_MANAGER = 0x0B4478e810D48B5882D4019D435A2f864Bab4F39;
    address internal constant SWAP_ROUTER = 0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c;
    IERC20 internal constant PHAR = IERC20(0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7);
    IERC20 internal constant XPHAR = IERC20(0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A);

    PharaohLiquidityVault internal constant USDC_VAULT =
        PharaohLiquidityVault(0x855bF832f26a294d28500db59eE941dE3d654129);
    ProxyAdmin internal constant USDC_PROXY_ADMIN = ProxyAdmin(0x2DD4191B2944396B5853f4219E829f01636F65cf);
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address internal constant USDC_POOL = 0x9bFE3108Cc16D17a9Ec65545a0f50B2CA1C970c0;
    address internal constant USDC_ORACLE = 0xe6060635dfdDd495ca22b828e144AB8411c8a431;

    PharaohLiquidityVault internal constant WAVAX_VAULT =
        PharaohLiquidityVault(0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8);
    ProxyAdmin internal constant WAVAX_PROXY_ADMIN = ProxyAdmin(0x34CbBdfcBcc72e8bf70CbF6c7245fdb2725b94dC);
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant SAVAX = 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE;
    address internal constant WAVAX_POOL = 0x65B9016c376604Fe0aF38c1E336Ffcec0F8ecBbD;
    address internal constant WAVAX_ORACLE = 0x2002aFd6C713a6075d66DaE758Dc466787faCeEF;

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    error RewardUpgrade__WrongChain(uint256 actualChainId);
    error RewardUpgrade__UnexpectedImplementation(address vault, address actualImplementation);
    error RewardUpgrade__UnexpectedProxyAdmin(address vault, address actualAdmin);
    error RewardUpgrade__UnexpectedOwner(address target, address actualOwner);
    error RewardUpgrade__UnexpectedConfiguration(address vault);
    error RewardUpgrade__UnexpectedLiveState(address vault);
    error RewardUpgrade__MissingCode(address target);
    error RewardUpgrade__WrongCodehash(address target, bytes32 expected, bytes32 actual);

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
        if (block.chainid != AVALANCHE_CHAIN_ID) revert RewardUpgrade__WrongChain(block.chainid);
        _assertCodehash(CURRENT_IMPLEMENTATION, CURRENT_IMPLEMENTATION_CODEHASH);
        if (address(PHAR).code.length == 0) revert RewardUpgrade__MissingCode(address(PHAR));
        if (address(XPHAR).code.length == 0) revert RewardUpgrade__MissingCode(address(XPHAR));

        _assertVault(USDC_VAULT, USDC_PROXY_ADMIN, USDC, USDT, USDC_POOL, USDC_ORACLE, 100, 30, 30, 100, 100);
        _assertVault(WAVAX_VAULT, WAVAX_PROXY_ADMIN, WAVAX, SAVAX, WAVAX_POOL, WAVAX_ORACLE, 600, 100, 100, 300, 300);
    }

    function _assertVault(
        PharaohLiquidityVault vault,
        ProxyAdmin expectedAdmin,
        address expectedAsset,
        address expectedPair,
        address expectedPool,
        address expectedOracle,
        int24 expectedRange,
        uint24 expectedTwapDeviation,
        uint16 expectedOracleDeviation,
        uint16 expectedSlippage,
        uint16 expectedHaircut
    ) private view {
        address actualImplementation = _addressSlot(address(vault), ERC1967_IMPLEMENTATION_SLOT);
        if (actualImplementation != CURRENT_IMPLEMENTATION) {
            revert RewardUpgrade__UnexpectedImplementation(address(vault), actualImplementation);
        }

        address actualAdmin = _addressSlot(address(vault), ERC1967_ADMIN_SLOT);
        if (actualAdmin != address(expectedAdmin)) {
            revert RewardUpgrade__UnexpectedProxyAdmin(address(vault), actualAdmin);
        }
        if (expectedAdmin.owner() != SAFE) {
            revert RewardUpgrade__UnexpectedOwner(address(expectedAdmin), expectedAdmin.owner());
        }
        if (vault.owner() != SAFE) revert RewardUpgrade__UnexpectedOwner(address(vault), vault.owner());

        uint256 positionId = vault.tokenId();
        uint256 supply = vault.totalSupply();
        if (
            vault.paused() || vault.depositCap() != 1 || supply == 0 || positionId == 0
                || vault.balanceOf(SAFE) != supply || IERC20(vault.asset()).allowance(SAFE, address(vault)) != 0
                || vault.positionManager().ownerOf(positionId) != address(vault)
        ) revert RewardUpgrade__UnexpectedLiveState(address(vault));

        if (
            vault.asset() != expectedAsset || address(vault.pairedToken()) != expectedPair
                || address(vault.pool()) != expectedPool || address(vault.priceOracle()) != expectedOracle
                || address(vault.positionManager()) != POSITION_MANAGER || address(vault.swapRouter()) != SWAP_ROUTER
                || vault.rebalancer() != KEEPER || vault.tickRange() != expectedRange
                || vault.twapPeriod() != 30 minutes || vault.maxTwapDeviationTicks() != expectedTwapDeviation
                || vault.maxOracleDeviationBps() != expectedOracleDeviation || vault.slippageBps() != expectedSlippage
                || vault.valuationHaircutBps() != expectedHaircut
        ) revert RewardUpgrade__UnexpectedConfiguration(address(vault));

        vault.totalAssets();
    }

    function _assertExtension(address extension) internal view {
        if (extension.code.length == 0) revert RewardUpgrade__MissingCode(extension);
        _assertCodehash(extension, keccak256(type(PharaohRewardExtension).runtimeCode));
    }

    function _logPackage(address extension, UpgradeCalls memory calls) internal view {
        console2.log("Avalanche chain ID:", block.chainid);
        console2.log("Safe:", SAFE);
        console2.log("Delegated base implementation:", CURRENT_IMPLEMENTATION);
        console2.log("New PharaohRewardExtension:", extension);
        console2.log("Extension runtime codehash:");
        console2.logBytes32(extension.codehash);

        console2.log("USDC vault PHAR balance:", PHAR.balanceOf(address(USDC_VAULT)));
        console2.log("USDC vault xPHAR balance:", XPHAR.balanceOf(address(USDC_VAULT)));
        console2.log("USDC ProxyAdmin target:", address(USDC_PROXY_ADMIN));
        console2.log("USDC proxy argument:", address(USDC_VAULT));
        console2.log("USDC ProxyAdmin.upgradeAndCall calldata (empty migration):");
        console2.logBytes(calls.usdcUpgrade);

        console2.log("WAVAX vault PHAR balance:", PHAR.balanceOf(address(WAVAX_VAULT)));
        console2.log("WAVAX vault xPHAR balance:", XPHAR.balanceOf(address(WAVAX_VAULT)));
        console2.log("WAVAX ProxyAdmin target:", address(WAVAX_PROXY_ADMIN));
        console2.log("WAVAX proxy argument:", address(WAVAX_VAULT));
        console2.log("WAVAX ProxyAdmin.upgradeAndCall calldata (empty migration):");
        console2.logBytes(calls.wavaxUpgrade);
        console2.log("Execute both Safe calls atomically with value 0 and CALL operation 0.");
    }

    function _assertCodehash(address target, bytes32 expected) private view {
        bytes32 actual = target.codehash;
        if (actual != expected) revert RewardUpgrade__WrongCodehash(target, expected, actual);
    }

    function _addressSlot(address target, bytes32 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(target, slot))));
    }
}

/// @notice Deploys only the reward extension; it does not modify either proxy.
contract DeployPharaohRewardExtension is PharaohRewardExtensionConfig {
    function run() external returns (PharaohRewardExtension extension) {
        address deployer = vm.envAddress("DEPLOYER");
        _assertPreUpgradeState();

        vm.startBroadcast(deployer);
        extension = new PharaohRewardExtension();
        vm.stopBroadcast();

        _assertExtension(address(extension));
        _logPackage(address(extension), buildUpgradeCalls(address(extension)));
    }
}

/// @notice Recreates and validates both Safe calls for a deployed extension.
contract PreparePharaohRewardExtension is PharaohRewardExtensionConfig {
    function run() external view returns (UpgradeCalls memory calls) {
        address extension = vm.envAddress("NEW_IMPLEMENTATION");
        _assertPreUpgradeState();
        _assertExtension(extension);

        calls = buildUpgradeCalls(extension);
        _logPackage(extension, calls);
    }
}
