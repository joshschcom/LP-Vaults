// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PharaohLiquidityVault} from "../contracts/PharaohLiquidityVault.sol";
import {PharaohRewardCompounder} from "../contracts/PharaohRewardCompounder.sol";
import {IPharaohFactory} from "../contracts/interfaces/pharaoh/IPharaohFactory.sol";
import {IPharaohPool} from "../contracts/interfaces/pharaoh/IPharaohPool.sol";
import {IPharaohQuoterV2} from "../contracts/interfaces/pharaoh/IPharaohQuoterV2.sol";
import {IPharaohSwapRouter} from "../contracts/interfaces/pharaoh/IPharaohSwapRouter.sol";

/// @notice Executes both pinned compounder routes against current Avalanche
///         contracts. Every state change remains local to the fork.
contract PharaohRewardCompounderMainnetForkTest is Test {
    address private constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address private constant PHAR = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;
    address private constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address private constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

    int24 private constant PHAR_WAVAX_SPACING = 5;
    int24 private constant WAVAX_USDC_SPACING = 10;
    address private constant PHAR_WAVAX_POOL = 0xb78DA03566B6537aCC22F6a4ba070AbCF6eDebF6;
    address private constant WAVAX_USDC_POOL = 0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534;

    IPharaohFactory private constant FACTORY = IPharaohFactory(0xAE6E5c62328ade73ceefD42228528b70c8157D0d);
    IPharaohSwapRouter private constant SWAP_ROUTER = IPharaohSwapRouter(0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c);
    IPharaohQuoterV2 private constant QUOTER = IPharaohQuoterV2(0xB7297301b7CC659BB96D51754643A0Df6eEA2138);

    PharaohLiquidityVault private constant USDC_VAULT =
        PharaohLiquidityVault(0x855bF832f26a294d28500db59eE941dE3d654129);
    PharaohLiquidityVault private constant WAVAX_VAULT =
        PharaohLiquidityVault(0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8);

    bool private forkConfigured;
    PharaohRewardCompounder private compounder;

    function setUp() public {
        if (block.chainid != 43_114) {
            string memory rpcUrl = vm.envOr("AVAX_MAINNET_RPC_URL", string(""));
            if (bytes(rpcUrl).length == 0) return;
            vm.createSelectFork(rpcUrl);
        }
        forkConfigured = block.chainid == 43_114;
        if (!forkConfigured) return;

        compounder = new PharaohRewardCompounder(
            PharaohRewardCompounder.Config({
                safe: SAFE,
                phar: IERC20(PHAR),
                wavax: IERC20(WAVAX),
                usdc: IERC20(USDC),
                swapRouter: SWAP_ROUTER,
                usdcVault: address(USDC_VAULT),
                wavaxVault: address(WAVAX_VAULT),
                pharWavaxTickSpacing: PHAR_WAVAX_SPACING,
                wavaxUsdcTickSpacing: WAVAX_USDC_SPACING
            })
        );
    }

    function test_livePoolsAndRouterMatchPinnedRoutes() public {
        _requireFork();
        assertEq(FACTORY.getPool(PHAR, WAVAX, PHAR_WAVAX_SPACING), PHAR_WAVAX_POOL);
        assertEq(FACTORY.getPool(WAVAX, USDC, WAVAX_USDC_SPACING), WAVAX_USDC_POOL);
        assertEq(SWAP_ROUTER.deployer(), FACTORY.ramsesV3PoolDeployer());
        assertGt(IPharaohPool(PHAR_WAVAX_POOL).liquidity(), 0);
        assertGt(IPharaohPool(WAVAX_USDC_POOL).liquidity(), 0);
    }

    function test_liveDirectPharToWavaxDonation() public {
        _requireFork();
        uint256 pharIn = 1 ether;
        (uint256 quote,,,) = QUOTER.quoteExactInputSingle(
            IPharaohQuoterV2.QuoteExactInputSingleParams({
                tokenIn: PHAR, tokenOut: WAVAX, amountIn: pharIn, tickSpacing: PHAR_WAVAX_SPACING, sqrtPriceLimitX96: 0
            })
        );
        uint256 minimumRate = (quote * 95) / 100;
        uint256 vaultBalanceBefore = IERC20(WAVAX).balanceOf(address(WAVAX_VAULT));
        uint256 supplyBefore = WAVAX_VAULT.totalSupply();

        _fundAndApprove(pharIn);
        vm.prank(SAFE);
        (uint256 actualIn, uint256 assetOut) =
            compounder.compound(address(WAVAX_VAULT), pharIn, pharIn, minimumRate, block.timestamp + 5 minutes);

        console2.log("1 PHAR -> WAVAX", assetOut);
        assertEq(actualIn, pharIn);
        assertGe(assetOut, minimumRate);
        assertEq(IERC20(WAVAX).balanceOf(address(WAVAX_VAULT)) - vaultBalanceBefore, assetOut);
        assertEq(WAVAX_VAULT.totalSupply(), supplyBefore);
        _assertCleared();
    }

    function test_liveMultihopPharToUsdcDonation() public {
        _requireFork();
        uint256 pharIn = 1 ether;
        bytes memory path = abi.encodePacked(PHAR, PHAR_WAVAX_SPACING, WAVAX, WAVAX_USDC_SPACING, USDC);
        (uint256 quote,,,) = QUOTER.quoteExactInput(path, pharIn);
        uint256 minimumRate = (quote * 95) / 100;
        uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(address(USDC_VAULT));
        uint256 supplyBefore = USDC_VAULT.totalSupply();

        _fundAndApprove(pharIn);
        vm.prank(SAFE);
        (uint256 actualIn, uint256 assetOut) =
            compounder.compound(address(USDC_VAULT), pharIn, pharIn, minimumRate, block.timestamp + 5 minutes);

        console2.log("1 PHAR -> USDC", assetOut);
        assertEq(actualIn, pharIn);
        assertGe(assetOut, minimumRate);
        assertEq(IERC20(USDC).balanceOf(address(USDC_VAULT)) - vaultBalanceBefore, assetOut);
        assertEq(USDC_VAULT.totalSupply(), supplyBefore);
        _assertCleared();
    }

    function test_liveRouteHonorsMinimumRateAtomically() public {
        _requireFork();
        uint256 pharIn = 1 ether;
        (uint256 quote,,,) = QUOTER.quoteExactInputSingle(
            IPharaohQuoterV2.QuoteExactInputSingleParams({
                tokenIn: PHAR, tokenOut: WAVAX, amountIn: pharIn, tickSpacing: PHAR_WAVAX_SPACING, sqrtPriceLimitX96: 0
            })
        );
        _fundAndApprove(pharIn);

        vm.prank(SAFE);
        vm.expectRevert("Too little received");
        compounder.compound(address(WAVAX_VAULT), pharIn, pharIn, quote + 1, block.timestamp + 5 minutes);

        assertEq(IERC20(PHAR).balanceOf(SAFE), pharIn);
        assertEq(IERC20(PHAR).balanceOf(address(compounder)), 0);
        assertEq(IERC20(PHAR).allowance(address(compounder), address(SWAP_ROUTER)), 0);
    }

    function _fundAndApprove(uint256 amount) private {
        deal(PHAR, SAFE, amount, true);
        vm.prank(SAFE);
        IERC20(PHAR).approve(address(compounder), amount);
    }

    function _assertCleared() private view {
        assertEq(IERC20(PHAR).balanceOf(SAFE), 0);
        assertEq(IERC20(PHAR).balanceOf(address(compounder)), 0);
        assertEq(IERC20(PHAR).allowance(SAFE, address(compounder)), 0);
        assertEq(IERC20(PHAR).allowance(address(compounder), address(SWAP_ROUTER)), 0);
    }

    function _requireFork() private {
        if (!forkConfigured) vm.skip(true, "Avalanche mainnet fork not configured");
    }
}
