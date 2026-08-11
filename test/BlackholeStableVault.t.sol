// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BlackholeStableVault} from "../contracts/BlackholeStableVault.sol";
import {IBlackholePair} from "../contracts/interfaces/IBlackholePair.sol";
import {IBlackholeRouter} from "../contracts/interfaces/IBlackholeRouter.sol";
import {IStableVaultOracle} from "../contracts/interfaces/IStableVaultOracle.sol";

contract BlackholeMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BlackholeMockPair is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable firstToken;
    IERC20 public immutable secondToken;
    address public router;

    constructor(IERC20 token0_, IERC20 token1_) ERC20("Mock Blackhole LP", "mBH-LP") {
        firstToken = token0_;
        secondToken = token1_;
    }

    function setRouter(address router_) external {
        require(router == address(0), "router already set");
        router = router_;
    }

    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 timestamp) {
        return (firstToken.balanceOf(address(this)), secondToken.balanceOf(address(this)), block.timestamp);
    }

    function stable() external pure returns (bool) {
        return true;
    }

    function token0() external view returns (address) {
        return address(firstToken);
    }

    function token1() external view returns (address) {
        return address(secondToken);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        require(msg.sender == router, "only router");
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }

    function sendToken(IERC20 token, address to, uint256 amount) external {
        require(msg.sender == router, "only router");
        token.safeTransfer(to, amount);
    }
}

contract BlackholeMockOracle is IStableVaultOracle {
    address public immutable override asset;
    address public immutable override pairedToken;

    constructor(address asset_, address pairedToken_) {
        asset = asset_;
        pairedToken = pairedToken_;
    }

    function quotePairToAsset(uint256 pairAmount) external pure returns (uint256 assetAmount) {
        return pairAmount;
    }

    function quoteAssetToPair(uint256 assetAmount) external pure returns (uint256 pairAmount) {
        return assetAmount;
    }
}

contract BlackholeMockRouter is IBlackholeRouter {
    using SafeERC20 for IERC20;

    BlackholeMockPair public immutable mockPair;
    uint256 public feeBps;

    constructor(BlackholeMockPair pair_, uint256 feeBps_) {
        mockPair = pair_;
        feeBps = feeBps_;
    }

    function setFeeBps(uint256 feeBps_) external {
        require(feeBps_ <= 10_000, "invalid fee");
        feeBps = feeBps_;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        route[] calldata routes,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(routes.length == 1 && routes[0].pair == address(mockPair), "bad route");
        IERC20 tokenIn = IERC20(routes[0].from);
        IERC20 tokenOut = IERC20(routes[0].to);
        (uint256 amountOut,) = getAmountOut(amountIn, address(tokenIn), address(tokenOut), true);
        require(amountOut >= amountOutMin, "insufficient output");

        tokenIn.safeTransferFrom(msg.sender, address(mockPair), amountIn);
        mockPair.sendToken(tokenOut, to, amountOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(amountADesired >= amountAMin && amountBDesired >= amountBMin, "liquidity slippage");
        IERC20(tokenA).safeTransferFrom(msg.sender, address(mockPair), amountADesired);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(mockPair), amountBDesired);
        liquidity = amountADesired + amountBDesired;
        mockPair.mint(to, liquidity);
        return (amountADesired, amountBDesired, liquidity);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256
    ) external returns (uint256 amountA, uint256 amountB) {
        uint256 supply = mockPair.totalSupply();
        amountA = (IERC20(tokenA).balanceOf(address(mockPair)) * liquidity) / supply;
        amountB = (IERC20(tokenB).balanceOf(address(mockPair)) * liquidity) / supply;
        require(amountA >= amountAMin && amountB >= amountBMin, "remove slippage");

        mockPair.burnFrom(msg.sender, liquidity);
        mockPair.sendToken(IERC20(tokenA), to, amountA);
        mockPair.sendToken(IERC20(tokenB), to, amountB);
    }

    function getAmountOut(uint256 amountIn, address tokenIn, address tokenOut, bool)
        public
        view
        returns (uint256 amountOut, bool isStable)
    {
        bool validPair =
            (tokenIn == address(mockPair.firstToken()) && tokenOut == address(mockPair.secondToken()))
                || (tokenIn == address(mockPair.secondToken()) && tokenOut == address(mockPair.firstToken()));
        require(validPair, "bad pair");
        return ((amountIn * (10_000 - feeBps)) / 10_000, true);
    }
}

