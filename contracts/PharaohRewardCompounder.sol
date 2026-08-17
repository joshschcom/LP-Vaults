// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPharaohSwapRouter} from "./interfaces/pharaoh/IPharaohSwapRouter.sol";

interface IPharaohCompounderVault {
    function owner() external view returns (address);
    function asset() external view returns (address);
    function swapRouter() external view returns (IPharaohSwapRouter);
}

/// @title PharaohRewardCompounder
/// @notice Converts Safe-held PHAR through Pharaoh and donates the resulting
///         asset directly to one of two pinned ERC-4626 vaults.
/// @dev The Safe should call this immediately after a vault harvest in the
///      same atomic batch. Direct asset delivery raises the value of existing
///      shares without minting new shares to the Safe.
contract PharaohRewardCompounder is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PHAR_UNIT = 1e18;

    address public immutable safe;
    IERC20 public immutable phar;
    IERC20 public immutable wavax;
    IERC20 public immutable usdc;
    IPharaohSwapRouter public immutable swapRouter;
    address public immutable usdcVault;
    address public immutable wavaxVault;
    int24 public immutable pharWavaxTickSpacing;
    int24 public immutable wavaxUsdcTickSpacing;

    struct Config {
        address safe;
        IERC20 phar;
        IERC20 wavax;
        IERC20 usdc;
        IPharaohSwapRouter swapRouter;
        address usdcVault;
        address wavaxVault;
        int24 pharWavaxTickSpacing;
        int24 wavaxUsdcTickSpacing;
    }

    error Compounder__Unauthorized(address caller);
    error Compounder__MissingCode(address target);
    error Compounder__InvalidToken(address token);
    error Compounder__InvalidTokenDecimals(address token, uint8 expected, uint8 actual);
    error Compounder__InvalidVault(address vault);
    error Compounder__InvalidTickSpacing(int24 tickSpacing);
    error Compounder__InvalidVaultConfiguration(address vault);
    error Compounder__InvalidPharBounds(uint256 minimumPharIn, uint256 maximumPharIn);
    error Compounder__InsufficientPhar(uint256 available, uint256 minimumRequired);
    error Compounder__InvalidMinimumRate(uint256 minimumAssetOutPerPhar);
    error Compounder__ZeroMinimumOutput();
    error Compounder__Expired(uint256 deadline, uint256 currentTimestamp);
    error Compounder__UnexpectedPharBalance(uint256 balance);
    error Compounder__UnexpectedAssetDelivery(uint256 routerAmountOut, uint256 vaultBalanceIncrease);
    error Compounder__NothingToRecover(address token);

    event RewardsCompounded(
        address indexed vault, address indexed asset, uint256 pharIn, uint256 assetOut, uint256 minimumAssetOut
    );
    event TokenRecovered(address indexed token, uint256 amount);

    modifier onlySafe() {
        if (msg.sender != safe) revert Compounder__Unauthorized(msg.sender);
        _;
    }

    constructor(Config memory config) {
        _requireCode(config.safe);
        _requireCode(address(config.phar));
        _requireCode(address(config.wavax));
        _requireCode(address(config.usdc));
        _requireCode(address(config.swapRouter));
        _requireCode(config.usdcVault);
        _requireCode(config.wavaxVault);

        if (
            address(config.phar) == address(config.wavax) || address(config.phar) == address(config.usdc)
                || address(config.wavax) == address(config.usdc)
        ) revert Compounder__InvalidToken(address(config.phar));
        if (config.usdcVault == config.wavaxVault) revert Compounder__InvalidVault(config.usdcVault);
        if (config.pharWavaxTickSpacing <= 0) {
            revert Compounder__InvalidTickSpacing(config.pharWavaxTickSpacing);
        }
        if (config.wavaxUsdcTickSpacing <= 0) {
            revert Compounder__InvalidTickSpacing(config.wavaxUsdcTickSpacing);
        }

        _requireDecimals(address(config.phar), 18);
        _requireDecimals(address(config.wavax), 18);
        _requireDecimals(address(config.usdc), 6);
        _requireVault(config.usdcVault, config.safe, address(config.usdc), config.swapRouter);
        _requireVault(config.wavaxVault, config.safe, address(config.wavax), config.swapRouter);

        safe = config.safe;
        phar = config.phar;
        wavax = config.wavax;
        usdc = config.usdc;
        swapRouter = config.swapRouter;
        usdcVault = config.usdcVault;
        wavaxVault = config.wavaxVault;
        pharWavaxTickSpacing = config.pharWavaxTickSpacing;
        wavaxUsdcTickSpacing = config.wavaxUsdcTickSpacing;
    }

    /// @notice Pulls a bounded amount of PHAR from the Safe, swaps it through
    ///         the pinned Pharaoh route, and sends the output to `vault`.
    /// @param vault Must be exactly `usdcVault` or `wavaxVault`.
    /// @param minimumPharIn Reverts if the Safe balance is below this amount.
    /// @param maximumPharIn Caps the amount pulled; use `type(uint256).max` to
    ///        process the Safe's complete PHAR balance after an atomic harvest.
    /// @param minimumAssetOutPerPhar Minimum raw asset units required per 1e18
    ///        PHAR. For USDC this uses six-decimal raw units; WAVAX uses 18.
    /// @param deadline Absolute timestamp enforced here and by Pharaoh.
    function compound(
        address vault,
        uint256 minimumPharIn,
        uint256 maximumPharIn,
        uint256 minimumAssetOutPerPhar,
        uint256 deadline
    ) external onlySafe nonReentrant returns (uint256 pharIn, uint256 assetOut) {
        if (minimumPharIn == 0 || maximumPharIn < minimumPharIn) {
            revert Compounder__InvalidPharBounds(minimumPharIn, maximumPharIn);
        }
        if (minimumAssetOutPerPhar == 0) {
            revert Compounder__InvalidMinimumRate(minimumAssetOutPerPhar);
        }
        if (deadline < block.timestamp) revert Compounder__Expired(deadline, block.timestamp);

        IERC20 outputAsset;
        bool outputIsUsdc;
        if (vault == usdcVault) {
            outputAsset = usdc;
            outputIsUsdc = true;
        } else if (vault == wavaxVault) {
            outputAsset = wavax;
        } else {
            revert Compounder__InvalidVault(vault);
        }

        uint256 existingPhar = phar.balanceOf(address(this));
        if (existingPhar != 0) {
            phar.safeTransfer(safe, existingPhar);
            emit TokenRecovered(address(phar), existingPhar);
        }

        uint256 available = phar.balanceOf(safe);
        pharIn = Math.min(available, maximumPharIn);
        if (pharIn < minimumPharIn) revert Compounder__InsufficientPhar(available, minimumPharIn);

        uint256 minimumAssetOut = Math.mulDiv(pharIn, minimumAssetOutPerPhar, PHAR_UNIT);
        if (minimumAssetOut == 0) revert Compounder__ZeroMinimumOutput();

        uint256 vaultBalanceBefore = outputAsset.balanceOf(vault);
        phar.safeTransferFrom(safe, address(this), pharIn);
        phar.forceApprove(address(swapRouter), pharIn);

        if (outputIsUsdc) {
            assetOut = swapRouter.exactInput(
                IPharaohSwapRouter.ExactInputParams({
                    path: abi.encodePacked(
                        address(phar), pharWavaxTickSpacing, address(wavax), wavaxUsdcTickSpacing, address(usdc)
                    ),
                    recipient: vault,
                    deadline: deadline,
                    amountIn: pharIn,
                    amountOutMinimum: minimumAssetOut
                })
            );
        } else {
            assetOut = swapRouter.exactInputSingle(
                IPharaohSwapRouter.ExactInputSingleParams({
                    tokenIn: address(phar),
                    tokenOut: address(wavax),
                    tickSpacing: pharWavaxTickSpacing,
                    recipient: vault,
                    deadline: deadline,
                    amountIn: pharIn,
                    amountOutMinimum: minimumAssetOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        phar.forceApprove(address(swapRouter), 0);
        uint256 remainingPhar = phar.balanceOf(address(this));
        if (remainingPhar != 0) revert Compounder__UnexpectedPharBalance(remainingPhar);

        uint256 vaultBalanceIncrease = outputAsset.balanceOf(vault) - vaultBalanceBefore;
        if (vaultBalanceIncrease != assetOut) {
            revert Compounder__UnexpectedAssetDelivery(assetOut, vaultBalanceIncrease);
        }

        emit RewardsCompounded(vault, address(outputAsset), pharIn, assetOut, minimumAssetOut);
    }

    /// @notice Returns an accidentally transferred ERC-20 balance to the Safe.
    /// @dev The recipient is fixed; this contract never grants a caller-selected sweep.
    function recoverToken(IERC20 token) external onlySafe nonReentrant returns (uint256 amount) {
        amount = token.balanceOf(address(this));
        if (amount == 0) revert Compounder__NothingToRecover(address(token));
        token.safeTransfer(safe, amount);
        emit TokenRecovered(address(token), amount);
    }

    function _requireCode(address target) private view {
        if (target == address(0) || target.code.length == 0) revert Compounder__MissingCode(target);
    }

    function _requireDecimals(address token, uint8 expected) private view {
        uint8 actual = IERC20Metadata(token).decimals();
        if (actual != expected) revert Compounder__InvalidTokenDecimals(token, expected, actual);
    }

    function _requireVault(
        address vault,
        address expectedOwner,
        address expectedAsset,
        IPharaohSwapRouter expectedRouter
    ) private view {
        IPharaohCompounderVault target = IPharaohCompounderVault(vault);
        if (
            target.owner() != expectedOwner || target.asset() != expectedAsset
                || address(target.swapRouter()) != address(expectedRouter)
        ) revert Compounder__InvalidVaultConfiguration(vault);
    }
}
