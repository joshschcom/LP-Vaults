// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {LFJStableVault} from "../contracts/LFJStableVault.sol";
import {ILBRouter} from "../contracts/interfaces/ILBRouter.sol";
import {ILBPair} from "../contracts/interfaces/ILBPair.sol";

contract LFJStableVaultV2Mock is LFJStableVault {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Avalanche mainnet fork coverage for the live LFJ V2.2 AUSD/USDC pool.
///
/// Run:
///   forge test --fork-url $AVAX_MAINNET_RPC_URL --match-contract LFJStableVaultMainnetForkTest -vvv
contract LFJStableVaultMainnetForkTest is Test {
    address constant LB_ROUTER = 0x18556DA13313f3532c54711497A8FedAC273220E;

    address constant AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant AUSD_USDC_PAIR = 0x8573F98175D816d520248B5fACF40D309B1c9ceE;
    bytes32 constant ERC1967_ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    LFJStableVault vault;
    address proxyAdmin;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address nonKeeper = makeAddr("nonKeeper");
    address keeper = makeAddr("keeper");
    bool forkConfigured;

    function setUp() public {
        if (block.chainid != 43114) {
            string memory rpcUrl = vm.envOr("AVAX_MAINNET_RPC_URL", string(""));
            if (bytes(rpcUrl).length == 0) return;
            vm.createSelectFork(rpcUrl);
        }

        forkConfigured = block.chainid == 43114;
        if (!forkConfigured) return;

        LFJStableVault implementation = new LFJStableVault();
        bytes memory initData = abi.encodeCall(
            LFJStableVault.initialize,
            (
                IERC20(USDC), // ERC-4626 asset; USDC is tokenY in the live pair
                IERC20(AUSD),
                IERC20(USDC),
                ILBRouter(LB_ROUTER),
                ILBPair(AUSD_USDC_PAIR),
                ILBRouter.Version.V2_2,
                keeper,
                address(this),
                1_000_000e6,
                2,
                50
            )
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(this), initData);
        vault = LFJStableVault(address(proxy));
        proxyAdmin = address(uint160(uint256(vm.load(address(proxy), ERC1967_ADMIN_SLOT))));

        deal(USDC, alice, 20_000e6);
        deal(USDC, bob, 20_000e6);
    }

    function test_livePairMetadata() public {
        if (!forkConfigured) return;

        ILBPair pair = ILBPair(AUSD_USDC_PAIR);

        assertEq(pair.getTokenX(), AUSD, "unexpected tokenX");
        assertEq(pair.getTokenY(), USDC, "unexpected tokenY");
        assertEq(pair.getBinStep(), 1, "unexpected bin step");
        assertEq(vault.asset(), USDC, "vault asset should be USDC");
        assertFalse(vault.assetIsTokenX(), "USDC should be tokenY");
        assertEq(vault.owner(), address(this), "unexpected owner");
        assertGt(proxyAdmin.code.length, 0, "proxy admin missing");
    }

    function test_depositUSDCIntoLivePair() public {
        if (!forkConfigured) return;

        uint256 depositAmount = 1_000e6;

        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        console2.log("shares", shares);
        console2.log("total assets", vault.totalAssets());

        assertGt(shares, 0, "no shares minted");
        assertGt(vault.getDepositedBins().length, 0, "no bins tracked");
        assertApproxEqRel(vault.totalAssets(), depositAmount, 0.02e18, "totalAssets off by >2%");
    }

    function test_redeemUSDCFromLivePair() public {
        if (!forkConfigured) return;

        uint256 depositAmount = 500e6;

        vm.startPrank(alice);
        IERC20(USDC).approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);

        uint256 beforeRedeem = IERC20(USDC).balanceOf(alice);
        vault.redeem(shares, alice, alice);
        uint256 received = IERC20(USDC).balanceOf(alice) - beforeRedeem;
        vm.stopPrank();

        console2.log("deposited", depositAmount);
        console2.log("received", received);

        assertGt(received, (depositAmount * 98) / 100, "lost >2% on round trip");
        assertEq(vault.getDepositedBins().length, 0, "bins should be cleaned");
    }

    function test_withdrawExactAssetsFromLivePair() public {
        if (!forkConfigured) return;

        _depositUSDC(alice, 1_000e6);

        uint256 withdrawAmount = 250e6;
        uint256 beforeWithdraw = IERC20(USDC).balanceOf(alice);

        vm.prank(alice);
        uint256 burnedShares = vault.withdraw(withdrawAmount, alice, alice);

        uint256 received = IERC20(USDC).balanceOf(alice) - beforeWithdraw;

        assertEq(received, withdrawAmount, "withdraw did not return exact assets");
        assertGt(burnedShares, 0, "no shares burned");
        assertGt(vault.balanceOf(alice), 0, "partial withdraw burned all shares");
        assertGt(vault.getDepositedBins().length, 0, "partial withdraw cleared all bins");
    }

    function test_keeperCanRebalanceLivePair() public {
        if (!forkConfigured) return;

        _depositUSDC(alice, 1_000e6);

        uint256 beforeRebalance = vault.totalAssets();

        vm.prank(keeper);
        vault.rebalance();

        assertApproxEqRel(vault.totalAssets(), beforeRebalance, 0.02e18, "rebalance lost >2%");
    }

    function test_partialWithdrawKeepsRemainingUserAccountingSane() public {
        if (!forkConfigured) return;

        uint256 aliceShares = _depositUSDC(alice, 1_000e6);
        uint256 bobShares = _depositUSDC(bob, 1_000e6);
        uint256 bobPreviewBefore = vault.previewRedeem(bobShares);

        vm.prank(alice);
        vault.redeem(aliceShares / 2, alice, alice);

        uint256 bobPreviewAfter = vault.previewRedeem(bobShares);

        assertGt(vault.balanceOf(alice), 0, "alice should retain shares");
        assertEq(vault.balanceOf(bob), bobShares, "bob shares changed");
        assertApproxEqRel(bobPreviewAfter, bobPreviewBefore, 0.02e18, "bob value moved too much");
        assertGt(vault.getDepositedBins().length, 0, "all bins unexpectedly cleared");
    }

    function test_previewAndConvertStayConservativeAfterDeployment() public {
        if (!forkConfigured) return;

        uint256 shares = _depositUSDC(alice, 1_000e6);
        uint256 previewAssets = vault.previewRedeem(shares);
        uint256 convertedAssets = vault.convertToAssets(shares);
        uint256 previewShares = vault.previewDeposit(100e6);

        assertGt(previewAssets, 0, "previewRedeem returned zero");
        assertEq(previewAssets, convertedAssets, "previewRedeem and convertToAssets diverged");
        assertLe(previewAssets, vault.totalAssets(), "preview overpromises vault assets");
        assertGt(previewShares, 0, "previewDeposit returned zero");
        assertLe(previewShares, 101e6, "previewDeposit unexpectedly generous");
    }

    function test_liveDepositCapUsesDeployedAssets() public {
        if (!forkConfigured) return;

        vault.setDepositCap(600e6);
        _depositUSDC(alice, 500e6);

        assertLt(vault.maxDeposit(alice), 110e6, "cap should account for LP assets");

        vm.startPrank(bob);
        IERC20(USDC).approve(address(vault), 200e6);
        vm.expectRevert();
        vault.deposit(200e6, bob);
        vm.stopPrank();
    }

    function test_pauseBlocksDepositsButAllowsRedeem() public {
        if (!forkConfigured) return;

        uint256 shares = _depositUSDC(alice, 500e6);

        vault.pause();

        vm.startPrank(bob);
        IERC20(USDC).approve(address(vault), 100e6);
        vm.expectRevert();
        vault.deposit(100e6, bob);
        vm.stopPrank();

        vm.prank(alice);
        uint256 redeemed = vault.redeem(shares, alice, alice);

        assertGt(redeemed, 0, "paused redeem returned zero");
    }

    function test_liveEmergencyWithdrawClearsBinsAndPauses() public {
        if (!forkConfigured) return;

        _depositUSDC(alice, 1_000e6);
        uint256 assetsBefore = vault.totalAssets();

        vm.prank(alice);
        vm.expectRevert();
        vault.emergencyWithdrawLP();

        vault.emergencyWithdrawLP();

        assertEq(vault.getDepositedBins().length, 0, "bins not cleared");
        assertTrue(vault.paused(), "vault not paused");
        assertGt(vault.totalAssets(), (assetsBefore * 98) / 100, "emergency value loss too high");
        assertGt(IERC20(USDC).balanceOf(address(vault)) + IERC20(AUSD).balanceOf(address(vault)), 0, "no idle funds");
    }

    function test_livePermissions() public {
        if (!forkConfigured) return;

        _depositUSDC(alice, 500e6);

        vm.prank(nonKeeper);
        vm.expectRevert();
        vault.rebalance();

        vm.prank(alice);
        vm.expectRevert();
        vault.setDepositCap(1_000e6);

        vm.prank(alice);
        vm.expectRevert();
        vault.setSlippage(30);
    }

    function test_proxyUpgradePreservesVaultState() public {
        if (!forkConfigured) return;

        uint256 shares = _depositUSDC(alice, 1_000e6);
        uint256 assetsBefore = vault.totalAssets();
        uint256 binCountBefore = vault.getDepositedBins().length;

        LFJStableVaultV2Mock newImplementation = new LFJStableVaultV2Mock();

        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(vault))),
            address(newImplementation),
            bytes("")
        );

        LFJStableVaultV2Mock upgradedVault = LFJStableVaultV2Mock(address(vault));

        assertEq(upgradedVault.version(), 2, "upgrade did not take effect");
        assertEq(upgradedVault.balanceOf(alice), shares, "shares changed during upgrade");
        assertEq(upgradedVault.getDepositedBins().length, binCountBefore, "bin count changed during upgrade");
        assertEq(upgradedVault.depositCap(), 1_000_000e6, "deposit cap changed during upgrade");
        assertEq(upgradedVault.slippageBps(), 50, "slippage changed during upgrade");
        assertEq(upgradedVault.rebalancer(), keeper, "rebalancer changed during upgrade");
        assertApproxEqRel(upgradedVault.totalAssets(), assetsBefore, 0.001e18, "assets changed during upgrade");
    }

    function test_onlyProxyAdminOwnerCanUpgrade() public {
        if (!forkConfigured) return;

        LFJStableVaultV2Mock newImplementation = new LFJStableVaultV2Mock();

        vm.prank(nonKeeper);
        vm.expectRevert();
        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(vault))),
            address(newImplementation),
            bytes("")
        );
    }

    function test_slippageCapStillEnforced() public {
        if (!forkConfigured) return;

        vm.expectRevert();
        vault.setSlippage(201);
    }

    function test_tinyDepositStaysRedeemable() public {
        if (!forkConfigured) return;

        uint256 shares = _depositUSDC(alice, 1);

        assertEq(shares, 1, "unexpected tiny-deposit shares");
        assertEq(vault.totalAssets(), 1, "tiny deposit should remain idle");

        vm.prank(alice);
        uint256 redeemed = vault.redeem(shares, alice, alice);

        assertEq(redeemed, 1, "tiny deposit not redeemable");
    }

    function test_multipleDepositCyclesAndFinalRedeem() public {
        if (!forkConfigured) return;

        uint256 firstShares = _depositUSDC(alice, 700e6);
        uint256 secondShares = _depositUSDC(alice, 300e6);

        assertGt(secondShares, 0, "second deposit minted no shares");

        uint256 balanceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        vault.redeem(firstShares + secondShares, alice, alice);
        uint256 received = IERC20(USDC).balanceOf(alice) - balanceBefore;

        assertGt(received, 975e6, "multi-cycle redeem lost too much");
        assertEq(vault.getDepositedBins().length, 0, "bins should be cleared after full redeem");
    }

    function _depositUSDC(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        IERC20(USDC).approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }
}
