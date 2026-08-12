// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {PharaohLiquidityVault} from "../contracts/PharaohLiquidityVault.sol";
import {IPharaohFactory} from "../contracts/interfaces/pharaoh/IPharaohFactory.sol";
import {IPharaohPool} from "../contracts/interfaces/pharaoh/IPharaohPool.sol";
import {IPharaohPositionManager} from "../contracts/interfaces/pharaoh/IPharaohPositionManager.sol";
import {IPharaohSwapRouter} from "../contracts/interfaces/pharaoh/IPharaohSwapRouter.sol";
import {IPharaohVaultOracle} from "../contracts/interfaces/pharaoh/IPharaohVaultOracle.sol";
import {PharaohLiquidityAmounts} from "../contracts/libraries/PharaohLiquidityAmounts.sol";
import {PharaohTickMath} from "../contracts/libraries/PharaohTickMath.sol";

contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

contract MockPharaohFactory is IPharaohFactory {
    address public immutable override ramsesV3PoolDeployer;
    address public pool;

    constructor(address deployer_) {
        ramsesV3PoolDeployer = deployer_;
    }

    function setPool(address pool_) external {
        pool = pool_;
    }

    function getPool(address, address, int24) external view override returns (address) {
        return pool;
    }
}

    contract MockPharaohPool is IPharaohPool {
        address public immutable override factory;
        address public immutable override token0;
        address public immutable override token1;
        uint24 public constant override fee = 40;
        int24 public constant override tickSpacing = 1;
        uint128 public constant override liquidity = 1;

        int24 public spotTick;
        int24 public meanTick;

        constructor(address factory_, address token0_, address token1_) {
            factory = factory_;
            token0 = token0_;
            token1 = token1_;
        }

        function setTicks(int24 spotTick_, int24 meanTick_) external {
            spotTick = spotTick_;
            meanTick = meanTick_;
        }

        function slot0() external view override returns (uint160, int24, uint16, uint16, uint16, uint24, bool) {
            return (PharaohTickMath.getSqrtRatioAtTick(spotTick), spotTick, 0, 2, 2, 0, true);
        }

        function observe(uint32[] calldata secondsAgos)
            external
            view
            override
            returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
        {
            tickCumulatives = new int56[](secondsAgos.length);
            secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
            for (uint256 i; i < secondsAgos.length; ++i) {
                tickCumulatives[i] = -int56(meanTick) * int56(uint56(secondsAgos[i]));
            }
        }

        function increaseObservationCardinalityNext(uint16) external override {}
    }

        contract MockVaultOracle is IPharaohVaultOracle {
            address public immutable override asset;
            address public immutable override pairedToken;
            uint256 public rate = 1 ether;

            constructor(address asset_, address pairedToken_) {
                asset = asset_;
                pairedToken = pairedToken_;
            }

            function setRate(uint256 newRate) external {
                rate = newRate;
            }

            function quotePairToAsset(uint256 amount) external view override returns (uint256) {
                return (amount * rate) / 1 ether;
            }

            function quoteAssetToPair(uint256 amount) external view override returns (uint256) {
                return (amount * 1 ether) / rate;
            }
        }

            contract MockPharaohRouter is IPharaohSwapRouter {
                using SafeERC20 for IERC20;

                address public immutable override deployer;
                bool public swapsDisabled;
                uint16 public outputBps = 10_000;

                constructor(address deployer_) {
                    deployer = deployer_;
                }

                function setSwapsDisabled(bool disabled) external {
                    swapsDisabled = disabled;
                }

                function setOutputBps(uint16 newOutputBps) external {
                    require(newOutputBps <= 10_000, "invalid output bps");
                    outputBps = newOutputBps;
                }

                function exactInputSingle(ExactInputSingleParams calldata params)
                    external
                    payable
                    override
                    returns (uint256 amountOut)
                {
                    require(!swapsDisabled, "swaps disabled");
                    IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
                    amountOut = (params.amountIn * outputBps) / 10_000;
                    require(amountOut >= params.amountOutMinimum, "minimum output");
                    MockToken(params.tokenOut).mint(params.recipient, amountOut);
                }
            }

                contract MockPharaohPositionManager is IPharaohPositionManager {
                    using SafeERC20 for IERC20;

                    struct PositionData {
                        address owner;
                        address token0;
                        address token1;
                        int24 spacing;
                        int24 lower;
                        int24 upper;
                        uint128 liquidity;
                        uint128 owed0;
                        uint128 owed1;
                    }

                    address public immutable override deployer;
                    uint256 public nextTokenId = 1;
                    mapping(uint256 => PositionData) private _positions;

                    constructor(address deployer_) {
                        deployer = deployer_;
                    }

                    function ownerOf(uint256 positionId) external view override returns (address) {
                        return _positions[positionId].owner;
                    }

                    function positions(uint256 positionId)
                        external
                        view
                        override
                        returns (address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128)
                    {
                        PositionData memory p = _positions[positionId];
                        return (p.token0, p.token1, p.spacing, p.lower, p.upper, p.liquidity, 0, 0, p.owed0, p.owed1);
                    }

                    function mint(MintParams calldata params)
                        external
                        payable
                        override
                        returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1)
                    {
                        (liquidity, amount0, amount1) = _liquidityAndAmounts(
                            params.tickLower, params.tickUpper, params.amount0Desired, params.amount1Desired
                        );
                        IERC20(params.token0).safeTransferFrom(msg.sender, address(this), amount0);
                        IERC20(params.token1).safeTransferFrom(msg.sender, address(this), amount1);

                        positionId = nextTokenId++;
                        _positions[positionId] = PositionData({
                            owner: params.recipient,
                            token0: params.token0,
                            token1: params.token1,
                            spacing: params.tickSpacing,
                            lower: params.tickLower,
                            upper: params.tickUpper,
                            liquidity: liquidity,
                            owed0: 0,
                            owed1: 0
                        });
                    }

                    function increaseLiquidity(IncreaseLiquidityParams calldata params)
                        external
                        payable
                        override
                        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
                    {
                        PositionData storage p = _positions[params.tokenId];
                        (liquidity, amount0, amount1) =
                            _liquidityAndAmounts(p.lower, p.upper, params.amount0Desired, params.amount1Desired);
                        IERC20(p.token0).safeTransferFrom(msg.sender, address(this), amount0);
                        IERC20(p.token1).safeTransferFrom(msg.sender, address(this), amount1);
                        p.liquidity += liquidity;
                    }

                    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
                        external
                        payable
                        override
                        returns (uint256 amount0, uint256 amount1)
                    {
                        PositionData storage p = _positions[params.tokenId];
                        require(msg.sender == p.owner, "not owner");
                        require(params.liquidity <= p.liquidity, "liquidity");
                        (amount0, amount1) = PharaohLiquidityAmounts.getAmountsForLiquidity(
                            uint160(1 << 96),
                            PharaohTickMath.getSqrtRatioAtTick(p.lower),
                            PharaohTickMath.getSqrtRatioAtTick(p.upper),
                            params.liquidity
                        );
                        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "minimum amounts");
                        p.liquidity -= params.liquidity;
                        p.owed0 += uint128(amount0);
                        p.owed1 += uint128(amount1);
                    }

                    function collect(CollectParams calldata params)
                        external
                        payable
                        override
                        returns (uint256 amount0, uint256 amount1)
                    {
                        PositionData storage p = _positions[params.tokenId];
                        require(msg.sender == p.owner, "not owner");
                        amount0 = p.owed0 > params.amount0Max ? params.amount0Max : p.owed0;
                        amount1 = p.owed1 > params.amount1Max ? params.amount1Max : p.owed1;
                        p.owed0 -= uint128(amount0);
                        p.owed1 -= uint128(amount1);
                        IERC20(p.token0).safeTransfer(params.recipient, amount0);
                        IERC20(p.token1).safeTransfer(params.recipient, amount1);
                    }

                    function burn(uint256 positionId) external payable override {
                        PositionData storage p = _positions[positionId];
                        require(msg.sender == p.owner, "not owner");
                        require(p.liquidity == 0 && p.owed0 == 0 && p.owed1 == 0, "not empty");
                        delete _positions[positionId];
                    }

                    function getReward(uint256, address[] calldata) external payable override {}

                    function _liquidityAndAmounts(int24 lower, int24 upper, uint256 desired0, uint256 desired1)
                        private
                        pure
                        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
                    {
                        uint160 sqrtLower = PharaohTickMath.getSqrtRatioAtTick(lower);
                        uint160 sqrtUpper = PharaohTickMath.getSqrtRatioAtTick(upper);
                        liquidity =
                            PharaohLiquidityAmounts.getLiquidityForAmounts(
                            uint160(1 << 96), sqrtLower, sqrtUpper, desired0, desired1
                        );
                        (amount0, amount1) =
                            PharaohLiquidityAmounts.getAmountsForLiquidity(
                            uint160(1 << 96), sqrtLower, sqrtUpper, liquidity
                        );
                    }
                }

                    contract PharaohLiquidityVaultTest is Test {
                        bytes32 private constant ERC1967_ADMIN_SLOT =
                            0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

                        MockToken private pairToken;
                        MockToken private assetToken;
                        MockPharaohFactory private factory;
                        MockPharaohPool private pool;
                        MockPharaohPositionManager private positionManager;
                        MockPharaohRouter private router;
                        MockVaultOracle private oracle;
                        PharaohLiquidityVault private vault;
                        ProxyAdmin private proxyAdmin;

                        address private alice = makeAddr("alice");
                        address private bob = makeAddr("bob");
                        address private keeper = makeAddr("keeper");

                        function setUp() public {
                            pairToken = new MockToken("Pair", "PAIR");
                            assetToken = new MockToken("Asset", "ASSET");

                            address poolDeployer = makeAddr("poolDeployer");
                            factory = new MockPharaohFactory(poolDeployer);
                            pool = new MockPharaohPool(address(factory), address(pairToken), address(assetToken));
                            factory.setPool(address(pool));
                            positionManager = new MockPharaohPositionManager(poolDeployer);
                            router = new MockPharaohRouter(poolDeployer);
                            oracle = new MockVaultOracle(address(assetToken), address(pairToken));

                            PharaohLiquidityVault implementation = new PharaohLiquidityVault();
                            bytes memory initData = abi.encodeCall(
                                PharaohLiquidityVault.initialize,
                                (PharaohLiquidityVault.InitParams({
                                        name: "Peridot Pharaoh Test Vault",
                                        symbol: "pPHAR-TEST",
                                        asset: IERC20(address(assetToken)),
                                        factory: factory,
                                        pool: pool,
                                        positionManager: positionManager,
                                        swapRouter: router,
                                        priceOracle: oracle,
                                        owner: address(this),
                                        rebalancer: keeper,
                                        depositCap: 10_000 ether,
                                        tickRange: 100,
                                        twapPeriod: 30 minutes,
                                        maxTwapDeviationTicks: 30,
                                        maxOracleDeviationBps: 30,
                                        slippageBps: 100,
                                        valuationHaircutBps: 100
                                    }))
                            );
                            TransparentUpgradeableProxy proxy =
                                new TransparentUpgradeableProxy(address(implementation), address(this), initData);
                            vault = PharaohLiquidityVault(address(proxy));
                            proxyAdmin = ProxyAdmin(
                                address(uint160(uint256(vm.load(address(proxy), ERC1967_ADMIN_SLOT))))
                            );
                            assertTrue(vault.paused());
                            vault.unpause();

                            assetToken.mint(alice, 10_000 ether);
                            assetToken.mint(bob, 10_000 ether);
                            vm.prank(alice);
                            assetToken.approve(address(vault), type(uint256).max);
                            vm.prank(bob);
                            assetToken.approve(address(vault), type(uint256).max);
                        }

                        function test_depositCreatesPositionAndRedeemRealizesAllAssets() public {
                            vm.prank(alice);
                            uint256 shares = vault.deposit(1_000 ether, alice);

                            assertGt(shares, vault.previewDeposit(1_000 ether));
                            assertGt(vault.tokenId(), 0);
                            assertEq(positionManager.ownerOf(vault.tokenId()), address(vault));
                            assertApproxEqRel(vault.totalAssets(), 995 ether, 0.001e18);

                            uint256 balanceBefore = assetToken.balanceOf(alice);
                            vm.prank(alice);
                            uint256 assets = vault.redeem(shares, alice, alice);

                            assertApproxEqAbs(assets, 1_000 ether, 10);
                            assertEq(assetToken.balanceOf(alice) - balanceBefore, assets);
                            assertEq(vault.tokenId(), 0);
                            assertEq(vault.totalSupply(), 0);
                        }

                        function test_exactShareMintingIsDisabled() public {
                            assertEq(vault.maxMint(alice), 0);
                            vm.prank(alice);
                            vm.expectRevert();
                            vault.mint(1 ether, alice);
                        }

                        function testFuzz_fullRedeemRealizesDeposit(uint96 rawAmount) public {
                            uint256 amount = bound(uint256(rawAmount), 1e12, 5_000 ether);
                            vm.prank(alice);
                            uint256 shares = vault.deposit(amount, alice);

                            uint256 balanceBefore = assetToken.balanceOf(alice);
                            vm.prank(alice);
                            uint256 assets = vault.redeem(shares, alice, alice);

                            assertApproxEqAbs(assets, amount, 10);
                            assertEq(assetToken.balanceOf(alice) - balanceBefore, assets);
                            assertEq(vault.totalSupply(), 0);
                            assertEq(vault.tokenId(), 0);
                        }

                        function test_tickMathMatchesKnownTick256Value() public pure {
                            // Exercises the 0x100 multiplication branch in PharaohTickMath.
                            assertEq(
                                PharaohTickMath.getSqrtRatioAtTick(256), uint160(80_248_749_790_819_932_309_965_073_893)
                            );
                        }

                        function test_proxyUpgradePreservesPositionAndAccounting() public {
                            uint256 shares = _deposit(alice, 1_000 ether);
                            uint256 positionId = vault.tokenId();
                            uint256 valueBefore = vault.convertToAssets(shares);

                            PharaohLiquidityVault upgradedImplementation = new PharaohLiquidityVault();
                            proxyAdmin.upgradeAndCall(
                                ITransparentUpgradeableProxy(address(vault)), address(upgradedImplementation), bytes("")
                            );

                            assertEq(vault.tokenId(), positionId);
                            assertEq(vault.balanceOf(alice), shares);
                            assertEq(vault.owner(), address(this));
                            assertEq(vault.rebalancer(), keeper);
                            assertEq(vault.convertToAssets(shares), valueBefore);
                        }

                        function test_proxyUpgradeAtomicallyMigratesRiskParameters() public {
                            PharaohLiquidityVault upgradedImplementation = new PharaohLiquidityVault();
                            bytes memory migration =
                                abi.encodeCall(
                                PharaohLiquidityVault.initializeV2RiskParameters, (uint16(20), uint16(100), uint16(100))
                            );

                            proxyAdmin.upgradeAndCall(
                                ITransparentUpgradeableProxy(address(vault)), address(upgradedImplementation), migration
                            );

                            assertEq(vault.maxTwapDeviationTicks(), 30);
                            assertEq(vault.maxOracleDeviationBps(), 20);
                            assertEq(vault.slippageBps(), 100);
                            assertEq(vault.valuationHaircutBps(), 100);
                        }

                        function test_riskMigrationRejectsMismatchAndUnauthorizedCaller() public {
                            vm.prank(alice);
                            vm.expectRevert(
                                abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice)
                            );
                            vault.initializeV2RiskParameters(100, 30, 50);

                            vm.expectRevert(PharaohLiquidityVault.Vault__InvalidConfiguration.selector);
                            vault.initializeV2RiskParameters(100, 30, 50);

                            vault.initializeV2RiskParameters(20, 100, 100);
                            assertEq(vault.slippageBps(), 100);
                        }

                        function test_secondDepositDoesNotDiluteFirstDepositor() public {
                            uint256 aliceShares = _deposit(alice, 1_000 ether);
                            uint256 aliceValueBefore = vault.convertToAssets(aliceShares);

                            _deposit(bob, 1_000 ether);
                            uint256 aliceValueAfter = vault.convertToAssets(aliceShares);

                            assertApproxEqRel(aliceValueAfter, aliceValueBefore, 0.001e18);
                        }

                        function test_partialWithdrawReturnsExactAssets() public {
                            _deposit(alice, 1_000 ether);
                            uint256 balanceBefore = assetToken.balanceOf(alice);

                            vm.prank(alice);
                            uint256 sharesBurned = vault.withdraw(200 ether, alice, alice);

                            assertGt(sharesBurned, 0);
                            assertEq(assetToken.balanceOf(alice) - balanceBefore, 200 ether);
                            assertGt(vault.balanceOf(alice), 0);
                            assertGt(vault.tokenId(), 0);
                        }

                        function test_partialWithdrawUsesBoundedExactInputAtConfiguredSlippage() public {
                            _deposit(alice, 1_000 ether);
                            _deposit(bob, 1_000 ether);
                            uint256 managedBefore = vault.totalAssets();
                            uint256 balanceBefore = assetToken.balanceOf(alice);

                            // The USDC deployment's configured one-percent
                            // slippage budget must cover a one-percent route loss.
                            router.setOutputBps(9_900);
                            vm.prank(alice);
                            uint256 sharesBurned = vault.withdraw(200 ether, alice, alice);

                            assertGt(sharesBurned, 0);
                            assertEq(assetToken.balanceOf(alice) - balanceBefore, 200 ether);
                            assertApproxEqAbs(vault.totalAssets(), managedBefore - 200 ether, 0.01 ether);
                            assertGt(vault.balanceOf(alice), 0);
                            assertGt(vault.balanceOf(bob), 0);
                            assertGt(vault.tokenId(), 0);
                        }

                        function test_partialWithdrawRevertsAtomicallyBeyondConfiguredSlippage() public {
                            _deposit(alice, 1_000 ether);
                            _deposit(bob, 1_000 ether);
                            uint256 aliceSharesBefore = vault.balanceOf(alice);
                            uint256 supplyBefore = vault.totalSupply();
                            uint256 managedBefore = vault.totalAssets();
                            uint256 tokenIdBefore = vault.tokenId();
                            uint256 aliceAssetsBefore = assetToken.balanceOf(alice);

                            router.setOutputBps(9_899);
                            vm.prank(alice);
                            vm.expectRevert(bytes("minimum output"));
                            vault.withdraw(200 ether, alice, alice);

                            assertEq(vault.balanceOf(alice), aliceSharesBefore);
                            assertEq(vault.totalSupply(), supplyBefore);
                            assertEq(vault.totalAssets(), managedBefore);
                            assertEq(vault.tokenId(), tokenIdBefore);
                            assertEq(assetToken.balanceOf(alice), aliceAssetsBefore);
                        }

                        function test_rebalancePreservesValueAndRequiresKeeper() public {
                            _deposit(alice, 1_000 ether);
                            uint256 beforeValue = vault.totalAssets();
                            uint256 oldTokenId = vault.tokenId();

                            vm.prank(alice);
                            vm.expectRevert(PharaohLiquidityVault.Vault__NotRebalancer.selector);
                            vault.rebalance();

                            vm.prank(keeper);
                            vault.rebalance();

                            assertGt(vault.tokenId(), oldTokenId);
                            assertApproxEqRel(vault.totalAssets(), beforeValue, 0.001e18);
                        }

                        function test_priceDeviationBlocksDeposits() public {
                            pool.setTicks(31, 0);

                            vm.prank(alice);
                            vm.expectRevert(
                                abi.encodeWithSelector(
                                    PharaohLiquidityVault.Vault__PriceDeviation.selector, int24(31), int24(0)
                                )
                            );
                            vault.deposit(100 ether, alice);
                        }

                        function test_oracleDeviationBlocksDeposits() public {
                            oracle.setRate(0.95 ether);

                            vm.prank(alice);
                            vm.expectRevert(
                                abi.encodeWithSelector(
                                    PharaohLiquidityVault.Vault__OracleDeviation.selector,
                                    uint256(1 ether),
                                    uint256(0.95 ether)
                                )
                            );
                            vault.deposit(100 ether, alice);
                        }

                        function test_collateralValuationFailsClosedOnUnsafePrice() public {
                            uint256 shares = _deposit(alice, 1_000 ether);

                            pool.setTicks(31, 0);
                            vm.expectRevert(
                                abi.encodeWithSelector(
                                    PharaohLiquidityVault.Vault__PriceDeviation.selector, int24(31), int24(0)
                                )
                            );
                            vault.convertToAssets(shares);

                            pool.setTicks(0, 0);
                            oracle.setRate(0.95 ether);
                            vm.expectRevert(
                                abi.encodeWithSelector(
                                    PharaohLiquidityVault.Vault__OracleDeviation.selector,
                                    uint256(1 ether),
                                    uint256(0.95 ether)
                                )
                            );
                            vault.convertToAssets(shares);
                        }

                        function test_pauseBlocksDepositButAllowsRedeem() public {
                            uint256 shares = _deposit(alice, 1_000 ether);
                            vault.pause();
                            assertEq(vault.maxMint(alice), 0);

                            vm.prank(bob);
                            vm.expectRevert();
                            vault.deposit(100 ether, bob);

                            vm.prank(alice);
                            uint256 assets = vault.redeem(shares, alice, alice);
                            assertGt(assets, 990 ether);
                        }

                        function test_emergencyExitWorksWhenAlreadyPaused() public {
                            _deposit(alice, 1_000 ether);
                            vault.pause();
                            vault.emergencyExit();

                            assertTrue(vault.paused());
                            assertEq(vault.tokenId(), 0);
                            assertGt(
                                assetToken.balanceOf(address(vault)) + pairToken.balanceOf(address(vault)), 990 ether
                            );
                        }

                        function test_depositCapUsesManagedValue() public {
                            vault.setDepositCap(1_050 ether);
                            _deposit(alice, 1_000 ether);

                            vm.prank(bob);
                            vm.expectRevert(
                                abi.encodeWithSelector(
                                    PharaohLiquidityVault.Vault__DepositCapExceeded.selector,
                                    uint256(1_050 ether),
                                    uint256(1_095 ether)
                                )
                            );
                            vault.deposit(100 ether, bob);
                        }

                        function test_canaryStaysActiveWhileFurtherDepositsAreClosed() public {
                            _deposit(alice, 10 ether);
                            vault.setDepositCap(1);

                            assertFalse(vault.paused());
                            assertEq(vault.maxDeposit(bob), 0);

                            vm.prank(bob);
                            vm.expectRevert(
                                abi.encodeWithSelector(
                                    PharaohLiquidityVault.Vault__DepositCapExceeded.selector,
                                    uint256(1),
                                    uint256(10.95 ether)
                                )
                            );
                            vault.deposit(1 ether, bob);

                            vm.prank(keeper);
                            vault.rebalance();
                            assertGt(vault.tokenId(), 0);
                        }

                        function test_directPairedTokenDonationRemainsRedeemable() public {
                            uint256 shares = _deposit(alice, 1_000 ether);
                            pairToken.mint(address(vault), 100 ether);

                            uint256 balanceBefore = assetToken.balanceOf(alice);
                            vm.prank(alice);
                            uint256 assets = vault.redeem(shares, alice, alice);

                            assertApproxEqAbs(assets, 1_100 ether, 10);
                            assertEq(assetToken.balanceOf(alice) - balanceBefore, assets);
                            assertEq(pairToken.balanceOf(address(vault)), 0);
                        }

                        function test_emergencyExitPairedBalanceRemainsRedeemable() public {
                            uint256 shares = _deposit(alice, 1_000 ether);
                            vault.emergencyExit();
                            assertTrue(vault.paused());
                            assertEq(vault.tokenId(), 0);

                            uint256 balanceBefore = assetToken.balanceOf(alice);
                            vm.prank(alice);
                            uint256 assets = vault.redeem(shares, alice, alice);

                            assertApproxEqAbs(assets, 1_000 ether, 10);
                            assertEq(assetToken.balanceOf(alice) - balanceBefore, assets);
                            assertEq(pairToken.balanceOf(address(vault)), 0);
                        }

                        function test_inKindRedeemWorksWithoutPoolSwapsOrSafePrices() public {
                            uint256 shares = _deposit(alice, 1_000 ether);
                            router.setSwapsDisabled(true);
                            pool.setTicks(0, 31);
                            oracle.setRate(0.95 ether);

                            vm.prank(alice);
                            vm.expectRevert();
                            vault.redeem(shares, alice, alice);
                            assertEq(vault.balanceOf(alice), shares, "failed asset-only exit burned shares");

                            uint256 assetBefore = assetToken.balanceOf(alice);
                            uint256 pairBefore = pairToken.balanceOf(alice);
                            vm.prank(alice);
                            (uint256 assets, uint256 pairedAssets) = vault.redeemInKind(shares, alice, alice);

                            assertGt(assets, 0);
                            assertGt(pairedAssets, 0);
                            assertEq(assetToken.balanceOf(alice) - assetBefore, assets);
                            assertEq(pairToken.balanceOf(alice) - pairBefore, pairedAssets);
                            assertEq(vault.totalSupply(), 0);
                            assertEq(vault.tokenId(), 0);
                        }

                        function _deposit(address user, uint256 assets) private returns (uint256 shares) {
                            vm.prank(user);
                            shares = vault.deposit(assets, user);
                        }
                    }
