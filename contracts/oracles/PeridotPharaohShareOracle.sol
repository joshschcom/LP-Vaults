// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @dev Minimal ABI shared by Peridot's PriceOracle implementations.
interface IPeridotPriceOracle {
    function getUnderlyingPrice(address pToken) external view returns (uint256);
}

/// @dev Minimal ABI shared by Peridot ERC-20 markets.
interface IPeridotMarket {
    function underlying() external view returns (address);
}

/// @title PeridotPharaohShareOracle
/// @notice Adds conservative Pharaoh ERC-4626 share prices to an existing
///         Peridot oracle without changing the prices of existing markets.
/// @dev Peridot inherits Compound's oracle scaling: an underlying with `d`
///      decimals requires a USD price scaled by 10^(36-d), not uniformly 1e18.
///      The registered Pharaoh vault's convertToAssets() path already applies
///      its paired-token haircut and price-safety checks. Any unsafe/stale
///      vault or Chainlink read returns zero so Peridot fails closed.
contract PeridotPharaohShareOracle is IPeridotPriceOracle, Ownable {
    uint256 private constant MAX_STALENESS = 7 days;

    struct VaultConfig {
        AggregatorV3Interface assetUsdFeed;
        uint64 maxStaleness;
        uint8 assetDecimals;
        uint8 shareDecimals;
        uint64 feedScale;
    }

    error Oracle__ZeroAddress();
    error Oracle__InvalidConfiguration();
    error Oracle__InvalidFeed();
    error Oracle__InvalidVault();

    IPeridotPriceOracle public immutable baseOracle;
    mapping(address vaultShare => VaultConfig config) public vaultConfigs;

    event VaultRegistered(address indexed vaultShare, address indexed asset, address indexed assetUsdFeed);
    event VaultRemoved(address indexed vaultShare);

    constructor(address owner_, IPeridotPriceOracle baseOracle_) Ownable(owner_) {
        if (owner_ == address(0) || address(baseOracle_) == address(0)) revert Oracle__ZeroAddress();
        baseOracle = baseOracle_;
    }

    /// @notice Registers or replaces the price configuration for one Pharaoh
    ///         vault-share token. Governance should be the Peridot Safe.
    function registerVault(IERC4626 vault, AggregatorV3Interface assetUsdFeed, uint64 maxStaleness) external onlyOwner {
        address vaultShare = address(vault);
        if (vaultShare == address(0) || address(assetUsdFeed) == address(0)) revert Oracle__ZeroAddress();
        if (maxStaleness == 0 || maxStaleness > MAX_STALENESS) revert Oracle__InvalidConfiguration();

        address asset;
        uint8 assetDecimals;
        uint8 shareDecimals;
        uint8 feedDecimals;
        try vault.asset() returns (address returnedAsset) {
            asset = returnedAsset;
        } catch {
            revert Oracle__InvalidVault();
        }
        if (asset == address(0)) revert Oracle__InvalidVault();

        try IERC20Metadata(asset).decimals() returns (uint8 returnedDecimals) {
            assetDecimals = returnedDecimals;
        } catch {
            revert Oracle__InvalidVault();
        }
        try IERC20Metadata(vaultShare).decimals() returns (uint8 returnedDecimals) {
            shareDecimals = returnedDecimals;
        } catch {
            revert Oracle__InvalidVault();
        }
        try assetUsdFeed.decimals() returns (uint8 returnedDecimals) {
            feedDecimals = returnedDecimals;
        } catch {
            revert Oracle__InvalidFeed();
        }
        if (assetDecimals > 18 || shareDecimals > 18 || feedDecimals > 18) {
            revert Oracle__InvalidConfiguration();
        }

        VaultConfig memory config = VaultConfig({
            assetUsdFeed: assetUsdFeed,
            maxStaleness: maxStaleness,
            assetDecimals: assetDecimals,
            shareDecimals: shareDecimals,
            feedScale: uint64(10 ** (18 - feedDecimals))
        });
        if (_readAssetUsdPrice(config) == 0) revert Oracle__InvalidFeed();
        if (_readAssetsPerWholeShare(vault, shareDecimals) == 0) revert Oracle__InvalidVault();

        vaultConfigs[vaultShare] = config;
        emit VaultRegistered(vaultShare, asset, address(assetUsdFeed));
    }

    function removeVault(address vaultShare) external onlyOwner {
        if (address(vaultConfigs[vaultShare].assetUsdFeed) == address(0)) revert Oracle__InvalidVault();
        delete vaultConfigs[vaultShare];
        emit VaultRemoved(vaultShare);
    }

    /// @inheritdoc IPeridotPriceOracle
    function getUnderlyingPrice(address pToken) external view returns (uint256) {
        address vaultShare = _marketUnderlying(pToken);
        VaultConfig memory config = vaultConfigs[vaultShare];
        if (vaultShare == address(0) || address(config.assetUsdFeed) == address(0)) {
            return baseOracle.getUnderlyingPrice(pToken);
        }

        uint256 shareUsdPrice18 = _shareUsdPrice18(IERC4626(vaultShare), config);
        if (shareUsdPrice18 == 0) return 0;

        // Compound/Peridot expects 10^(36-underlyingDecimals) scaling.
        return shareUsdPrice18 * (10 ** (18 - config.shareDecimals));
    }

    /// @notice Returns the USD value of one whole vault share, scaled to 1e18.
    function getShareUsdPrice(address vaultShare) external view returns (uint256) {
        VaultConfig memory config = vaultConfigs[vaultShare];
        if (address(config.assetUsdFeed) == address(0)) return 0;
        return _shareUsdPrice18(IERC4626(vaultShare), config);
    }

    function _shareUsdPrice18(IERC4626 vault, VaultConfig memory config) private view returns (uint256) {
        uint256 assetsPerWholeShare = _readAssetsPerWholeShare(vault, config.shareDecimals);
        if (assetsPerWholeShare == 0) return 0;

        uint256 assetUsdPrice18 = _readAssetUsdPrice(config);
        if (assetUsdPrice18 == 0) return 0;
        return Math.mulDiv(assetsPerWholeShare, assetUsdPrice18, 10 ** config.assetDecimals);
    }

    function _readAssetsPerWholeShare(IERC4626 vault, uint8 shareDecimals) private view returns (uint256) {
        try vault.convertToAssets(10 ** shareDecimals) returns (uint256 assetsPerWholeShare) {
            return assetsPerWholeShare;
        } catch {
            return 0;
        }
    }

    function _readAssetUsdPrice(VaultConfig memory config) private view returns (uint256) {
        try config.assetUsdFeed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (
                roundId == 0 || answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp
                    || answeredInRound < roundId || block.timestamp - updatedAt > config.maxStaleness
            ) return 0;
            return uint256(answer) * config.feedScale;
        } catch {
            return 0;
        }
    }

    function _marketUnderlying(address pToken) private view returns (address) {
        try IPeridotMarket(pToken).underlying() returns (address underlying) {
            return underlying;
        } catch {
            return address(0);
        }
    }
}
