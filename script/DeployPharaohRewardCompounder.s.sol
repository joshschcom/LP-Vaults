// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

import {PharaohLiquidityVault} from "../contracts/PharaohLiquidityVault.sol";
import {PharaohRewardCompounder} from "../contracts/PharaohRewardCompounder.sol";
import {IPharaohFactory} from "../contracts/interfaces/pharaoh/IPharaohFactory.sol";
import {IPharaohPool} from "../contracts/interfaces/pharaoh/IPharaohPool.sol";
import {IPharaohQuoterV2} from "../contracts/interfaces/pharaoh/IPharaohQuoterV2.sol";
import {IPharaohSwapRouter} from "../contracts/interfaces/pharaoh/IPharaohSwapRouter.sol";

/// @notice Pinned Avalanche deployment for the standalone PHAR processor.
/// @dev This script deploys only the compounder. It does not approve tokens,
///      harvest rewards, swap PHAR, donate assets, or modify either vault.
contract DeployPharaohRewardCompounder is Script {
    uint256 private constant AVALANCHE_CHAIN_ID = 43_114;
    uint256 private constant BPS = 10_000;
    uint256 private constant QUOTE_AMOUNT = 1 ether;

    address private constant EXPECTED_DEPLOYER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address private constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address private constant CURRENT_IMPLEMENTATION = 0x165E1f072e7bEeDf94f14F732838354cA20bA45d;
    bytes32 private constant CURRENT_IMPLEMENTATION_CODEHASH =
        0x4fa61d2d9ce0a7e8f1aebf96fd007fad0aa17f969be476eddd6d6f344fb22e4b;
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    IERC20 private constant PHAR = IERC20(0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7);
    IERC20 private constant WAVAX = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    IERC20 private constant USDC = IERC20(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);

    int24 private constant PHAR_WAVAX_SPACING = 5;
    int24 private constant WAVAX_USDC_SPACING = 10;
    IPharaohPool private constant PHAR_WAVAX_POOL = IPharaohPool(0xb78DA03566B6537aCC22F6a4ba070AbCF6eDebF6);
    IPharaohPool private constant WAVAX_USDC_POOL = IPharaohPool(0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534);

    IPharaohFactory private constant FACTORY = IPharaohFactory(0xAE6E5c62328ade73ceefD42228528b70c8157D0d);
    IPharaohSwapRouter private constant SWAP_ROUTER = IPharaohSwapRouter(0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c);
    IPharaohQuoterV2 private constant QUOTER = IPharaohQuoterV2(0xB7297301b7CC659BB96D51754643A0Df6eEA2138);

    PharaohLiquidityVault private constant USDC_VAULT =
        PharaohLiquidityVault(0x855bF832f26a294d28500db59eE941dE3d654129);
    PharaohLiquidityVault private constant WAVAX_VAULT =
        PharaohLiquidityVault(0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8);

    bytes32 private constant SWAP_ROUTER_CODEHASH = 0xc73f3d2a21cdace7e104858002a8be4442e2dc9d234f39c3f01320a962219032;
    bytes32 private constant QUOTER_CODEHASH = 0xf520476b52f99d9a1ff89c6187193eb240c6cb1d11d2e6466ebcbbdf7a753bd2;
    bytes32 private constant PHAR_WAVAX_POOL_CODEHASH =
        0x8574735b0859cec219b9019a9b80cae444288ef8b884ae74f7ca7d21b4244363;
    bytes32 private constant WAVAX_USDC_POOL_CODEHASH =
        0xc09ba0e43ec861307c9abaf85e482e9562c1fb0597d782070c93aa12ddfd9ac6;

    error CompounderDeploy__WrongChain(uint256 actual);
    error CompounderDeploy__WrongDeployer(address actual);
    error CompounderDeploy__MissingCode(address target);
    error CompounderDeploy__WrongCodehash(address target, bytes32 expected, bytes32 actual);
    error CompounderDeploy__UnexpectedImplementation(address vault, address actual);
    error CompounderDeploy__UnexpectedVaultState(address vault);
    error CompounderDeploy__UnexpectedRoute(address pool);
    error CompounderDeploy__NoActiveLiquidity(address pool);
    error CompounderDeploy__NoExecutableQuote();
    error CompounderDeploy__UnexpectedCompounder(address compounder);

    function run() external returns (PharaohRewardCompounder compounder) {
        address deployer = vm.envAddress("DEPLOYER");
        _assertLiveState(deployer);

        vm.startBroadcast(deployer);
        compounder = new PharaohRewardCompounder(_config());
        vm.stopBroadcast();

        _assertCompounder(compounder);
        (uint256 wavaxPerPhar, uint256 usdcPerPhar) = _quotes(QUOTE_AMOUNT);
        _logDeployment(compounder, wavaxPerPhar, usdcPerPhar);
    }

    function _config() private pure returns (PharaohRewardCompounder.Config memory) {
        return PharaohRewardCompounder.Config({
            safe: SAFE,
            phar: PHAR,
            wavax: WAVAX,
            usdc: USDC,
            swapRouter: SWAP_ROUTER,
            usdcVault: address(USDC_VAULT),
            wavaxVault: address(WAVAX_VAULT),
            pharWavaxTickSpacing: PHAR_WAVAX_SPACING,
            wavaxUsdcTickSpacing: WAVAX_USDC_SPACING
        });
    }

    function _assertLiveState(address deployer) private {
        if (block.chainid != AVALANCHE_CHAIN_ID) revert CompounderDeploy__WrongChain(block.chainid);
        if (deployer != EXPECTED_DEPLOYER) revert CompounderDeploy__WrongDeployer(deployer);

        _assertCodehash(CURRENT_IMPLEMENTATION, CURRENT_IMPLEMENTATION_CODEHASH);
        _assertCodehash(address(SWAP_ROUTER), SWAP_ROUTER_CODEHASH);
        _assertCodehash(address(QUOTER), QUOTER_CODEHASH);
        _assertCodehash(address(PHAR_WAVAX_POOL), PHAR_WAVAX_POOL_CODEHASH);
        _assertCodehash(address(WAVAX_USDC_POOL), WAVAX_USDC_POOL_CODEHASH);
        _requireCode(SAFE);
        _requireCode(address(PHAR));
        _requireCode(address(WAVAX));
        _requireCode(address(USDC));

        address poolDeployer = FACTORY.ramsesV3PoolDeployer();
        if (SWAP_ROUTER.deployer() != poolDeployer || _quoterDeployer() != poolDeployer) {
            revert CompounderDeploy__UnexpectedRoute(address(SWAP_ROUTER));
        }
        _assertPool(PHAR_WAVAX_POOL, address(PHAR), address(WAVAX), PHAR_WAVAX_SPACING);
        _assertPool(WAVAX_USDC_POOL, address(WAVAX), address(USDC), WAVAX_USDC_SPACING);

        _assertVault(USDC_VAULT, address(USDC));
        _assertVault(WAVAX_VAULT, address(WAVAX));

        (uint256 wavaxOut, uint256 usdcOut) = _quotes(QUOTE_AMOUNT);
        if (wavaxOut == 0 || usdcOut == 0) revert CompounderDeploy__NoExecutableQuote();
    }

    function _assertPool(IPharaohPool pool, address tokenA, address tokenB, int24 spacing) private view {
        if (FACTORY.getPool(tokenA, tokenB, spacing) != address(pool)) {
            revert CompounderDeploy__UnexpectedRoute(address(pool));
        }
        address expected0 = tokenA < tokenB ? tokenA : tokenB;
        address expected1 = tokenA < tokenB ? tokenB : tokenA;
        if (pool.token0() != expected0 || pool.token1() != expected1 || pool.tickSpacing() != spacing) {
            revert CompounderDeploy__UnexpectedRoute(address(pool));
        }
        if (pool.liquidity() == 0) revert CompounderDeploy__NoActiveLiquidity(address(pool));
    }

    function _assertVault(PharaohLiquidityVault vault, address expectedAsset) private view {
        address implementation = address(uint160(uint256(vm.load(address(vault), ERC1967_IMPLEMENTATION_SLOT))));
        if (implementation != CURRENT_IMPLEMENTATION) {
            revert CompounderDeploy__UnexpectedImplementation(address(vault), implementation);
        }
        uint256 supply = vault.totalSupply();
        if (
            vault.owner() != SAFE || vault.asset() != expectedAsset
                || address(vault.swapRouter()) != address(SWAP_ROUTER) || vault.paused() || vault.depositCap() != 1
                || supply == 0 || vault.balanceOf(SAFE) != supply || vault.tokenId() == 0
        ) revert CompounderDeploy__UnexpectedVaultState(address(vault));
        vault.totalAssets();
    }

    function _assertCompounder(PharaohRewardCompounder compounder) private view {
        if (
            address(compounder).code.length == 0 || compounder.safe() != SAFE
                || address(compounder.phar()) != address(PHAR) || address(compounder.wavax()) != address(WAVAX)
                || address(compounder.usdc()) != address(USDC)
                || address(compounder.swapRouter()) != address(SWAP_ROUTER)
                || compounder.usdcVault() != address(USDC_VAULT) || compounder.wavaxVault() != address(WAVAX_VAULT)
                || compounder.pharWavaxTickSpacing() != PHAR_WAVAX_SPACING
                || compounder.wavaxUsdcTickSpacing() != WAVAX_USDC_SPACING
        ) revert CompounderDeploy__UnexpectedCompounder(address(compounder));
    }

    function _quotes(uint256 pharIn) private returns (uint256 wavaxOut, uint256 usdcOut) {
        (wavaxOut,,,) = QUOTER.quoteExactInputSingle(
            IPharaohQuoterV2.QuoteExactInputSingleParams({
                tokenIn: address(PHAR),
                tokenOut: address(WAVAX),
                amountIn: pharIn,
                tickSpacing: PHAR_WAVAX_SPACING,
                sqrtPriceLimitX96: 0
            })
        );
        bytes memory usdcPath =
            abi.encodePacked(address(PHAR), PHAR_WAVAX_SPACING, address(WAVAX), WAVAX_USDC_SPACING, address(USDC));
        (usdcOut,,,) = QUOTER.quoteExactInput(usdcPath, pharIn);
    }

    function _logDeployment(PharaohRewardCompounder compounder, uint256 wavaxPerPhar, uint256 usdcPerPhar)
        private
        view
    {
        console2.log("Avalanche chain ID:", block.chainid);
        console2.log("Safe:", SAFE);
        console2.log("PharaohRewardCompounder:", address(compounder));
        console2.log("Runtime codehash:");
        console2.logBytes32(address(compounder).codehash);
        console2.log("PHAR/WAVAX pool:", address(PHAR_WAVAX_POOL));
        console2.log("PHAR/WAVAX fee:", PHAR_WAVAX_POOL.fee());
        console2.log("WAVAX/USDC pool:", address(WAVAX_USDC_POOL));
        console2.log("WAVAX/USDC fee:", WAVAX_USDC_POOL.fee());
        console2.log("1 PHAR quoted WAVAX:", wavaxPerPhar);
        console2.log("1 PHAR quoted USDC:", usdcPerPhar);
        console2.log("95% WAVAX minimum rate:", (wavaxPerPhar * 9_500) / BPS);
        console2.log("95% USDC minimum rate:", (usdcPerPhar * 9_500) / BPS);
        console2.log("Safe PHAR balance:", PHAR.balanceOf(SAFE));
        console2.log("Deployment changed no Safe approvals, vault state, or reward balances.");
    }

    function _quoterDeployer() private view returns (address result) {
        (bool success, bytes memory data) = address(QUOTER).staticcall(abi.encodeWithSignature("deployer()"));
        if (!success || data.length != 32) revert CompounderDeploy__UnexpectedRoute(address(QUOTER));
        result = abi.decode(data, (address));
    }

    function _requireCode(address target) private view {
        if (target.code.length == 0) revert CompounderDeploy__MissingCode(target);
    }

    function _assertCodehash(address target, bytes32 expected) private view {
        bytes32 actual = target.codehash;
        if (actual != expected) revert CompounderDeploy__WrongCodehash(target, expected, actual);
    }
}
