// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626}        from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20}          from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20}         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}      from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable}        from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable}       from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBlackholeRouter} from "./interfaces/IBlackholeRouter.sol";
import {IBlackholePair}   from "./interfaces/IBlackholePair.sol";

/// ============================================================
/// @title  BlackholeStableVault
/// @notice ERC-4626 vault that deposits into the Blackhole sAMM EURC/USDC
///         pair (Solidly/Thena V2 fork, x³y+y³x invariant) to earn swap fees.
///
/// @dev    Architecture
///           Asset = USDC (6 dec). Shares are USDC-denominated.
///
///           USDC deposit path:
///             deposit(amount, receiver)
///             └─ swap optimal fraction USDC→EURC at on-chain sAMM price
///             └─ addLiquidity(USDC, EURC, stable=true, ...)
///             └─ vault holds ERC-20 LP tokens
///
///           EURC deposit path:
///             depositEURC(amount, receiver)
///             └─ swap all EURC→USDC first (on-chain price)
///             └─ then same LP path as USDC deposit
///
///           Withdraw path:
///             _withdraw (standard ERC-4626)
///             └─ removeLiquidity proportional to shares redeemed
///             └─ swap EURC proceeds back to USDC
///             └─ transfer USDC to receiver
///
///           LP is standard ERC-20 (full range, Solidly sAMM).
///           No rebalancing needed — ever.
///
/// @dev    ⚠️  ADDRESSES NOT YET FILLED
///           BLACKHOLE_ROUTER and EURC_USDC_PAIR are address(0) placeholders.
///           Find them via Snowscan name-tag search for "Blackhole" or contact
///           kenneth [at] blackhole.xyz / discord.gg/blackholedex.
///           Verify: router.addLiquidity exists, pair.stable() == true.
///
/// ============================================================
contract BlackholeStableVault is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Errors ──────────────────────────────────────────────────────────────
    error Vault__ZeroAmount();
    error Vault__DepositCapExceeded(uint256 cap, uint256 total);
    error Vault__SlippageTooHigh(uint256 bps);
    error Vault__InsufficientOutput(uint256 got, uint256 min);
    error Vault__NotStablePair();

    // ─── Events ──────────────────────────────────────────────────────────────
    event DepositedUSDC(address indexed receiver, uint256 usdc, uint256 shares);
    event DepositedEURC(address indexed receiver, uint256 eurc, uint256 shares);
    event SlippageUpdated(uint256 newBps);
    event DepositCapUpdated(uint256 newCap);
    event EmergencyWithdrawn(uint256 usdc, uint256 eurc);

    // ─── Immutables ──────────────────────────────────────────────────────────

    IBlackholeRouter public immutable router;
    IBlackholePair   public immutable pair;

    IERC20 public immutable USDC; // asset() — 6 dec
    IERC20 public immutable EURC; // paired token — 6 dec

    // ─── Storage ─────────────────────────────────────────────────────────────

    /// @notice Max slippage in basis points (default 30 = 0.3%)
    uint256 public slippageBps = 30;

    /// @notice Hard cap on total assets (0 = uncapped)
    uint256 public depositCap;

    // ─── Constructor ─────────────────────────────────────────────────────────

    /// @param _usdc    USDC token (6 dec) — vault asset
    /// @param _eurc    EURC token (6 dec) — paired token in sAMM
    /// @param _router  Blackhole RouterV2
    /// @param _pair    Blackhole EURC/USDC sAMM pair (stable = true)
    constructor(
        IERC20 _usdc,
        IERC20 _eurc,
        IBlackholeRouter _router,
        IBlackholePair _pair
    )
        ERC4626(IERC20(address(_usdc)))
        ERC20("Peridot Blackhole USDC/EURC Vault", "pBH-USDC")
        Ownable(msg.sender)
    {
        if (!_pair.stable()) revert Vault__NotStablePair();

        USDC   = _usdc;
        EURC   = _eurc;
        router = _router;
        pair   = _pair;
    }

    // =========================================================================
    // ERC-4626 OVERRIDES
    // =========================================================================

    /// @notice Total USDC value managed by the vault (idle + LP value)
    function totalAssets() public view override returns (uint256) {
        return USDC.balanceOf(address(this)) + _lpValueInUSDC();
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (depositCap == 0) return type(uint256).max;
        uint256 ta = totalAssets();
        if (ta >= depositCap) return 0;
        return depositCap - ta;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    /// @dev Standard USDC deposit — swaps optimal fraction to EURC then LPs.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant whenNotPaused {
        if (assets == 0) revert Vault__ZeroAmount();
        if (depositCap > 0 && totalAssets() + assets > depositCap) {
            revert Vault__DepositCapExceeded(depositCap, totalAssets() + assets);
        }

        super._deposit(caller, receiver, assets, shares);
        _deployToLP(USDC.balanceOf(address(this)));
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        uint256 supply = totalSupply();
        if (supply > 0) {
            _withdrawFromLP(shares, supply);
        }
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    // =========================================================================
    // EURC DEPOSIT PATH
    // =========================================================================

    /// @notice Deposit EURC — swaps all EURC→USDC at on-chain sAMM price,
    ///         then uses the standard LP path.
    ///         Shares minted ≈ EURC amount (both are 6 dec, 1:1 peg at sAMM price).
    function depositEURC(uint256 eurcAmount, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (eurcAmount == 0) revert Vault__ZeroAmount();

        EURC.safeTransferFrom(msg.sender, address(this), eurcAmount);

        // Swap all EURC → USDC at sAMM price
        uint256 usdcOut = _swapEURCtoUSDC(eurcAmount);

        // Now deposit the USDC on behalf of receiver
        shares = convertToShares(usdcOut);

        if (depositCap > 0 && totalAssets() + usdcOut > depositCap) {
            revert Vault__DepositCapExceeded(depositCap, totalAssets() + usdcOut);
        }

        _mint(receiver, shares);
        _deployToLP(USDC.balanceOf(address(this)));

        emit DepositedEURC(receiver, eurcAmount, shares);
    }

    // =========================================================================
    // LP MANAGEMENT — INTERNAL
    // =========================================================================

    /// @dev Swap ~half USDC → EURC, then addLiquidity.
    ///      For a sAMM at peg, optimal split is 50/50.
    function _deployToLP(uint256 usdcAmount) internal {
        if (usdcAmount < 2) return;

        uint256 halfUsdc     = usdcAmount / 2;
        uint256 remainingUsdc = usdcAmount - halfUsdc;

        // Quote swap to get minOut
        (uint256 quoted,) = router.getAmountOut(halfUsdc, address(USDC), address(EURC), true);
        uint256 minEurcOut = _applySlippage(quoted);

        // Swap
        uint256 eurcOut = _swapUSDCtoEURC(halfUsdc, minEurcOut);

        // Approve router to pull both tokens
        USDC.forceApprove(address(router), remainingUsdc);
        EURC.forceApprove(address(router), eurcOut);

        router.addLiquidity(
            address(USDC),
            address(EURC),
            true,                        // stable sAMM
            remainingUsdc,
            eurcOut,
            _applySlippage(remainingUsdc),
            _applySlippage(eurcOut),
            address(this),
            block.timestamp
        );

        // Clear allowances
        USDC.forceApprove(address(router), 0);
        EURC.forceApprove(address(router), 0);
    }

    /// @dev Remove `shares/totalShares` of LP, swap EURC proceeds back to USDC.
    function _withdrawFromLP(uint256 shares, uint256 totalShares) internal {
        uint256 lpBalance = pair.balanceOf(address(this));
        if (lpBalance == 0) return;

        uint256 lpToRemove = (lpBalance * shares) / totalShares;
        if (lpToRemove == 0) return;

        // Compute expected outputs for slippage floor
        uint256 supply = pair.totalSupply();
        (uint256 res0, uint256 res1,) = pair.getReserves();

        address tok0 = pair.token0();
        (uint256 resUsdc, uint256 resEurc) = tok0 == address(USDC)
            ? (res0, res1)
            : (res1, res0);

        uint256 expUsdc = (resUsdc * lpToRemove) / supply;
        uint256 expEurc = (resEurc * lpToRemove) / supply;

        pair.approve(address(router), lpToRemove);

        (uint256 gotUsdc, uint256 gotEurc) = router.removeLiquidity(
            address(USDC),
            address(EURC),
            true,
            lpToRemove,
            _applySlippage(expUsdc),
            _applySlippage(expEurc),
            address(this),
            block.timestamp
        );

        // Swap EURC proceeds → USDC
        if (gotEurc > 0) {
            (uint256 quotedBack,) = router.getAmountOut(gotEurc, address(EURC), address(USDC), true);
            _swapEURCtoUSDC_min(gotEurc, _applySlippage(quotedBack));
        }

        // gotUsdc sits in the vault; ERC-4626 _withdraw will send it out
    }

    // =========================================================================
    // VALUATION — VIEW
    // =========================================================================

    /// @dev LP value in USDC terms.
    ///      Both USDC and EURC are 6 dec so no normalisation needed.
    ///      At 1:1 peg this is exact; a depeg will over/understate value.
    function _lpValueInUSDC() internal view returns (uint256) {
        uint256 lpBalance = pair.balanceOf(address(this));
        if (lpBalance == 0) return 0;

        uint256 supply = pair.totalSupply();
        if (supply == 0) return 0;

        (uint256 res0, uint256 res1,) = pair.getReserves();

        address tok0 = pair.token0();
        (uint256 resUsdc, uint256 resEurc) = tok0 == address(USDC)
            ? (res0, res1)
            : (res1, res0);

        // Pro-rata share at 1:1 price (EURC ≈ USDC, both 6 dec)
        uint256 shareUsdc = (resUsdc * lpBalance) / supply;
        uint256 shareEurc = (resEurc * lpBalance) / supply;

        return shareUsdc + shareEurc;
    }

    // =========================================================================
    // SWAP HELPERS
    // =========================================================================

    function _swapUSDCtoEURC(uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 amountOut)
    {
        USDC.forceApprove(address(router), amountIn);

        IBlackholeRouter.route[] memory routes = new IBlackholeRouter.route[](1);
        routes[0] = IBlackholeRouter.route({
            pair:         address(pair),
            from:         address(USDC),
            to:           address(EURC),
            stable:       true,
            concentrated: false,
            receiver:     address(this)
        });

        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minOut,
            routes,
            address(this),
            block.timestamp
        );

        USDC.forceApprove(address(router), 0);

        amountOut = amounts[amounts.length - 1];
        if (amountOut < minOut) revert Vault__InsufficientOutput(amountOut, minOut);
    }

    function _swapEURCtoUSDC(uint256 amountIn) internal returns (uint256 amountOut) {
        (uint256 quoted,) = router.getAmountOut(amountIn, address(EURC), address(USDC), true);
        return _swapEURCtoUSDC_min(amountIn, _applySlippage(quoted));
    }

    function _swapEURCtoUSDC_min(uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 amountOut)
    {
        EURC.forceApprove(address(router), amountIn);

        IBlackholeRouter.route[] memory routes = new IBlackholeRouter.route[](1);
        routes[0] = IBlackholeRouter.route({
            pair:         address(pair),
            from:         address(EURC),
            to:           address(USDC),
            stable:       true,
            concentrated: false,
            receiver:     address(this)
        });

        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minOut,
            routes,
            address(this),
            block.timestamp
        );

        EURC.forceApprove(address(router), 0);

        amountOut = amounts[amounts.length - 1];
        if (amountOut < minOut) revert Vault__InsufficientOutput(amountOut, minOut);
    }

    // =========================================================================
    // UTILITY
    // =========================================================================

    function _applySlippage(uint256 amount) internal view returns (uint256) {
        return (amount * (10_000 - slippageBps)) / 10_000;
    }

    // =========================================================================
    // EMERGENCY / ADMIN
    // =========================================================================

    /// @notice Pull all LP and hold tokens idle in the vault (no swap back).
    function emergencyWithdrawLP() external onlyOwner {
        _pause();

        uint256 lpBalance = pair.balanceOf(address(this));
        if (lpBalance == 0) return;

        pair.approve(address(router), lpBalance);

        (uint256 gotUsdc, uint256 gotEurc) = router.removeLiquidity(
            address(USDC),
            address(EURC),
            true,
            lpBalance,
            0, // no min in emergency
            0,
            address(this),
            block.timestamp
        );

        emit EmergencyWithdrawn(gotUsdc, gotEurc);
    }

    /// @notice Recover tokens accidentally sent to this contract.
    ///         Cannot sweep USDC or EURC.
    function sweep(IERC20 token, address to, uint256 amount) external onlyOwner {
        require(token != USDC && token != EURC, "cannot sweep vault tokens");
        token.safeTransfer(to, amount);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setSlippage(uint256 _bps) external onlyOwner {
        if (_bps > 200) revert Vault__SlippageTooHigh(_bps);
        slippageBps = _bps;
        emit SlippageUpdated(_bps);
    }

    function setDepositCap(uint256 _cap) external onlyOwner {
        depositCap = _cap;
        emit DepositCapUpdated(_cap);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    function getLPBalance() external view returns (uint256) {
        return pair.balanceOf(address(this));
    }
}
