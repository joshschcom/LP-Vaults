// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Script, console2} from "forge-std/Script.sol";

import {PharaohLiquidityVault} from "../contracts/PharaohLiquidityVault.sol";
import {IPharaohFactory} from "../contracts/interfaces/pharaoh/IPharaohFactory.sol";
import {IPharaohPool} from "../contracts/interfaces/pharaoh/IPharaohPool.sol";
import {IPharaohSwapRouter} from "../contracts/interfaces/pharaoh/IPharaohSwapRouter.sol";

/// @notice Converts 5 deployer USDC to WAVAX, then funds the Safe with the
///         exact assets required by the reviewed small-stage deposit batches.
/// @dev Guarded against replay by pinning the pre-stage vault supplies and
///      requiring the Safe to own every outstanding share.
contract FundPharaohSmallStage is Script {
    using SafeERC20 for IERC20;

    uint256 private constant AVALANCHE_CHAIN_ID = 43_114;
    uint256 private constant MAX_FEED_STALENESS = 26 hours;
    uint256 private constant PRE_STAGE_USDC_SUPPLY = 9_949_763;
    uint256 private constant PRE_STAGE_WAVAX_SUPPLY = 985_198_126_710_275_400;

    address private constant EXPECTED_DEPLOYER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address private constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address private constant LIVE_IMPLEMENTATION = 0x37E28a2C9FA3bBdab81efA69D5D480f5107a3770;
    bytes32 private constant LIVE_IMPLEMENTATION_CODEHASH =
        0x416f2a818693b20948fc44e9955ec7a370be051599b1eef6ca1fad932f3626ef;
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    IERC20 private constant USDC = IERC20(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    IERC20 private constant WAVAX = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    PharaohLiquidityVault private constant USDC_VAULT =
        PharaohLiquidityVault(0x855bF832f26a294d28500db59eE941dE3d654129);
    PharaohLiquidityVault private constant WAVAX_VAULT =
        PharaohLiquidityVault(0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8);

    IPharaohFactory private constant FACTORY = IPharaohFactory(0xAE6E5c62328ade73ceefD42228528b70c8157D0d);
    IPharaohSwapRouter private constant SWAP_ROUTER = IPharaohSwapRouter(0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c);
    IPharaohPool private constant USDC_WAVAX_POOL = IPharaohPool(0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534);
    address private constant POOL_DEPLOYER = 0x6a4113ed0915bCf5E48e758e8f4cEBFFC07C66f9;

    AggregatorV3Interface private constant USDC_USD_FEED =
        AggregatorV3Interface(0xF096872672F44d6EBA71458D74fe67F9a77a23B9);
    AggregatorV3Interface private constant AVAX_USD_FEED =
        AggregatorV3Interface(0x0A77230d17318075983913bC2145DB16C7366156);

    uint256 public constant USDC_TO_SWAP = 5e6;
    uint256 public constant USDC_TO_SAFE = 20e6;
    uint256 public constant WAVAX_TO_SAFE = 0.75 ether;

    error Funding__WrongChain(uint256 actual);
    error Funding__WrongDeployer(address actual);
    error Funding__UnexpectedState();
    error Funding__InsufficientBalance(address token, uint256 actual, uint256 required);
    error Funding__StaleFeed(address feed);
    error Funding__InvalidFeed(address feed);
    error Funding__InsufficientSwapOutput(uint256 actual, uint256 required);

    function run() external returns (uint256 amountOut, uint256 amountOutMinimum) {
        address deployer = vm.envAddress("DEPLOYER");
        _assertPreFundingState(deployer);

        uint256 oracleFairOut = Math.mulDiv(USDC_TO_SWAP * 1e12, _readFeed(USDC_USD_FEED), _readFeed(AVAX_USD_FEED));
        uint256 oracleMinimum = Math.mulDiv(oracleFairOut, 9_700, 10_000);
        amountOutMinimum = Math.max(WAVAX_TO_SAFE, oracleMinimum);
        uint256 wavaxBefore = WAVAX.balanceOf(deployer);

        vm.startBroadcast(deployer);
        USDC.forceApprove(address(SWAP_ROUTER), USDC_TO_SWAP);
        amountOut = SWAP_ROUTER.exactInputSingle(
            IPharaohSwapRouter.ExactInputSingleParams({
                tokenIn: address(USDC),
                tokenOut: address(WAVAX),
                tickSpacing: 10,
                recipient: deployer,
                deadline: block.timestamp + 15 minutes,
                amountIn: USDC_TO_SWAP,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );
        if (USDC.allowance(deployer, address(SWAP_ROUTER)) != 0) USDC.forceApprove(address(SWAP_ROUTER), 0);
        USDC.safeTransfer(SAFE, USDC_TO_SAFE);
        WAVAX.safeTransfer(SAFE, WAVAX_TO_SAFE);
        vm.stopBroadcast();

        if (amountOut < amountOutMinimum || WAVAX.balanceOf(deployer) != wavaxBefore + amountOut - WAVAX_TO_SAFE) {
            revert Funding__InsufficientSwapOutput(amountOut, amountOutMinimum);
        }
        if (USDC.balanceOf(SAFE) != USDC_TO_SAFE || WAVAX.balanceOf(SAFE) != WAVAX_TO_SAFE) {
            revert Funding__UnexpectedState();
        }

        console2.log("USDC swapped:", USDC_TO_SWAP);
        console2.log("minimum WAVAX output:", amountOutMinimum);
        console2.log("actual WAVAX output:", amountOut);
        console2.log("Safe USDC funded:", USDC_TO_SAFE);
        console2.log("Safe WAVAX funded:", WAVAX_TO_SAFE);
        console2.log("remaining deployer WAVAX:", WAVAX.balanceOf(deployer));
    }

    function _assertPreFundingState(address deployer) private view {
        if (block.chainid != AVALANCHE_CHAIN_ID) revert Funding__WrongChain(block.chainid);
        if (deployer != EXPECTED_DEPLOYER) revert Funding__WrongDeployer(deployer);
        if (deployer.balance < 0.05 ether) {
            revert Funding__InsufficientBalance(address(0), deployer.balance, 0.05 ether);
        }
        if (USDC.balanceOf(deployer) < USDC_TO_SWAP + USDC_TO_SAFE) {
            revert Funding__InsufficientBalance(address(USDC), USDC.balanceOf(deployer), USDC_TO_SWAP + USDC_TO_SAFE);
        }
        if (
            USDC.balanceOf(SAFE) != 0 || WAVAX.balanceOf(SAFE) != 0
                || USDC.allowance(deployer, address(SWAP_ROUTER)) != 0 || USDC.allowance(SAFE, address(USDC_VAULT)) != 0
                || WAVAX.allowance(SAFE, address(WAVAX_VAULT)) != 0 || USDC_VAULT.paused() || WAVAX_VAULT.paused()
                || USDC_VAULT.depositCap() != 1 || WAVAX_VAULT.depositCap() != 1
                || USDC_VAULT.totalSupply() != PRE_STAGE_USDC_SUPPLY
                || WAVAX_VAULT.totalSupply() != PRE_STAGE_WAVAX_SUPPLY
                || USDC_VAULT.balanceOf(SAFE) != PRE_STAGE_USDC_SUPPLY
                || WAVAX_VAULT.balanceOf(SAFE) != PRE_STAGE_WAVAX_SUPPLY
                || _implementationOf(USDC_VAULT) != LIVE_IMPLEMENTATION
                || _implementationOf(WAVAX_VAULT) != LIVE_IMPLEMENTATION
                || LIVE_IMPLEMENTATION.codehash != LIVE_IMPLEMENTATION_CODEHASH
        ) revert Funding__UnexpectedState();

        (,,,,,, bool unlocked) = USDC_WAVAX_POOL.slot0();
        if (
            FACTORY.ramsesV3PoolDeployer() != POOL_DEPLOYER || SWAP_ROUTER.deployer() != POOL_DEPLOYER
                || FACTORY.getPool(address(USDC), address(WAVAX), 10) != address(USDC_WAVAX_POOL)
                || USDC_WAVAX_POOL.factory() != address(FACTORY) || USDC_WAVAX_POOL.token0() != address(WAVAX)
                || USDC_WAVAX_POOL.token1() != address(USDC) || USDC_WAVAX_POOL.tickSpacing() != 10
                || USDC_WAVAX_POOL.liquidity() == 0 || !unlocked
        ) revert Funding__UnexpectedState();
    }

    function _readFeed(AggregatorV3Interface feed) private view returns (uint256 answer) {
        if (feed.decimals() != 8) revert Funding__InvalidFeed(address(feed));
        (uint80 roundId, int256 signedAnswer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (roundId == 0 || signedAnswer <= 0 || answeredInRound < roundId) {
            revert Funding__InvalidFeed(address(feed));
        }
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > MAX_FEED_STALENESS) {
            revert Funding__StaleFeed(address(feed));
        }
        answer = uint256(signedAnswer);
    }

    function _implementationOf(PharaohLiquidityVault vault) private view returns (address) {
        return address(uint160(uint256(vm.load(address(vault), ERC1967_IMPLEMENTATION_SLOT))));
    }
}
