// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ILBPair — V2.2 pair interface (lfj-gg/joe-v2)
/// The LBPair IS its own ERC-1155-style token (ILBToken), so
/// approveForAll / totalSupply(id) are on the pair itself.
interface ILBPair {
    // ─── State views ────────────────────────────────────────────────────────

    /// @notice Returns the pair's tokenX
    function getTokenX() external view returns (address);

    /// @notice Returns the pair's tokenY
    function getTokenY() external view returns (address);

    /// @notice Returns the active bin id (current price bin)
    function getActiveId() external view returns (uint24 activeId);

    /// @notice Returns bin step in basis-points (e.g. 1 = 0.01%)
    function getBinStep() external view returns (uint16);

    /// @notice Reserves of tokenX and tokenY in a specific bin
    function getBin(uint24 id) external view returns (uint128 binReserveX, uint128 binReserveY);

    // ─── ILBToken (inherited) ────────────────────────────────────────────────

    /// @notice Total LB-token supply minted for a specific bin
    function totalSupply(uint256 id) external view returns (uint256);

    /// @notice Approve/revoke `spender` to manage all tokens of the caller
    /// Must be called by the vault on itself before removeLiquidity via router
    function approveForAll(address spender, bool approved) external;

    /// @notice Check approval status
    function isApprovedForAll(address owner, address spender) external view returns (bool);
}
