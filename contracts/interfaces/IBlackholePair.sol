// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IBlackholePair — Solidly/Thena V2 ERC-20 LP pair used by Blackhole DEX
interface IBlackholePair {
    /// @notice Reserves of token0 and token1 in the pair
    function getReserves()
        external
        view
        returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);

    /// @notice Total LP token supply (standard ERC-20, full range)
    function totalSupply() external view returns (uint256);

    /// @notice Returns true if this is a stable (sAMM) pair
    function stable() external view returns (bool);

    /// @notice token0 of the pair (lower address)
    function token0() external view returns (address);

    /// @notice token1 of the pair (higher address)
    function token1() external view returns (address);

    /// @notice LP balance of an account
    function balanceOf(address account) external view returns (uint256);

    /// @notice Approve router to spend LP tokens for removeLiquidity
    function approve(address spender, uint256 amount) external returns (bool);
}
