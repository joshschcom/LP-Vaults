// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
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

/// @notice Current-state Avalanche fork coverage for the two selected Pharaoh pools.
///
/// Run after the pools' 30-minute TWAP buffers have warmed:
///   forge test --fork-url <rpc> \
///     --match-contract PharaohLiquidityVaultMainnetForkTest -vvv
contract PharaohLiquidityVaultMainnetForkTest is Test {
    IPharaohFactory private constant FACTORY = IPharaohFactory(0xAE6E5c62328ade73ceefD42228528b70c8157D0d);
    IPharaohPositionManager private constant POSITION_MANAGER =
        IPharaohPositionManager(0x0B4478e810D48B5882D4019D435A2f864Bab4F39);
    IPharaohSwapRouter private constant SWAP_ROUTER = IPharaohSwapRouter(0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c);

    address private constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address private constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    IPharaohPool private constant USDT_USDC_POOL = IPharaohPool(0x9bFE3108Cc16D17a9Ec65545a0f50B2CA1C970c0);
    AggregatorV3Interface private constant USDC_USD_FEED =
        AggregatorV3Interface(0xF096872672F44d6EBA71458D74fe67F9a77a23B9);
    AggregatorV3Interface private constant USDT_USD_FEED =
        AggregatorV3Interface(0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a);

    address private constant SAVAX = 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE;
    address private constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    IPharaohPool private constant SAVAX_WAVAX_POOL = IPharaohPool(0x65B9016c376604Fe0aF38c1E336Ffcec0F8ecBbD);

    PharaohLiquidityVault private usdcVault;
    PharaohLiquidityVault private wavaxVault;
    ChainlinkRatioOracle private usdcOracle;
    SAVAXRateOracle private sAVAXOracle;

    address private alice = makeAddr("alice");
    address private keeper = makeAddr("keeper");
    bool private forkConfigured;
    bool private usdcTwapReady;
    bool private wavaxTwapReady;

    function setUp() public {
        if (block.chainid != 43114) {
            string memory rpcUrl = vm.envOr("AVAX_MAINNET_RPC_URL", string(""));
            if (bytes(rpcUrl).length == 0) return;
            vm.createSelectFork(rpcUrl);
        }
        forkConfigured = block.chainid == 43114;
        if (!forkConfigured) return;

        USDT_USDC_POOL.increaseObservationCardinalityNext(64);
        SAVAX_WAVAX_POOL.increaseObservationCardinalityNext(64);

        PharaohLiquidityVault implementation = new PharaohLiquidityVault();
        usdcOracle = new ChainlinkRatioOracle(USDC, USDT, USDC_USD_FEED, USDT_USD_FEED, 26 hours);
        sAVAXOracle = new SAVAXRateOracle(WAVAX, ISAVAX(SAVAX));

        usdcVault = _deploy(
            implementation,
            PharaohLiquidityVault.InitParams({
                name: "Peridot Pharaoh USDC/USDt Vault",
                symbol: "pPHAR-USDC",
                asset: IERC20(USDC),
                factory: FACTORY,
                pool: USDT_USDC_POOL,
                positionManager: POSITION_MANAGER,
                swapRouter: SWAP_ROUTER,
                priceOracle: usdcOracle,
                owner: address(this),
                rebalancer: keeper,
                depositCap: 250_000e6,
                tickRange: 100,
                twapPeriod: 30 minutes,
                maxTwapDeviationTicks: 30,
                maxOracleDeviationBps: 30,
                slippageBps: 100,
                valuationHaircutBps: 100
            })
        );
        wavaxVault = _deploy(
            implementation,
            PharaohLiquidityVault.InitParams({
                name: "Peridot Pharaoh sAVAX/WAVAX Vault",
                symbol: "pPHAR-WAVAX",
                asset: IERC20(WAVAX),
                factory: FACTORY,
                pool: SAVAX_WAVAX_POOL,
                positionManager: POSITION_MANAGER,
                swapRouter: SWAP_ROUTER,
                priceOracle: sAVAXOracle,
                owner: address(this),
                rebalancer: keeper,
                depositCap: 500 ether,
                tickRange: 600,
                twapPeriod: 30 minutes,
                maxTwapDeviationTicks: 100,
                maxOracleDeviationBps: 100,
                slippageBps: 300,
                valuationHaircutBps: 300
            })
        );
        usdcVault.unpause();
        wavaxVault.unpause();

        usdcTwapReady = _twapReady(USDT_USDC_POOL);
        wavaxTwapReady = _twapReady(SAVAX_WAVAX_POOL);
        deal(USDC, alice, 10_000e6);
        deal(WAVAX, alice, 100 ether);
    }

    function test_liveConfigurationAndIndependentRates() public {
        _requireFork();

        assertEq(USDT_USDC_POOL.token0(), USDT);
        assertEq(USDT_USDC_POOL.token1(), USDC);
        assertEq(SAVAX_WAVAX_POOL.token0(), SAVAX);
        assertEq(SAVAX_WAVAX_POOL.token1(), WAVAX);
        assertEq(POSITION_MANAGER.deployer(), FACTORY.ramsesV3PoolDeployer());
        assertEq(SWAP_ROUTER.deployer(), FACTORY.ramsesV3PoolDeployer());

        assertApproxEqRel(usdcOracle.quotePairToAsset(1e6), 1e6, 0.01e18);
        assertGt(sAVAXOracle.quotePairToAsset(1 ether), 1 ether);
    }

    function test_liveUSDCDepositAndFullRedeem() public {
        _requireFork();
        _requireTwap(usdcTwapReady, "USDt/USDC");

        uint256 depositAmount = 1_000e6;
        vm.startPrank(alice);
        IERC20(USDC).approve(address(usdcVault), depositAmount);
        uint256 shares = usdcVault.deposit(depositAmount, alice);
        assertEq(POSITION_MANAGER.ownerOf(usdcVault.tokenId()), address(usdcVault));
        uint256 balanceBefore = IERC20(USDC).balanceOf(alice);
        uint256 redeemed = usdcVault.redeem(shares, alice, alice);
        vm.stopPrank();

        console2.log("USDC round trip:", redeemed);
        assertEq(IERC20(USDC).balanceOf(alice) - balanceBefore, redeemed);
        assertGt(redeemed, (depositAmount * 98) / 100);
    }

    function test_liveWAVAXDepositAndFullRedeem() public {
        _requireFork();
        _requireTwap(wavaxTwapReady, "sAVAX/WAVAX");

        // The live pool currently has shallow active liquidity before this
        // vault contributes its first position. Use the documented 1-WAVAX
        // bootstrap canary; the deposit cap is not a per-transaction depth
        // guarantee and must only be raised after incremental depth testing.
        uint256 depositAmount = 1 ether;
        vm.startPrank(alice);
        IERC20(WAVAX).approve(address(wavaxVault), depositAmount);
        uint256 shares = wavaxVault.deposit(depositAmount, alice);
        uint256 balanceBefore = IERC20(WAVAX).balanceOf(alice);
        uint256 redeemed = wavaxVault.redeem(shares, alice, alice);
        vm.stopPrank();

        console2.log("WAVAX round trip:", redeemed);
        assertEq(IERC20(WAVAX).balanceOf(alice) - balanceBefore, redeemed);
        assertGt(redeemed, (depositAmount * 95) / 100);
    }

    function test_liveKeeperRebalance() public {
        _requireFork();
        _requireTwap(usdcTwapReady, "USDt/USDC");

        vm.startPrank(alice);
        IERC20(USDC).approve(address(usdcVault), 1_000e6);
        usdcVault.deposit(1_000e6, alice);
        vm.stopPrank();
        uint256 valueBefore = usdcVault.totalAssets();

        vm.prank(keeper);
        usdcVault.rebalance();

        assertApproxEqRel(usdcVault.totalAssets(), valueBefore, 0.02e18);
    }

    function _deploy(PharaohLiquidityVault implementation, PharaohLiquidityVault.InitParams memory params)
        private
        returns (PharaohLiquidityVault)
    {
        bytes memory initData = abi.encodeCall(PharaohLiquidityVault.initialize, (params));
        return PharaohLiquidityVault(
            address(new TransparentUpgradeableProxy(address(implementation), address(this), initData))
        );
    }

    function _requireFork() private {
        if (!forkConfigured) vm.skip(true, "AVAX_MAINNET_RPC_URL not configured");
    }

    function _requireTwap(bool ready, string memory poolName) private {
        if (!ready) vm.skip(true, string.concat(poolName, " 30-minute TWAP not ready"));
    }

    function _twapReady(IPharaohPool targetPool) private view returns (bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 30 minutes;
        (bool success,) = address(targetPool).staticcall(abi.encodeCall(IPharaohPool.observe, (secondsAgos)));
        return success;
    }
}
