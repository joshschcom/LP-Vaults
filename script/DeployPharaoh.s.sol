// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {PharaohLiquidityVault} from "../contracts/PharaohLiquidityVault.sol";
import {IPharaohFactory} from "../contracts/interfaces/pharaoh/IPharaohFactory.sol";
import {IPharaohPool} from "../contracts/interfaces/pharaoh/IPharaohPool.sol";
import {IPharaohPositionManager} from "../contracts/interfaces/pharaoh/IPharaohPositionManager.sol";
import {IPharaohSwapRouter} from "../contracts/interfaces/pharaoh/IPharaohSwapRouter.sol";
import {ISAVAX} from "../contracts/interfaces/ISAVAX.sol";
import {ChainlinkRatioOracle} from "../contracts/oracles/ChainlinkRatioOracle.sol";
import {SAVAXRateOracle} from "../contracts/oracles/SAVAXRateOracle.sol";

/// @notice Deploys the two selected Avalanche vaults:
///         - Pharaoh USDt/USDC, denominated in USDC
///         - Pharaoh sAVAX/WAVAX, denominated in WAVAX
///
/// Required:
///   DEPLOYER=<broadcasting address>
///
/// Optional:
///   MULTISIG=<owner and proxy-admin owner> (defaults to DEPLOYER)
///   KEEPER=<rebalancer>                 (defaults to DEPLOYER)
///   USDC_DEPOSIT_CAP=<raw USDC units>   (defaults to 250,000e6)
///   WAVAX_DEPOSIT_CAP=<raw WAVAX units> (defaults to 500e18)
///
/// Run:
///   forge script script/DeployPharaoh.s.sol:DeployPharaoh \
///     --rpc-url avax --broadcast --verify
contract DeployPharaoh is Script {
    bytes32 private constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    IPharaohFactory private constant FACTORY = IPharaohFactory(0xAE6E5c62328ade73ceefD42228528b70c8157D0d);
    IPharaohPositionManager private constant POSITION_MANAGER =
        IPharaohPositionManager(0x0B4478e810D48B5882D4019D435A2f864Bab4F39);
    IPharaohSwapRouter private constant SWAP_ROUTER = IPharaohSwapRouter(0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c);

    IERC20 private constant USDT = IERC20(0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7);
    IERC20 private constant USDC = IERC20(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    IPharaohPool private constant USDT_USDC_POOL = IPharaohPool(0x9bFE3108Cc16D17a9Ec65545a0f50B2CA1C970c0);

    AggregatorV3Interface private constant USDC_USD_FEED =
        AggregatorV3Interface(0xF096872672F44d6EBA71458D74fe67F9a77a23B9);
    AggregatorV3Interface private constant USDT_USD_FEED =
        AggregatorV3Interface(0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a);

    IERC20 private constant SAVAX = IERC20(0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE);
    IERC20 private constant WAVAX = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    IPharaohPool private constant SAVAX_WAVAX_POOL = IPharaohPool(0x65B9016c376604Fe0aF38c1E336Ffcec0F8ecBbD);

    struct Deployment {
        PharaohLiquidityVault implementation;
        ChainlinkRatioOracle usdcOracle;
        SAVAXRateOracle sAVAXOracle;
        PharaohLiquidityVault usdcVault;
        PharaohLiquidityVault wavaxVault;
    }

    function run() external returns (Deployment memory deployed) {
        address deployer = vm.envAddress("DEPLOYER");
        address multisig = vm.envOr("MULTISIG", deployer);
        address keeper = vm.envOr("KEEPER", deployer);
        uint256 usdcCap = vm.envOr("USDC_DEPOSIT_CAP", uint256(250_000e6));
        uint256 wavaxCap = vm.envOr("WAVAX_DEPOSIT_CAP", uint256(500 ether));

        vm.startBroadcast(deployer);

        // Both live pools were deployed with a one-slot oracle buffer. Grow the
        // ring before launch so the configured 30-minute TWAP remains available
        // across swaps. Deposits fail closed while the first 30 minutes accrue.
        USDT_USDC_POOL.increaseObservationCardinalityNext(64);
        SAVAX_WAVAX_POOL.increaseObservationCardinalityNext(64);

        deployed.implementation = new PharaohLiquidityVault();
        deployed.usdcOracle =
            new ChainlinkRatioOracle(address(USDC), address(USDT), USDC_USD_FEED, USDT_USD_FEED, 26 hours);
        deployed.sAVAXOracle = new SAVAXRateOracle(address(WAVAX), ISAVAX(address(SAVAX)));

        deployed.usdcVault = _deployProxy(
            deployed.implementation,
            multisig,
            PharaohLiquidityVault.InitParams({
                name: "Peridot Pharaoh USDC/USDt Vault",
                symbol: "pPHAR-USDC",
                asset: USDC,
                factory: FACTORY,
                pool: USDT_USDC_POOL,
                positionManager: POSITION_MANAGER,
                swapRouter: SWAP_ROUTER,
                priceOracle: deployed.usdcOracle,
                owner: multisig,
                rebalancer: keeper,
                depositCap: usdcCap,
                tickRange: 100,
                twapPeriod: 30 minutes,
                maxTwapDeviationTicks: 30,
                maxOracleDeviationBps: 30,
                slippageBps: 100,
                valuationHaircutBps: 100
            })
        );

        deployed.wavaxVault = _deployProxy(
            deployed.implementation,
            multisig,
            PharaohLiquidityVault.InitParams({
                name: "Peridot Pharaoh sAVAX/WAVAX Vault",
                symbol: "pPHAR-WAVAX",
                asset: WAVAX,
                factory: FACTORY,
                pool: SAVAX_WAVAX_POOL,
                positionManager: POSITION_MANAGER,
                swapRouter: SWAP_ROUTER,
                priceOracle: deployed.sAVAXOracle,
                owner: multisig,
                rebalancer: keeper,
                depositCap: wavaxCap,
                tickRange: 600,
                twapPeriod: 30 minutes,
                maxTwapDeviationTicks: 100,
                maxOracleDeviationBps: 100,
                slippageBps: 300,
                valuationHaircutBps: 300
            })
        );

        vm.stopBroadcast();

        console2.log("PharaohLiquidityVault implementation:", address(deployed.implementation));
        _logVault("USDC/USDt", deployed.usdcVault);
        console2.log("  Chainlink ratio oracle:", address(deployed.usdcOracle));
        _logVault("sAVAX/WAVAX", deployed.wavaxVault);
        console2.log("  BENQI rate oracle:", address(deployed.sAVAXOracle));
        console2.log("TWAP warm-up: wait at least 30 minutes and verify observe([1800,0]) before listing.");
    }

    function _deployProxy(
        PharaohLiquidityVault implementation,
        address proxyAdminOwner,
        PharaohLiquidityVault.InitParams memory params
    ) private returns (PharaohLiquidityVault vault) {
        bytes memory initData = abi.encodeCall(PharaohLiquidityVault.initialize, (params));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), proxyAdminOwner, initData);
        vault = PharaohLiquidityVault(address(proxy));
    }

    function _logVault(string memory label, PharaohLiquidityVault vault) private view {
        address admin = address(uint160(uint256(vm.load(address(vault), ERC1967_ADMIN_SLOT))));
        console2.log(label, "vault:", address(vault));
        console2.log("  proxyAdmin:", admin);
        console2.log("  owner:", vault.owner());
        console2.log("  rebalancer:", vault.rebalancer());
        console2.log("  asset:", vault.asset());
        console2.log("  paired token:", address(vault.pairedToken()));
        console2.log("  pool:", address(vault.pool()));
        console2.log("  deposit cap:", vault.depositCap());
        console2.log("  paused:", vault.paused());
    }
}
