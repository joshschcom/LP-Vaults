// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PharaohRewardCompounder} from "../contracts/PharaohRewardCompounder.sol";
import {IPharaohSwapRouter} from "../contracts/interfaces/pharaoh/IPharaohSwapRouter.sol";

contract CompounderTestToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

contract CompounderTestSafe {}

contract CompounderTestVault {
    address public owner;
    address public asset;
    IPharaohSwapRouter public swapRouter;

    constructor(address owner_, address asset_, IPharaohSwapRouter swapRouter_) {
        owner = owner_;
        asset = asset_;
        swapRouter = swapRouter_;
    }
}

contract CompounderTestRouter is IPharaohSwapRouter {
    using SafeERC20 for IERC20;

    uint256 private constant PHAR_UNIT = 1e18;

    address public immutable override deployer;
    CompounderTestToken public immutable phar;
    CompounderTestToken public immutable wavax;
    CompounderTestToken public immutable usdc;
    int24 public immutable pharWavaxSpacing;
    int24 public immutable wavaxUsdcSpacing;

    uint256 public wavaxPerPhar = 3e15;
    uint256 public usdcPerPhar = 19_000;
    bytes32 public lastPathHash;
    address public lastRecipient;
    uint256 public lastAmountIn;
    uint256 public lastMinimumOut;

    constructor(
        address deployer_,
        CompounderTestToken phar_,
        CompounderTestToken wavax_,
        CompounderTestToken usdc_,
        int24 pharWavaxSpacing_,
        int24 wavaxUsdcSpacing_
    ) {
        deployer = deployer_;
        phar = phar_;
        wavax = wavax_;
        usdc = usdc_;
        pharWavaxSpacing = pharWavaxSpacing_;
        wavaxUsdcSpacing = wavaxUsdcSpacing_;
    }

    function setRates(uint256 wavaxPerPhar_, uint256 usdcPerPhar_) external {
        wavaxPerPhar = wavaxPerPhar_;
        usdcPerPhar = usdcPerPhar_;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        bytes memory expectedPath =
            abi.encodePacked(address(phar), pharWavaxSpacing, address(wavax), wavaxUsdcSpacing, address(usdc));
        require(keccak256(params.path) == keccak256(expectedPath), "wrong path");
        require(params.deadline >= block.timestamp, "expired");

        IERC20(address(phar)).safeTransferFrom(msg.sender, address(this), params.amountIn);
        amountOut = Math.mulDiv(params.amountIn, usdcPerPhar, PHAR_UNIT);
        require(amountOut >= params.amountOutMinimum, "minimum output");
        usdc.mint(params.recipient, amountOut);

        lastPathHash = keccak256(params.path);
        lastRecipient = params.recipient;
        lastAmountIn = params.amountIn;
        lastMinimumOut = params.amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        require(params.tokenIn == address(phar), "wrong input");
        require(params.tokenOut == address(wavax), "wrong output");
        require(params.tickSpacing == pharWavaxSpacing, "wrong spacing");
        require(params.deadline >= block.timestamp, "expired");

        IERC20(address(phar)).safeTransferFrom(msg.sender, address(this), params.amountIn);
        amountOut = Math.mulDiv(params.amountIn, wavaxPerPhar, PHAR_UNIT);
        require(amountOut >= params.amountOutMinimum, "minimum output");
        wavax.mint(params.recipient, amountOut);

        lastRecipient = params.recipient;
        lastAmountIn = params.amountIn;
        lastMinimumOut = params.amountOutMinimum;
    }
}

    contract PharaohRewardCompounderTest is Test {
        uint256 private constant DEADLINE = 2 days;
        int24 private constant PHAR_WAVAX_SPACING = 5;
        int24 private constant WAVAX_USDC_SPACING = 10;

        CompounderTestToken private phar;
        CompounderTestToken private wavax;
        CompounderTestToken private usdc;
        CompounderTestSafe private safe;
        CompounderTestRouter private router;
        CompounderTestVault private usdcVault;
        CompounderTestVault private wavaxVault;
        PharaohRewardCompounder private compounder;

        function setUp() public {
            vm.warp(1 days);
            phar = new CompounderTestToken("PHAR", 18);
            wavax = new CompounderTestToken("WAVAX", 18);
            usdc = new CompounderTestToken("USDC", 6);
            safe = new CompounderTestSafe();
            router = new CompounderTestRouter(address(this), phar, wavax, usdc, PHAR_WAVAX_SPACING, WAVAX_USDC_SPACING);
            usdcVault = new CompounderTestVault(address(safe), address(usdc), router);
            wavaxVault = new CompounderTestVault(address(safe), address(wavax), router);
            compounder = _deploy(address(usdcVault), address(wavaxVault));

            phar.mint(address(safe), 100 ether);
            vm.prank(address(safe));
            phar.approve(address(compounder), type(uint256).max);
        }

        function test_constructorPinsConfiguration() public view {
            assertEq(compounder.safe(), address(safe));
            assertEq(address(compounder.phar()), address(phar));
            assertEq(address(compounder.wavax()), address(wavax));
            assertEq(address(compounder.usdc()), address(usdc));
            assertEq(address(compounder.swapRouter()), address(router));
            assertEq(compounder.usdcVault(), address(usdcVault));
            assertEq(compounder.wavaxVault(), address(wavaxVault));
            assertEq(compounder.pharWavaxTickSpacing(), PHAR_WAVAX_SPACING);
            assertEq(compounder.wavaxUsdcTickSpacing(), WAVAX_USDC_SPACING);
        }

        function test_compoundToWavaxUsesPinnedPoolAndDonatesOutput() public {
            uint256 pharIn = 10 ether;
            uint256 minimumRate = 2.9e15;

            vm.prank(address(safe));
            (uint256 actualIn, uint256 assetOut) =
                compounder.compound(address(wavaxVault), pharIn, pharIn, minimumRate, DEADLINE);

            assertEq(actualIn, pharIn);
            assertEq(assetOut, 0.03 ether);
            assertEq(wavax.balanceOf(address(wavaxVault)), assetOut);
            assertEq(router.lastRecipient(), address(wavaxVault));
            assertEq(router.lastAmountIn(), pharIn);
            assertEq(router.lastMinimumOut(), 0.029 ether);
            assertEq(phar.balanceOf(address(safe)), 90 ether);
            assertEq(phar.balanceOf(address(compounder)), 0);
            assertEq(phar.allowance(address(compounder), address(router)), 0);
        }

        function test_compoundToUsdcUsesPinnedMultihopAndDonatesOutput() public {
            uint256 pharIn = 10 ether;
            uint256 minimumRate = 18_000;
            bytes memory expectedPath =
                abi.encodePacked(address(phar), PHAR_WAVAX_SPACING, address(wavax), WAVAX_USDC_SPACING, address(usdc));

            vm.prank(address(safe));
            (uint256 actualIn, uint256 assetOut) =
                compounder.compound(address(usdcVault), pharIn, pharIn, minimumRate, DEADLINE);

            assertEq(actualIn, pharIn);
            assertEq(assetOut, 190_000);
            assertEq(usdc.balanceOf(address(usdcVault)), assetOut);
            assertEq(router.lastPathHash(), keccak256(expectedPath));
            assertEq(router.lastRecipient(), address(usdcVault));
            assertEq(router.lastMinimumOut(), 180_000);
            assertEq(phar.balanceOf(address(compounder)), 0);
            assertEq(phar.allowance(address(compounder), address(router)), 0);
        }

        function test_maximumPharCapsSafeBalance() public {
            vm.prank(address(safe));
            (uint256 actualIn,) = compounder.compound(address(wavaxVault), 1 ether, 3 ether, 1, DEADLINE);

            assertEq(actualIn, 3 ether);
            assertEq(phar.balanceOf(address(safe)), 97 ether);
        }

        function test_revertsForUnauthorizedCaller() public {
            vm.expectRevert(
                abi.encodeWithSelector(PharaohRewardCompounder.Compounder__Unauthorized.selector, address(this))
            );
            compounder.compound(address(wavaxVault), 1 ether, 1 ether, 1, DEADLINE);
        }

        function test_revertsForUnsupportedVault() public {
            address unsupported = makeAddr("unsupported");
            vm.prank(address(safe));
            vm.expectRevert(
                abi.encodeWithSelector(PharaohRewardCompounder.Compounder__InvalidVault.selector, unsupported)
            );
            compounder.compound(unsupported, 1 ether, 1 ether, 1, DEADLINE);
        }

        function test_revertsWhenSafeRewardIsBelowMinimum() public {
            vm.prank(address(safe));
            vm.expectRevert(
                abi.encodeWithSelector(
                    PharaohRewardCompounder.Compounder__InsufficientPhar.selector, 100 ether, 101 ether
                )
            );
            compounder.compound(address(wavaxVault), 101 ether, type(uint256).max, 1, DEADLINE);
        }

        function test_revertsForInvalidBoundsAndMinimumRate() public {
            vm.startPrank(address(safe));
            vm.expectRevert(
                abi.encodeWithSelector(PharaohRewardCompounder.Compounder__InvalidPharBounds.selector, 0, 1 ether)
            );
            compounder.compound(address(wavaxVault), 0, 1 ether, 1, DEADLINE);

            vm.expectRevert(
                abi.encodeWithSelector(PharaohRewardCompounder.Compounder__InvalidPharBounds.selector, 2 ether, 1 ether)
            );
            compounder.compound(address(wavaxVault), 2 ether, 1 ether, 1, DEADLINE);

            vm.expectRevert(abi.encodeWithSelector(PharaohRewardCompounder.Compounder__InvalidMinimumRate.selector, 0));
            compounder.compound(address(wavaxVault), 1 ether, 1 ether, 0, DEADLINE);
            vm.stopPrank();
        }

        function test_revertsForExpiredBatch() public {
            vm.prank(address(safe));
            vm.expectRevert(
                abi.encodeWithSelector(
                    PharaohRewardCompounder.Compounder__Expired.selector, block.timestamp - 1, block.timestamp
                )
            );
            compounder.compound(address(wavaxVault), 1 ether, 1 ether, 1, block.timestamp - 1);
        }

        function test_slippageFailureRollsBackPullAndApproval() public {
            uint256 safeBefore = phar.balanceOf(address(safe));
            vm.prank(address(safe));
            vm.expectRevert("minimum output");
            compounder.compound(address(wavaxVault), 1 ether, 1 ether, 4e15, DEADLINE);

            assertEq(phar.balanceOf(address(safe)), safeBefore);
            assertEq(phar.balanceOf(address(compounder)), 0);
            assertEq(phar.allowance(address(compounder), address(router)), 0);
            assertEq(wavax.balanceOf(address(wavaxVault)), 0);
        }

        function test_accidentalTokenCanOnlyBeRecoveredToSafe() public {
            usdc.mint(address(compounder), 25e6);

            vm.expectRevert(
                abi.encodeWithSelector(PharaohRewardCompounder.Compounder__Unauthorized.selector, address(this))
            );
            compounder.recoverToken(usdc);

            vm.prank(address(safe));
            uint256 recovered = compounder.recoverToken(usdc);
            assertEq(recovered, 25e6);
            assertEq(usdc.balanceOf(address(safe)), 25e6);
            assertEq(usdc.balanceOf(address(compounder)), 0);
        }

        function test_constructorRejectsMismatchedVaultOwner() public {
            CompounderTestVault wrongVault = new CompounderTestVault(address(this), address(usdc), router);
            vm.expectRevert(
                abi.encodeWithSelector(
                    PharaohRewardCompounder.Compounder__InvalidVaultConfiguration.selector, address(wrongVault)
                )
            );
            _deploy(address(wrongVault), address(wavaxVault));
        }

        function _deploy(address usdcVault_, address wavaxVault_) private returns (PharaohRewardCompounder) {
            return new PharaohRewardCompounder(
                PharaohRewardCompounder.Config({
                    safe: address(safe),
                    phar: phar,
                    wavax: wavax,
                    usdc: usdc,
                    swapRouter: router,
                    usdcVault: usdcVault_,
                    wavaxVault: wavaxVault_,
                    pharWavaxTickSpacing: PHAR_WAVAX_SPACING,
                    wavaxUsdcTickSpacing: WAVAX_USDC_SPACING
                })
            );
        }
    }
