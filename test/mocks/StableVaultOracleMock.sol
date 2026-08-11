// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStableVaultOracle} from "../../contracts/interfaces/IStableVaultOracle.sol";

contract StableVaultOracleMock is IStableVaultOracle {
    uint256 private constant BPS = 10_000;

    address public immutable override asset;
    address public immutable override pairedToken;
    uint256 public pairPriceBps = BPS;

    constructor(address asset_, address pairedToken_) {
        asset = asset_;
        pairedToken = pairedToken_;
    }

    function setPairPriceBps(uint256 newPairPriceBps) external {
        require(newPairPriceBps > 0, "zero price");
        pairPriceBps = newPairPriceBps;
    }

    function quotePairToAsset(uint256 pairAmount) external view returns (uint256 assetAmount) {
        return Math.mulDiv(pairAmount, pairPriceBps, BPS);
    }

    function quoteAssetToPair(uint256 assetAmount) external view returns (uint256 pairAmount) {
        return Math.mulDiv(assetAmount, BPS, pairPriceBps);
    }
}
