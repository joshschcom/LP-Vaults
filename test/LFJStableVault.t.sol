// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20}         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {LFJStableVault} from "../contracts/LFJStableVault.sol";
import {ILBRouter}      from "../contracts/interfaces/ILBRouter.sol";
import {ILBPair}        from "../contracts/interfaces/ILBPair.sol";

/// @dev Minimal factory interface — only what the test needs
interface ILBFactory {
    struct LBPairInformation {
        uint16   binStep;
        ILBPair  LBPair;
        bool     createdByOwner;
        bool     ignoredForRouting;
    }
    function createLBPair(
        IERC20 tokenX,
        IERC20 tokenY,
        uint24 activeId,
        uint16 binStep
    ) external returns (ILBPair pair);

    function getLBPairInformation(
        IERC20 tokenX,
        IERC20 tokenY,
        uint256 binStep
    ) external view returns (LBPairInformation memory info);
}

/// @notice Fork test against Fuji testnet using a freshly created V2.2 pair.
///
///  Why a fresh pair?
///  ─────────────────
///  The only stable pair available on Fuji is a V2.1 USDC/USDT pair.
///  The V2.2 router's addLiquidity returns liquidityMinted in V2.2 units
///  (price-weighted) while V2.1's totalSupply(id) is in V2.1 units — the
///  two are incompatible, causing totalAssets() to return ~0.
///  Creating a fresh V2.2 pair avoids the mismatch entirely.
///
///  Run:
///    forge test --fork-url fuji --match-contract LFJStableVaultTest -vvv
contract LFJStableVaultTest is Test {

    // ── Fuji V2.2 addresses ──────────────────────────────────────────────────
    address constant LB_ROUTER  = 0x18556DA13313f3532c54711497A8FedAC273220E;
    address constant LB_FACTORY = 0xb43120c4745967fa9b93E79C149E66B0f2D6Fe0c;

    // ── Fuji test tokens (LFJ's own — NOT the Avalanche Foundation USDC) ────
    address constant USDC_FUJI = 0xB6076C93701D6a07266c31066B298AeC6dd65c2d; // 6 dec
    address constant USDT_FUJI = 0xAb231A5744C8E6c45481754928cCfFFFD4aa0732; // 6 dec

    // USDT (0xAb...) < USDC (0xB6...) so USDT = tokenX, USDC = tokenY

    // Active ID 8388608 represents a 1:1 price in LFJ V2.2 (2^23 = price anchor)
    uint24 constant ACTIVE_ID_PEG = 8388608;
    uint16 constant BIN_STEP_1BPS = 1;
    bytes32 constant ERC1967_ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // ─────────────────────────────────────────────────────────────────────────

    LFJStableVault vault;
    ILBPair        testPair;
    address        alice  = makeAddr("alice");
    address        keeper = makeAddr("keeper");

    function setUp() public {
        // ── 1. Create fresh V2.2 USDT/USDC pair ─────────────────────────────
        ILBFactory factory = ILBFactory(LB_FACTORY);

        // Check if a V2.2 pair already exists — reuse it if so
        ILBFactory.LBPairInformation memory info = factory.getLBPairInformation(
            IERC20(USDT_FUJI),
            IERC20(USDC_FUJI),
            BIN_STEP_1BPS
        );

        if (address(info.LBPair) == address(0)) {
            testPair = factory.createLBPair(
                IERC20(USDT_FUJI),
                IERC20(USDC_FUJI),
                ACTIVE_ID_PEG,
                BIN_STEP_1BPS
            );
        } else {
            testPair = info.LBPair;
        }

        // ── 2. Seed the pair with initial liquidity ──────────────────────────
        // Without seed liquidity, getSwapOut returns 0 → swap produces 0 tokens.
        // We seed 20,000 USDT + 20,000 USDC split across ±2 bins so the vault
        // can quote and execute swaps from the very first deposit.
        uint256 seedAmount = 20_000e6;
        deal(USDT_FUJI, address(this), seedAmount);
        deal(USDC_FUJI, address(this), seedAmount);

        IERC20(USDT_FUJI).approve(LB_ROUTER, seedAmount);
        IERC20(USDC_FUJI).approve(LB_ROUTER, seedAmount);

        int256[]  memory deltaIds = new int256[](5);
        uint256[] memory distX    = new uint256[](5);
        uint256[] memory distY    = new uint256[](5);

        // Simple even distribution: each bin gets 1/3 of X or 1/3 of Y
        // Below active: Y-only; active: split; above: X-only
        uint256 perBin = uint256(1e18) / 3;
        uint256 rem    = uint256(1e18) - perBin * 3;

        deltaIds[0] = -2; distY[0] = perBin;
        deltaIds[1] = -1; distY[1] = perBin;
        deltaIds[2] =  0; distX[2] = perBin;         distY[2] = perBin + rem;
        deltaIds[3] =  1; distX[3] = perBin;
        deltaIds[4] =  2; distX[4] = perBin + rem;

        ILBRouter.LiquidityParameters memory seedParams = ILBRouter.LiquidityParameters({
            tokenX:          IERC20(USDT_FUJI),
            tokenY:          IERC20(USDC_FUJI),
            binStep:         BIN_STEP_1BPS,
            amountX:         seedAmount,
            amountY:         seedAmount,
            amountXMin:      0,
            amountYMin:      0,
            activeIdDesired: ACTIVE_ID_PEG,
            idSlippage:      3,
            deltaIds:        deltaIds,
            distributionX:   distX,
            distributionY:   distY,
            to:              address(this),
            refundTo:        address(this),
            deadline:        block.timestamp
        });

        ILBRouter(LB_ROUTER).addLiquidity(seedParams);

        // ── 3. Deploy vault proxy against the fresh V2.2 pair ────────────────
        LFJStableVault implementation = new LFJStableVault();
        bytes memory initData = abi.encodeCall(
            LFJStableVault.initialize,
            (
                IERC20(USDT_FUJI), // ERC-4626 asset
                IERC20(USDT_FUJI),
                IERC20(USDC_FUJI),
                ILBRouter(LB_ROUTER),
                testPair,
                ILBRouter.Version.V2_2, // fresh pair is V2.2
                keeper,
                address(this),
                10_000e6,
                2,
                30
            )
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(implementation), address(this), initData);
        vault = LFJStableVault(address(proxy));

        // ── 4. Fund alice ─────────────────────────────────────────────────────
        _mintTestToken(USDT_FUJI, alice, 5_000e6);
        _mintTestToken(USDC_FUJI, alice, 5_000e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tests
    // ─────────────────────────────────────────────────────────────────────────

    function test_depositAndTotalAssets() public {
        uint256 depositAmount = 1_000e6; // 1000 USDT (vault asset)

        vm.startPrank(alice);
        IERC20(USDT_FUJI).approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);
        vm.stopPrank();

        console2.log("Shares minted:   ", shares);
        console2.log("Total assets:    ", vault.totalAssets());
        console2.log("Deposited bins:  ", vault.getDepositedBins().length);

        assertGt(shares, 0, "no shares minted");
        assertApproxEqRel(vault.totalAssets(), depositAmount, 0.01e18, "totalAssets off by >1%");
    }

    function test_depositAndWithdraw_roundTrip() public {
        uint256 depositAmount = 500e6;

        vm.startPrank(alice);
        IERC20(USDT_FUJI).approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, alice);

        uint256 usdtBefore = IERC20(USDT_FUJI).balanceOf(alice);
        vault.redeem(shares, alice, alice);
        uint256 usdtAfter = IERC20(USDT_FUJI).balanceOf(alice);
        vm.stopPrank();

        uint256 received = usdtAfter - usdtBefore;
        console2.log("Deposited: ", depositAmount);
        console2.log("Received:  ", received);

        // Should get back at least 98.5% (two swaps at 0.3% slippage + fees)
        assertGt(received, (depositAmount * 985) / 1000, "lost >1.5% on round trip");
    }

    function test_needsRebalance_returnsFalse_onFreshDeposit() public {
        vm.startPrank(alice);
        IERC20(USDT_FUJI).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        assertFalse(vault.needsRebalance(), "should not need rebalance");
    }

    function test_rebalance_byKeeper() public {
        vm.startPrank(alice);
        IERC20(USDT_FUJI).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        uint256 assetsBefore = vault.totalAssets();

        vm.prank(keeper);
        vault.rebalance();

        uint256 assetsAfter = vault.totalAssets();
        console2.log("Before rebalance:", assetsBefore);
        console2.log("After rebalance: ", assetsAfter);

        assertApproxEqRel(assetsAfter, assetsBefore, 0.01e18, "rebalance lost >1%");
    }

    function test_depositCap_revert() public {
        vault.setDepositCap(100e6);

        vm.startPrank(alice);
        IERC20(USDT_FUJI).approve(address(vault), 200e6);
        vm.expectRevert();
        vault.deposit(200e6, alice);
        vm.stopPrank();
    }

    function test_pause_blocksDeposit() public {
        vault.pause();

        vm.startPrank(alice);
        IERC20(USDT_FUJI).approve(address(vault), 500e6);
        vm.expectRevert();
        vault.deposit(500e6, alice);
        vm.stopPrank();
    }

    function test_emergencyWithdrawLP() public {
        vm.startPrank(alice);
        IERC20(USDT_FUJI).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        assertGt(vault.getDepositedBins().length, 0, "no bins to emergency withdraw");

        vault.emergencyWithdrawLP();

        assertEq(vault.getDepositedBins().length, 0, "bins not cleared");
        assertGt(IERC20(USDT_FUJI).balanceOf(address(vault)), 0, "no USDT returned");
    }

    function test_onlyOwnerCanSetParams() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setSlippage(50);

        vm.prank(alice);
        vm.expectRevert();
        vault.setDepositCap(1e18);
    }

    function test_slippageCap() public {
        vm.expectRevert();
        vault.setSlippage(201);
    }

    function test_proxyAdminIsCreatedForOwner() public {
        address proxyAdmin = address(uint160(uint256(vm.load(address(vault), ERC1967_ADMIN_SLOT))));
        assertGt(proxyAdmin.code.length, 0, "proxy admin not deployed");
    }

    function test_initializeCannotRunTwice() public {
        vm.expectRevert();
        vault.initialize(
            IERC20(USDT_FUJI),
            IERC20(USDT_FUJI),
            IERC20(USDC_FUJI),
            ILBRouter(LB_ROUTER),
            testPair,
            ILBRouter.Version.V2_2,
            keeper,
            address(this),
            10_000e6,
            2,
            30
        );
    }

    function test_implementationCannotBeInitializedDirectly() public {
        LFJStableVault implementation = new LFJStableVault();

        vm.expectRevert();
        implementation.initialize(
            IERC20(USDT_FUJI),
            IERC20(USDT_FUJI),
            IERC20(USDC_FUJI),
            ILBRouter(LB_ROUTER),
            testPair,
            ILBRouter.Version.V2_2,
            keeper,
            address(this),
            10_000e6,
            2,
            30
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _mintTestToken(address token, address to, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
        if (!ok) {
            deal(token, to, amount);
        }
    }
}
