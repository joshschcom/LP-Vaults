// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {IPharaohVaultOracle} from "../interfaces/pharaoh/IPharaohVaultOracle.sol";

/// @notice Values one token against another using two Chainlink USD feeds.
/// @dev Intended for USDC/USDt, where `assetFeed` is USDC/USD and
///      `pairedFeed` is USDT/USD.
contract ChainlinkRatioOracle is IPharaohVaultOracle {
    error Oracle__ZeroAddress();
    error Oracle__UnsupportedDecimals(uint8 decimals);
    error Oracle__InvalidAnswer(address feed);
    error Oracle__StaleAnswer(address feed, uint256 updatedAt);

    address public immutable override asset;
    address public immutable override pairedToken;
    AggregatorV3Interface public immutable assetFeed;
    AggregatorV3Interface public immutable pairedFeed;
    uint256 public immutable maxStaleness;

    uint256 private immutable _assetUnit;
    uint256 private immutable _pairedUnit;
    uint256 private immutable _assetFeedScale;
    uint256 private immutable _pairedFeedScale;

    constructor(
        address asset_,
        address pairedToken_,
        AggregatorV3Interface assetFeed_,
        AggregatorV3Interface pairedFeed_,
        uint256 maxStaleness_
    ) {
        if (
            asset_ == address(0) || pairedToken_ == address(0) || address(assetFeed_) == address(0)
                || address(pairedFeed_) == address(0) || maxStaleness_ == 0
        ) revert Oracle__ZeroAddress();

        uint8 assetDecimals = IERC20Metadata(asset_).decimals();
        uint8 pairedDecimals = IERC20Metadata(pairedToken_).decimals();
        uint8 assetFeedDecimals = assetFeed_.decimals();
        uint8 pairedFeedDecimals = pairedFeed_.decimals();
        if (assetDecimals > 18) revert Oracle__UnsupportedDecimals(assetDecimals);
        if (pairedDecimals > 18) revert Oracle__UnsupportedDecimals(pairedDecimals);
        if (assetFeedDecimals > 18) revert Oracle__UnsupportedDecimals(assetFeedDecimals);
        if (pairedFeedDecimals > 18) revert Oracle__UnsupportedDecimals(pairedFeedDecimals);

        asset = asset_;
        pairedToken = pairedToken_;
        assetFeed = assetFeed_;
        pairedFeed = pairedFeed_;
        maxStaleness = maxStaleness_;
        _assetUnit = 10 ** assetDecimals;
        _pairedUnit = 10 ** pairedDecimals;
        _assetFeedScale = 10 ** (18 - assetFeedDecimals);
        _pairedFeedScale = 10 ** (18 - pairedFeedDecimals);

        _readPrice(assetFeed_, _assetFeedScale);
        _readPrice(pairedFeed_, _pairedFeedScale);
    }

    function quotePairToAsset(uint256 pairAmount) external view override returns (uint256 assetAmount) {
        uint256 assetPrice = _readPrice(assetFeed, _assetFeedScale);
        uint256 pairedPrice = _readPrice(pairedFeed, _pairedFeedScale);
        assetAmount = Math.mulDiv(pairAmount, pairedPrice * _assetUnit, assetPrice * _pairedUnit);
    }

    function quoteAssetToPair(uint256 assetAmount) external view override returns (uint256 pairAmount) {
        uint256 assetPrice = _readPrice(assetFeed, _assetFeedScale);
        uint256 pairedPrice = _readPrice(pairedFeed, _pairedFeedScale);
        pairAmount = Math.mulDiv(assetAmount, assetPrice * _pairedUnit, pairedPrice * _assetUnit);
    }

    function prices() external view returns (uint256 assetUsdPrice18, uint256 pairedUsdPrice18) {
        assetUsdPrice18 = _readPrice(assetFeed, _assetFeedScale);
        pairedUsdPrice18 = _readPrice(pairedFeed, _pairedFeedScale);
    }

    function _readPrice(AggregatorV3Interface feed, uint256 scale) private view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) {
            revert Oracle__InvalidAnswer(address(feed));
        }
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxStaleness) {
            revert Oracle__StaleAnswer(address(feed), updatedAt);
        }
        return uint256(answer) * scale;
    }
}
