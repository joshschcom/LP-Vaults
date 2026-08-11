// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPharaohVaultOracle} from "../interfaces/pharaoh/IPharaohVaultOracle.sol";
import {ISAVAX} from "../interfaces/ISAVAX.sol";

/// @notice Values sAVAX in WAVAX using BENQI's protocol exchange rate.
/// @dev WAVAX and native AVAX have the same denomination. This avoids treating
///      a volatile CL spot price as the vault's accounting oracle.
contract SAVAXRateOracle is IPharaohVaultOracle {
    error Oracle__ZeroAddress();
    error Oracle__InvalidRate();

    address public immutable override asset;
    address public immutable override pairedToken;
    ISAVAX public immutable sAVAX;

    constructor(address wavax_, ISAVAX sAVAX_) {
        if (wavax_ == address(0) || address(sAVAX_) == address(0)) revert Oracle__ZeroAddress();
        if (sAVAX_.getPooledAvaxByShares(1 ether) == 0 || sAVAX_.getSharesByPooledAvax(1 ether) == 0) {
            revert Oracle__InvalidRate();
        }
        asset = wavax_;
        pairedToken = address(sAVAX_);
        sAVAX = sAVAX_;
    }

    function quotePairToAsset(uint256 pairAmount) external view override returns (uint256 assetAmount) {
        assetAmount = sAVAX.getPooledAvaxByShares(pairAmount);
    }

    function quoteAssetToPair(uint256 assetAmount) external view override returns (uint256 pairAmount) {
        pairAmount = sAVAX.getSharesByPooledAvax(assetAmount);
    }
}
