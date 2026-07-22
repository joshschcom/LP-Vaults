// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IBlackholeRouter — Solidly/Thena V2 style router used by Blackhole DEX
/// @dev route struct from Blackhole docs (https://docs.blackhole.xyz)
interface IBlackholeRouter {
    struct route {
        address pair;
        address from;
        address to;
        bool stable;
        bool concentrated;
        address receiver;
    }

    /// @notice Swap exact `amountIn` of routes[0].from along the given route path
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Add liquidity to a stable or volatile pair
    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @notice Remove liquidity from a stable or volatile pair
    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    /// @notice Quote the output amount for a given input through a single hop
    function getAmountOut(
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        bool stable
    ) external view returns (uint256 amountOut, bool isStable);
}
