// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Script, console2} from "forge-std/Script.sol";

import {PharaohRewardCompounder} from "../contracts/PharaohRewardCompounder.sol";

interface IPharaohRewardHarvester {
    function harvestRewards(bool claimPosition, uint256 minimumPharFromXPhar)
        external
        returns (uint256 pharForwarded, uint256 xPharExited);

    function totalSupply() external view returns (uint256);
}

/// @notice Fork-only execution of the exact Safe reward-compounding call order.
/// @dev This script has no broadcast path. It is invoked by the batch generator
///      before a Transaction Builder JSON file is written.
contract SimulatePharaohRewardCompound is Script {
    uint256 private constant AVALANCHE_CHAIN_ID = 43_114;
    uint256 private constant PHAR_UNIT = 1 ether;

    address private constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    IERC20 private constant PHAR = IERC20(0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7);
    IERC20 private constant XPHAR = IERC20(0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A);
    IERC20 private constant WAVAX = IERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    IERC20 private constant USDC = IERC20(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);

    address private constant USDC_VAULT = 0x855bF832f26a294d28500db59eE941dE3d654129;
    address private constant WAVAX_VAULT = 0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8;
    PharaohRewardCompounder private constant COMPOUNDER =
        PharaohRewardCompounder(0xe7fCeE8d52B5340168eb33804c49BE086cE04cB0);

    function run() external {
        require(block.chainid == AVALANCHE_CHAIN_ID, "RewardSim: wrong chain");

        address targetVault = vm.envAddress("TARGET_VAULT");
        uint256 expectedSafePhar = vm.envUint("EXPECTED_SAFE_PHAR");
        uint256 approvalAmount = vm.envUint("APPROVAL_AMOUNT");
        uint256 minimumPharIn = vm.envUint("MINIMUM_PHAR_IN");
        uint256 maximumPharIn = vm.envUint("MAXIMUM_PHAR_IN");
        uint256 minimumRate = vm.envUint("MINIMUM_ASSET_OUT_PER_PHAR");
        uint256 deadline = vm.envUint("DEADLINE");
        address carryVault = vm.envOr("CARRY_VAULT", address(0));
        uint256 carryPharIn = vm.envOr("CARRY_PHAR_IN", uint256(0));
        uint256 carryMinimumRate = vm.envOr("CARRY_MINIMUM_ASSET_OUT_PER_PHAR", uint256(0));

        require(targetVault == USDC_VAULT || targetVault == WAVAX_VAULT, "RewardSim: invalid target");
        require(PHAR.balanceOf(SAFE) == expectedSafePhar, "RewardSim: Safe PHAR changed");
        require(PHAR.allowance(SAFE, address(COMPOUNDER)) == 0, "RewardSim: Safe allowance");
        require(
            PHAR.allowance(address(COMPOUNDER), address(COMPOUNDER.swapRouter())) == 0, "RewardSim: router allowance"
        );
        require(deadline >= block.timestamp, "RewardSim: expired");
        require(minimumPharIn != 0 && maximumPharIn >= minimumPharIn, "RewardSim: target bounds");

        if (carryPharIn == 0) {
            require(carryVault == address(0) && carryMinimumRate == 0, "RewardSim: unexpected carry");
        } else {
            require(carryVault == USDC_VAULT || carryVault == WAVAX_VAULT, "RewardSim: invalid carry vault");
            require(carryVault != targetVault, "RewardSim: carry equals target");
            require(carryPharIn <= expectedSafePhar && carryMinimumRate != 0, "RewardSim: invalid carry");
        }
        require(approvalAmount == carryPharIn + maximumPharIn, "RewardSim: approval mismatch");

        IERC20 targetAsset = targetVault == USDC_VAULT ? USDC : WAVAX;
        IERC20 carryAsset = carryVault == USDC_VAULT ? USDC : WAVAX;
        uint256 targetAssetsBefore = targetAsset.balanceOf(targetVault);
        uint256 targetSupplyBefore = IPharaohRewardHarvester(targetVault).totalSupply();
        uint256 carryAssetsBefore = carryPharIn == 0 ? 0 : carryAsset.balanceOf(carryVault);
        uint256 carrySupplyBefore = carryPharIn == 0 ? 0 : IPharaohRewardHarvester(carryVault).totalSupply();
        uint256 safeXPharBefore = XPHAR.balanceOf(SAFE);
        uint256 targetXPharBefore = XPHAR.balanceOf(targetVault);
        uint256 compounderPharBefore = PHAR.balanceOf(address(COMPOUNDER));
        uint256 compounderWavaxBefore = WAVAX.balanceOf(address(COMPOUNDER));
        uint256 compounderUsdcBefore = USDC.balanceOf(address(COMPOUNDER));

        vm.startPrank(SAFE);
        require(PHAR.approve(address(COMPOUNDER), approvalAmount), "RewardSim: approve failed");

        uint256 carryOut;
        if (carryPharIn != 0) {
            (uint256 actualCarryIn, uint256 actualCarryOut) =
                COMPOUNDER.compound(carryVault, carryPharIn, carryPharIn, carryMinimumRate, deadline);
            require(actualCarryIn == carryPharIn, "RewardSim: carry input mismatch");
            carryOut = actualCarryOut;
        }

        (uint256 harvestedPhar, uint256 exitedXPhar) = IPharaohRewardHarvester(targetVault).harvestRewards(true, 0);
        require(exitedXPhar == 0, "RewardSim: xPHAR exited");

        (uint256 pharIn, uint256 assetOut) =
            COMPOUNDER.compound(targetVault, minimumPharIn, maximumPharIn, minimumRate, deadline);
        require(PHAR.approve(address(COMPOUNDER), 0), "RewardSim: revoke failed");
        vm.stopPrank();

        require(pharIn >= minimumPharIn, "RewardSim: target input below minimum");
        require(pharIn <= maximumPharIn, "RewardSim: target input above maximum");
        require(assetOut >= Math.mulDiv(pharIn, minimumRate, PHAR_UNIT), "RewardSim: target output below minimum");
        require(targetAsset.balanceOf(targetVault) - targetAssetsBefore == assetOut, "RewardSim: target donation");
        require(
            IPharaohRewardHarvester(targetVault).totalSupply() == targetSupplyBefore, "RewardSim: target shares changed"
        );

        if (carryPharIn != 0) {
            require(
                carryOut >= Math.mulDiv(carryPharIn, carryMinimumRate, PHAR_UNIT),
                "RewardSim: carry output below minimum"
            );
            require(carryAsset.balanceOf(carryVault) - carryAssetsBefore == carryOut, "RewardSim: carry donation");
            require(
                IPharaohRewardHarvester(carryVault).totalSupply() == carrySupplyBefore,
                "RewardSim: carry shares changed"
            );
        }

        uint256 expectedSafePharAfter = expectedSafePhar - carryPharIn + compounderPharBefore + harvestedPhar - pharIn;
        require(PHAR.balanceOf(SAFE) == expectedSafePharAfter, "RewardSim: Safe PHAR conservation");
        require(PHAR.balanceOf(address(COMPOUNDER)) == 0, "RewardSim: compounder PHAR remains");
        require(WAVAX.balanceOf(address(COMPOUNDER)) == compounderWavaxBefore, "RewardSim: compounder WAVAX changed");
        require(USDC.balanceOf(address(COMPOUNDER)) == compounderUsdcBefore, "RewardSim: compounder USDC changed");
        require(PHAR.allowance(SAFE, address(COMPOUNDER)) == 0, "RewardSim: Safe allowance remains");
        require(
            PHAR.allowance(address(COMPOUNDER), address(COMPOUNDER.swapRouter())) == 0,
            "RewardSim: router allowance remains"
        );
        require(XPHAR.balanceOf(SAFE) == safeXPharBefore, "RewardSim: Safe xPHAR changed");
        require(XPHAR.balanceOf(targetVault) >= targetXPharBefore, "RewardSim: vault xPHAR decreased");

        console2.log("Fork-simulated target vault:", targetVault);
        console2.log("Estimated PHAR harvested:", harvestedPhar);
        console2.log("PHAR compounded to target:", pharIn);
        console2.log("Target asset donated:", assetOut);
        console2.log("Safe PHAR left outside bounds:", expectedSafePharAfter);
        if (carryPharIn != 0) {
            console2.log("Historical carry vault:", carryVault);
            console2.log("Historical PHAR carry compounded:", carryPharIn);
            console2.log("Historical carry asset donated:", carryOut);
        }
        console2.log("Simulation only; no transaction was broadcast.");
    }
}
