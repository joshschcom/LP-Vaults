// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice BENQI liquid-staked AVAX exchange-rate methods used by the vault oracle.
interface ISAVAX {
    function getPooledAvaxByShares(uint256 sharesAmount) external view returns (uint256);
    function getSharesByPooledAvax(uint256 avaxAmount) external view returns (uint256);
}
