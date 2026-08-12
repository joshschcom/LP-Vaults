// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {PharaohLiquidityVault} from "../contracts/PharaohLiquidityVault.sol";
import {IPeridotPriceOracle, PeridotPharaohShareOracle} from "../contracts/oracles/PeridotPharaohShareOracle.sol";

contract LiveForkPeridotBaseOracle is IPeridotPriceOracle {
    function getUnderlyingPrice(address) external pure returns (uint256) {
        return 0;
    }
}

contract LiveForkPeridotMarket {
    address public immutable underlying;

    constructor(address underlying_) {
        underlying = underlying_;
    }
}

/// @notice Current-state checks for the deployed Avalanche Pharaoh proxies.
/// @dev All state changes happen only inside the local fork.
contract PharaohDeploymentMainnetForkTest is Test {
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    address private constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address private constant KEEPER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address private constant IMPLEMENTATION = 0x87C2C3bE37B2D71Ca85D2D950F0eed4532410CEa;

    address private constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    AggregatorV3Interface private constant USDC_USD_FEED =
        AggregatorV3Interface(0xF096872672F44d6EBA71458D74fe67F9a77a23B9);
    address private constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address private constant USDC_POOL = 0x9bFE3108Cc16D17a9Ec65545a0f50B2CA1C970c0;
    address private constant USDC_ORACLE = 0xe6060635dfdDd495ca22b828e144AB8411c8a431;
    address private constant USDC_PROXY_ADMIN = 0x2DD4191B2944396B5853f4219E829f01636F65cf;
    PharaohLiquidityVault private constant USDC_VAULT =
        PharaohLiquidityVault(0x855bF832f26a294d28500db59eE941dE3d654129);

    address private constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    AggregatorV3Interface private constant AVAX_USD_FEED =
        AggregatorV3Interface(0x0A77230d17318075983913bC2145DB16C7366156);
    address private constant SAVAX = 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE;
    address private constant WAVAX_POOL = 0x65B9016c376604Fe0aF38c1E336Ffcec0F8ecBbD;
    address private constant WAVAX_ORACLE = 0x2002aFd6C713a6075d66DaE758Dc466787faCeEF;
    address private constant WAVAX_PROXY_ADMIN = 0x34CbBdfcBcc72e8bf70CbF6c7245fdb2725b94dC;
    PharaohLiquidityVault private constant WAVAX_VAULT =
        PharaohLiquidityVault(0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8);

    bool private forkConfigured;

    function setUp() public {
        if (block.chainid != 43114) {
            string memory rpcUrl = vm.envOr("AVAX_MAINNET_RPC_URL", string(""));
            if (bytes(rpcUrl).length == 0) return;
            vm.createSelectFork(rpcUrl);
        }
        forkConfigured = block.chainid == 43114;
    }

    function test_deployedConfiguration() public {
        _requireFork();

        _assertProxy(USDC_VAULT, USDC_PROXY_ADMIN);
        _assertVault(USDC_VAULT, USDC, USDT, USDC_POOL, USDC_ORACLE, 1, 100, 30, 30, 100, 100);

        _assertProxy(WAVAX_VAULT, WAVAX_PROXY_ADMIN);
        _assertVault(WAVAX_VAULT, WAVAX, SAVAX, WAVAX_POOL, WAVAX_ORACLE, 1, 600, 100, 100, 300, 300);
    }

    function test_candidateHotfixUSDCPartialCanaryRoundTrip() public {
        _requireFork();
        address hotfix = address(new PharaohLiquidityVault());
        _installPartialExitHotfix(USDC_VAULT, USDC_PROXY_ADMIN, hotfix);
        uint256 redeemed = _canaryRoundTrip(USDC_VAULT, USDC, 10e6);
        console2.log("hotfixed USDC canary round trip", redeemed);
        assertGt(redeemed, 9_800_000);
    }

    function test_candidateHotfixWAVAXPartialCanaryRoundTrip() public {
        _requireFork();
        address hotfix = address(new PharaohLiquidityVault());
        _installPartialExitHotfix(WAVAX_VAULT, WAVAX_PROXY_ADMIN, hotfix);
        uint256 redeemed = _canaryRoundTrip(WAVAX_VAULT, WAVAX, 1 ether);
        console2.log("hotfixed WAVAX canary round trip", redeemed);
        assertGt(redeemed, 0.98 ether);
    }

    function test_proposedUSDCStagedBatchRoundTrip() public {
        _requireFork();
        address hotfix = address(new PharaohLiquidityVault());
        _installPartialExitHotfix(USDC_VAULT, USDC_PROXY_ADMIN, hotfix);
        uint256 redeemed = _stagedRoundTrip(USDC_VAULT, USDC, 100e6, 200e6);
        console2.log("proposed 100-USDC stage round trip", redeemed);
        assertGt(redeemed, 98e6);
    }

    function test_proposedWAVAXStagedBatchRoundTrip() public {
        _requireFork();
        address hotfix = address(new PharaohLiquidityVault());
        _installPartialExitHotfix(WAVAX_VAULT, WAVAX_PROXY_ADMIN, hotfix);
        uint256 redeemed = _stagedRoundTrip(WAVAX_VAULT, WAVAX, 5 ether, 10 ether);
        console2.log("proposed 5-WAVAX stage round trip", redeemed);
        assertGt(redeemed, 4.75 ether);
    }

    function test_peridotShareOracleUsesLiveVaultAccountingAndFeeds() public {
        _requireFork();

        PeridotPharaohShareOracle oracle = new PeridotPharaohShareOracle(address(this), new LiveForkPeridotBaseOracle());
        oracle.registerVault(IERC4626(address(USDC_VAULT)), USDC_USD_FEED, 26 hours);
        oracle.registerVault(IERC4626(address(WAVAX_VAULT)), AVAX_USD_FEED, 26 hours);

        LiveForkPeridotMarket usdcMarket = new LiveForkPeridotMarket(address(USDC_VAULT));
        LiveForkPeridotMarket wavaxMarket = new LiveForkPeridotMarket(address(WAVAX_VAULT));
        uint256 usdcPrice = oracle.getUnderlyingPrice(address(usdcMarket));
        uint256 wavaxPrice = oracle.getUnderlyingPrice(address(wavaxMarket));

        // USDC vault shares use six decimals, so Compound/Peridot requires 1e30-scale pricing.
        assertGt(usdcPrice, 0.95e30);
        assertLt(usdcPrice, 1.05e30);
        assertGt(wavaxPrice, 0);
        assertEq(wavaxPrice, oracle.getShareUsdPrice(address(WAVAX_VAULT)));
    }

    function test_securityUpgradeIsLiveAndRiskMigrationCannotReplay() public {
        _requireFork();

        assertEq(_implementationOf(USDC_VAULT), IMPLEMENTATION);
        assertEq(_implementationOf(WAVAX_VAULT), IMPLEMENTATION);
        assertEq(USDC_VAULT.maxOracleDeviationBps(), 30);
        assertEq(USDC_VAULT.slippageBps(), 100);
        assertEq(USDC_VAULT.valuationHaircutBps(), 100);
        assertEq(WAVAX_VAULT.maxOracleDeviationBps(), 100);
        assertEq(WAVAX_VAULT.slippageBps(), 300);
        assertEq(WAVAX_VAULT.valuationHaircutBps(), 300);

        _assertRiskMigrationLocked(USDC_VAULT, USDC_PROXY_ADMIN, 30, 100, 100);
        _assertRiskMigrationLocked(WAVAX_VAULT, WAVAX_PROXY_ADMIN, 100, 300, 300);

        address hotfix = address(new PharaohLiquidityVault());
        _installPartialExitHotfix(USDC_VAULT, USDC_PROXY_ADMIN, hotfix);
        _installPartialExitHotfix(WAVAX_VAULT, WAVAX_PROXY_ADMIN, hotfix);
        assertGt(_canaryRoundTrip(USDC_VAULT, USDC, 10e6), 9_800_000);
        assertGt(_canaryRoundTrip(WAVAX_VAULT, WAVAX, 1 ether), 0.98 ether);
    }

    function test_partialExitHotfixPreservesLiveState() public {
        _requireFork();

        address hotfix = address(new PharaohLiquidityVault());
        _installPartialExitHotfix(USDC_VAULT, USDC_PROXY_ADMIN, hotfix);
        _installPartialExitHotfix(WAVAX_VAULT, WAVAX_PROXY_ADMIN, hotfix);
    }

    function _assertProxy(PharaohLiquidityVault vault, address expectedAdmin) private view {
        address implementation = _implementationOf(vault);
        address admin = address(uint160(uint256(vm.load(address(vault), ERC1967_ADMIN_SLOT))));
        assertEq(implementation, IMPLEMENTATION);
        assertEq(admin, expectedAdmin);
        assertEq(ProxyAdmin(admin).owner(), SAFE);
    }

    function _assertRiskMigrationLocked(
        PharaohLiquidityVault vault,
        address admin,
        uint16 oracleDeviation,
        uint16 slippage,
        uint16 haircut
    ) private {
        bytes memory migration = abi.encodeCall(
            PharaohLiquidityVault.initializeV2RiskParameters, (oracleDeviation, slippage, haircut)
        );
        vm.prank(SAFE);
        vm.expectRevert();
        ProxyAdmin(admin)
            .upgradeAndCall(ITransparentUpgradeableProxy(payable(address(vault))), IMPLEMENTATION, migration);
    }

    function _implementationOf(PharaohLiquidityVault vault) private view returns (address) {
        return address(uint160(uint256(vm.load(address(vault), ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _installPartialExitHotfix(PharaohLiquidityVault vault, address admin, address hotfix) private {
        uint256 supplyBefore = vault.totalSupply();
        uint256 safeSharesBefore = vault.balanceOf(SAFE);
        uint256 assetsBefore = vault.totalAssets();
        uint256 tokenIdBefore = vault.tokenId();
        uint256 capBefore = vault.depositCap();
        bool pausedBefore = vault.paused();

        vm.prank(SAFE);
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(payable(address(vault))), hotfix, bytes(""));

        assertEq(_implementationOf(vault), hotfix);
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(vault.balanceOf(SAFE), safeSharesBefore);
        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(vault.tokenId(), tokenIdBefore);
        assertEq(vault.depositCap(), capBefore);
        assertEq(vault.paused(), pausedBefore);
        assertEq(vault.owner(), SAFE);
        assertEq(vault.rebalancer(), KEEPER);
    }

    function _assertVault(
        PharaohLiquidityVault vault,
        address expectedAsset,
        address expectedPair,
        address expectedPool,
        address expectedOracle,
        uint256 expectedCap,
        int24 expectedRange,
        uint24 expectedTwapDeviation,
        uint16 expectedOracleDeviation,
        uint16 expectedSlippage,
        uint16 expectedHaircut
    ) private view {
        assertEq(vault.owner(), SAFE);
        assertEq(vault.rebalancer(), KEEPER);
        assertEq(vault.asset(), expectedAsset);
        assertEq(address(vault.pairedToken()), expectedPair);
        assertEq(address(vault.pool()), expectedPool);
        assertEq(address(vault.priceOracle()), expectedOracle);
        assertEq(vault.depositCap(), expectedCap);
        assertFalse(vault.paused());
        assertGt(vault.tokenId(), 0);
        assertGt(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(SAFE), vault.totalSupply());
        assertEq(IERC20(expectedAsset).allowance(SAFE, address(vault)), 0);
        assertEq(vault.tickRange(), expectedRange);
        assertEq(vault.twapPeriod(), 30 minutes);
        assertEq(vault.maxTwapDeviationTicks(), expectedTwapDeviation);
        assertEq(vault.maxOracleDeviationBps(), expectedOracleDeviation);
        assertEq(vault.slippageBps(), expectedSlippage);
        assertEq(vault.valuationHaircutBps(), expectedHaircut);
    }

    function _canaryRoundTrip(PharaohLiquidityVault vault, address asset, uint256 amount)
        private
        returns (uint256 redeemed)
    {
        uint256 existingAssets = vault.totalAssets();
        vm.startPrank(SAFE);
        if (vault.paused()) vault.unpause();
        // deposit() collects accrued LP fees before enforcing the cap, so an
        // exact pre-call NAV + amount cap can become a few wei too small.
        uint256 temporaryCap = existingAssets + amount + (amount / 10) + 1;
        if (vault.depositCap() < temporaryCap) vault.setDepositCap(temporaryCap);

        uint256 balanceBefore = IERC20(asset).balanceOf(SAFE);
        deal(asset, SAFE, balanceBefore + amount);
        IERC20(asset).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, SAFE);
        assertGt(shares, 0);
        assertGt(vault.tokenId(), 0);
        vault.setDepositCap(1);
        assertFalse(vault.paused());
        assertEq(vault.maxDeposit(SAFE), 0);

        redeemed = vault.redeem(shares, SAFE, SAFE);
        vm.stopPrank();
    }

    function _stagedRoundTrip(PharaohLiquidityVault vault, address asset, uint256 amount, uint256 temporaryCap)
        private
        returns (uint256 redeemed)
    {
        assertFalse(vault.paused());
        assertEq(vault.depositCap(), 1);
        uint256 sharesBefore = vault.balanceOf(SAFE);
        uint256 balanceBefore = IERC20(asset).balanceOf(SAFE);
        deal(asset, SAFE, balanceBefore + amount);

        vm.startPrank(SAFE);
        IERC20(asset).approve(address(vault), amount);
        vault.setDepositCap(temporaryCap);
        uint256 stagedShares = vault.deposit(amount, SAFE);
        vault.setDepositCap(1);
        vm.stopPrank();

        assertGt(stagedShares, 0);
        assertEq(vault.balanceOf(SAFE), sharesBefore + stagedShares);
        assertEq(IERC20(asset).allowance(SAFE, address(vault)), 0);
        assertEq(vault.depositCap(), 1);
        assertEq(vault.maxDeposit(address(0xBEEF)), 0);

        vm.prank(SAFE);
        redeemed = vault.redeem(stagedShares, SAFE, SAFE);
        assertEq(vault.balanceOf(SAFE), sharesBefore);
    }

    function _requireFork() private {
        if (!forkConfigured) vm.skip(true, "Avalanche mainnet fork not configured");
    }
}
