// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @notice Verified Pharaoh Ramses V3 QuoterV2 interface.
/// @dev Quote functions intentionally are not view: the quoter invokes pool
///      swaps and obtains results by catching their reverts.
interface IPharaohQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        int24 tickSpacing;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInput(bytes calldata path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );

    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}
