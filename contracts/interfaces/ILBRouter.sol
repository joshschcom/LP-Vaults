// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILBPair} from "./ILBPair.sol";

/// @title ILBRouter — exact V2.2 interface from lfj-gg/joe-v2
interface ILBRouter {
    /// @dev Identifies which pool version to route through
    enum Version {
        V1,
        V2,
        V2_1,
        V2_2
    }

    /// @dev Full parameter set for addLiquidity / addLiquidityNATIVE
    /// distributionX and distributionY each must sum to exactly 1e18 (or 0)
    struct LiquidityParameters {
        IERC20 tokenX;
        IERC20 tokenY;
        uint256 binStep;        // e.g. 1 for 1bps stable pair
        uint256 amountX;
        uint256 amountY;
        uint256 amountXMin;     // slippage floor
        uint256 amountYMin;     // slippage floor
        uint256 activeIdDesired;
        uint256 idSlippage;     // bins of tolerance around activeIdDesired
        int256[] deltaIds;      // offsets from activeId, e.g. [-1, 0, 1]
        uint256[] distributionX;
        uint256[] distributionY;
        address to;
        address refundTo;
        uint256 deadline;
    }

    /// @dev Swap routing path
    struct Path {
        uint256[] pairBinSteps; // bin step of each hop
        Version[] versions;     // version of each hop
        IERC20[] tokenPath;     // token[0] → token[n], length = hops + 1
    }

    function addLiquidity(LiquidityParameters calldata liquidityParameters)
        external
        returns (
            uint256 amountXAdded,
            uint256 amountYAdded,
            uint256 amountXLeft,
            uint256 amountYLeft,
            uint256[] memory depositIds,
            uint256[] memory liquidityMinted
        );

    function removeLiquidity(
        IERC20 tokenX,
        IERC20 tokenY,
        uint16 binStep,          // NOTE: uint16, not uint256
        uint256 amountXMin,
        uint256 amountYMin,
        uint256[] memory ids,
        uint256[] memory amounts,
        address to,
        uint256 deadline
    ) external returns (uint256 amountX, uint256 amountY);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Path memory path,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function getSwapOut(ILBPair lbPair, uint128 amountIn, bool swapForY)
        external
        view
        returns (uint128 amountInLeft, uint128 amountOut, uint128 fee);
}