contract BlackholeStableVaultTest is Test {
    BlackholeMockToken private usdc;
    BlackholeMockToken private eurc;
    BlackholeMockPair private pair;
    BlackholeMockRouter private router;
    BlackholeMockOracle private oracle;
    BlackholeStableVault private vault;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        usdc = new BlackholeMockToken("USD Coin", "USDC");
        eurc = new BlackholeMockToken("Euro Coin", "EURC");
        pair = new BlackholeMockPair(usdc, eurc);
        router = new BlackholeMockRouter(pair, 100); // deterministic 1% swap cost
        pair.setRouter(address(router));
        oracle = new BlackholeMockOracle(address(usdc), address(eurc));

        // Keep the vault a small share of the mock pool, matching the intended
        // capped deployment and making LP minting proportional in this harness.
        usdc.mint(address(pair), 1_000_000e6);
        eurc.mint(address(pair), 1_000_000e6);
        pair.mint(address(this), 2_000_000e6);

        vault = new BlackholeStableVault(usdc, eurc, router, IBlackholePair(address(pair)), oracle);
        vault.setDepositCap(1_000_000e6);

        usdc.mint(alice, 10_000e6);
        eurc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
        eurc.mint(bob, 10_000e6);
    }

    function test_depositEURCIntoEmptyVaultMintsShares() public {
        vm.startPrank(alice);
        eurc.approve(address(vault), 100e6);
        uint256 shares = vault.depositEURC(100e6, alice);
        vm.stopPrank();

        assertEq(shares, 99e6);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_secondEURCDepositorIsNotDilutedByOwnAssets() public {
        _depositUSDC(alice, 100e6);

        vm.startPrank(bob);
        eurc.approve(address(vault), 100e6);
        uint256 shares = vault.depositEURC(100e6, bob);
        vm.stopPrank();

        assertGt(shares, 90e6, "EURC depositor was materially under-minted");
    }

    function test_depositEURCCapCountsRealizedAssetsOnce() public {
        vault.setDepositCap(150e6);
        _depositUSDC(alice, 100e6);

        vm.startPrank(bob);
        eurc.approve(address(vault), 40e6);
        uint256 shares = vault.depositEURC(40e6, bob);
        vm.stopPrank();

        assertGt(shares, 0);
        assertLe(vault.totalAssets(), 150e6);
    }

    function test_fullRedemptionSettlesAfterSwapCosts() public {
        uint256 shares = _depositUSDC(alice, 1_000e6);
        uint256 preview = vault.previewRedeem(shares);
        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 redeemed = vault.redeem(shares, alice, alice);

        assertEq(usdc.balanceOf(alice) - balanceBefore, redeemed);
        assertGt(redeemed, preview, "final holder did not receive execution surplus");
        assertGt(redeemed, 970e6);
        assertEq(vault.totalSupply(), 0);
        assertEq(pair.balanceOf(address(vault)), 0);
        assertEq(eurc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_exactWithdrawKeepsExecutionSurplusBackedByShares() public {
        uint256 initialShares = _depositUSDC(alice, 1_000e6);
        uint256 assets = vault.maxWithdraw(alice);
        assertEq(vault.previewWithdraw(assets), initialShares, "test must exercise final-share quote");

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 burnedShares = vault.withdraw(assets, alice, alice);

        assertEq(usdc.balanceOf(alice) - balanceBefore, assets, "withdraw must remain exact");
        assertLt(burnedShares, initialShares, "execution surplus was left without shares");
        assertGt(vault.totalSupply(), 0, "surplus has no remaining claimant");
        assertEq(pair.balanceOf(address(vault)), 0, "full liquidation left LP");
        assertEq(eurc.balanceOf(address(vault)), 0, "full liquidation left EURC");

        uint256 remainingShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(remainingShares, alice, alice);

        assertEq(vault.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_routerQuoteCannotManipulateTotalAssets() public {
        _depositUSDC(alice, 1_000e6);
        uint256 assetsBefore = vault.totalAssets();

        router.setFeeBps(500);

        assertEq(vault.totalAssets(), assetsBefore, "router quote changed share accounting");
    }

    function test_adverseRouterQuoteBlocksDeposit() public {
        router.setFeeBps(500);

        vm.startPrank(alice);
        usdc.approve(address(vault), 100e6);
        vm.expectPartialRevert(BlackholeStableVault.Vault__UnsafeSwapQuote.selector);
        vault.deposit(100e6, alice);
        vm.stopPrank();

        assertEq(vault.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_zeroShareUSDCDepositRevertsBeforeTakingAssets() public {
        vault.setDepositCap(0);
        eurc.mint(address(vault), 1_000_000_000e6);

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1);
        vm.expectRevert(BlackholeStableVault.Vault__ZeroShares.selector);
        vault.deposit(1, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), balanceBefore);
    }

    function test_sweepRejectsBackingLPToken() public {
        _depositUSDC(alice, 100e6);
        uint256 lpBefore = pair.balanceOf(address(vault));

        vm.expectRevert(bytes("cannot sweep vault tokens"));
        vault.sweep(IERC20(address(pair)), address(this), lpBefore);

        assertEq(pair.balanceOf(address(vault)), lpBefore);
    }

    function test_emergencyEURCBalanceRemainsRedeemable() public {
        uint256 shares = _depositUSDC(alice, 1_000e6);
        vault.emergencyWithdrawLP();

        assertTrue(vault.paused());
        assertEq(pair.balanceOf(address(vault)), 0);
        assertGt(eurc.balanceOf(address(vault)), 0);

        uint256 balanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 redeemed = vault.redeem(shares, alice, alice);

        assertEq(usdc.balanceOf(alice) - balanceBefore, redeemed);
        assertGt(redeemed, 970e6);
        assertEq(eurc.balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function test_twoHoldersRealizeDirectEURCDonation() public {
        uint256 aliceShares = _depositUSDC(alice, 1_000e6);
        uint256 bobShares = _depositUSDC(bob, 1_000e6);

        vm.prank(bob);
        assertTrue(eurc.transfer(address(vault), 100e6));

        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(aliceShares, alice, alice);
        assertGt(aliceAssets, 950e6);
        assertGt(eurc.balanceOf(address(vault)), 0, "final holder donation slice was consumed early");

        uint256 bobPreview = vault.previewRedeem(bobShares);
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(bobShares, bob, bob);
        assertGt(bobAssets, 950e6);
        assertEq(usdc.balanceOf(bob) - bobBalanceBefore, bobAssets);
        assertGt(bobAssets, bobPreview, "final holder did not receive retained surplus");
        assertEq(vault.totalSupply(), 0);
        assertEq(pair.balanceOf(address(vault)), 0);
        assertEq(eurc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function _depositUSDC(address user, uint256 amount) private returns (uint256 shares) {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }
}
