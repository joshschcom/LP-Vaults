// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626}        from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20}          from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20}         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}      from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math}           from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable}        from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable}       from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IBlackholeRouter} from "./interfaces/IBlackholeRouter.sol";
import {IBlackholePair}   from "./interfaces/IBlackholePair.sol";
import {IStableVaultOracle} from "./interfaces/IStableVaultOracle.sol";

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

    uint256 private constant BPS = 10_000;

    // ─── Errors ──────────────────────────────────────────────────────────────
    error Vault__ZeroAmount();
    error Vault__DepositCapExceeded(uint256 cap, uint256 total);
    error Vault__SlippageTooHigh(uint256 bps);
    error Vault__InsufficientOutput(uint256 got, uint256 min);
    error Vault__NotStablePair();
    error Vault__ZeroShares();
    error Vault__ZeroAddress();
    error Vault__InvalidPair();
    error Vault__InvalidOracle(address oracle);
    error Vault__UnsafeSwapQuote(uint256 routerMinimum, uint256 oracleMinimum);
    error Vault__ValuationHaircutTooHigh(uint256 bps);
    error Vault__ValuationHaircutBelowSlippage(uint256 haircutBps, uint256 slippageBps);

    // ─── Events ──────────────────────────────────────────────────────────────
    event DepositedUSDC(address indexed receiver, uint256 usdc, uint256 shares);
    event DepositedEURC(address indexed receiver, uint256 eurc, uint256 shares);
    event SlippageUpdated(uint256 newBps);
    event ValuationHaircutUpdated(uint256 newBps);
    event DepositCapUpdated(uint256 newCap);
    event EmergencyWithdrawn(uint256 usdc, uint256 eurc);

    // ─── Immutables ──────────────────────────────────────────────────────────

    IBlackholeRouter public immutable router;
    IBlackholePair   public immutable pair;
    IStableVaultOracle public immutable priceOracle;

    IERC20 public immutable USDC; // asset() — 6 dec
    IERC20 public immutable EURC; // paired token — 6 dec

    // ─── Storage ─────────────────────────────────────────────────────────────

    /// @notice Max slippage in basis points (default 30 = 0.3%)
    uint256 public slippageBps = 30;

    /// @notice Haircut applied to all EURC value (default 200 = 2%).
    /// @dev Must cover the configured execution slippage and expected exit cost.
    uint256 public valuationHaircutBps = 200;

    /// @notice Hard cap on total assets (0 = uncapped)
    uint256 public depositCap;

    // ─── Constructor ─────────────────────────────────────────────────────────

    /// @param _usdc    USDC token (6 dec) — vault asset
    /// @param _eurc    EURC token (6 dec) — paired token in sAMM
    /// @param _router  Blackhole RouterV2
    /// @param _pair    Blackhole EURC/USDC sAMM pair (stable = true)
    /// @param _priceOracle Independent EURC/USDC valuation oracle
    constructor(
        IERC20 _usdc,
        IERC20 _eurc,
        IBlackholeRouter _router,
        IBlackholePair _pair,
        IStableVaultOracle _priceOracle
    )
        ERC4626(IERC20(address(_usdc)))
        ERC20("Peridot Blackhole USDC/EURC Vault", "pBH-USDC")
        Ownable(msg.sender)
    {
        if (
            address(_usdc) == address(0) || address(_eurc) == address(0) || address(_router) == address(0)
                || address(_pair) == address(0) || address(_priceOracle) == address(0)
        ) revert Vault__ZeroAddress();
        if (!_pair.stable()) revert Vault__NotStablePair();
        address token0 = _pair.token0();
        address token1 = _pair.token1();
        if (
            !(
                (token0 == address(_usdc) && token1 == address(_eurc))
                    || (token0 == address(_eurc) && token1 == address(_usdc))
            )
        ) revert Vault__InvalidPair();
        if (_priceOracle.asset() != address(_usdc) || _priceOracle.pairedToken() != address(_eurc)) {
            revert Vault__InvalidOracle(address(_priceOracle));
        }

        USDC   = _usdc;
        EURC   = _eurc;
        router = _router;
        pair   = _pair;
        priceOracle = _priceOracle;
    }

    // =========================================================================
    // ERC-4626 OVERRIDES
    // =========================================================================

    /// @notice Conservative USDC liquidation value of idle balances and LP.
    function totalAssets() public view override returns (uint256) {
        (uint256 lpUsdc, uint256 lpEurc) = _lpTokenAmounts();
        uint256 managedEurc = EURC.balanceOf(address(this)) + lpEurc;
        return USDC.balanceOf(address(this)) + lpUsdc + _eurcLiquidationValue(managedEurc);
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

    /// @dev A conservative preview may be lower than the USDC actually realized
    ///      when the final holder exits. Return and transfer that full realized
    ///      balance so no shareholder assets remain after all shares are burned.
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        returns (uint256 assets)
    {
        uint256 maxShares = maxRedeem(owner_);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner_, shares, maxShares);
        }

        assets = previewRedeem(shares);
        uint256 supply = totalSupply();
        if (shares > 0 && shares == supply) {
            return _redeemAll(_msgSender(), receiver, owner_, shares, supply);
        }

        _withdraw(_msgSender(), receiver, owner_, assets, shares);
    }

    /// @dev If an exact-asset withdrawal would consume the full conservatively
    ///      priced supply, first realize the strategy and recompute the shares
    ///      against actual USDC. Any execution surplus remains backed by shares
    ///      instead of becoming ownerless after the withdrawal.
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        returns (uint256 shares)
    {
        uint256 maxAssets = maxWithdraw(owner_);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner_, assets, maxAssets);
        }

        shares = previewWithdraw(assets);
        uint256 supply = totalSupply();
        if (shares > 0 && shares == supply) {
            return _withdrawExactAfterFullLiquidation(
                _msgSender(), receiver, owner_, assets, supply
            );
        }

        _withdraw(_msgSender(), receiver, owner_, assets, shares);
    }

    /// @dev Standard USDC deposit — swaps optimal fraction to EURC then LPs.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant whenNotPaused {
        if (assets == 0) revert Vault__ZeroAmount();
        if (shares == 0) revert Vault__ZeroShares();
        if (depositCap > 0 && totalAssets() + assets > depositCap) {
            revert Vault__DepositCapExceeded(depositCap, totalAssets() + assets);
        }

        super._deposit(caller, receiver, assets, shares);
        _deployToLP(USDC.balanceOf(address(this)));

        uint256 managedAfter = totalAssets();
        if (depositCap > 0 && managedAfter > depositCap) {
            revert Vault__DepositCapExceeded(depositCap, managedAfter);
        }
        emit DepositedUSDC(receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        uint256 supply = totalSupply();
        _liquidateWithdrawal(shares, supply);
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    function _redeemAll(
        address caller,
        address receiver,
        address owner_,
        uint256 shares,
        uint256 supply
    ) internal nonReentrant returns (uint256 assets) {
        _liquidateWithdrawal(shares, supply);
        assets = USDC.balanceOf(address(this));
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    function _withdrawExactAfterFullLiquidation(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 supply
    ) internal nonReentrant returns (uint256 shares) {
        _liquidateWithdrawal(supply, supply);
        shares = previewWithdraw(assets);
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    function _liquidateWithdrawal(uint256 shares, uint256 supply) internal {
        if (supply == 0 || shares == 0) return;

        uint256 idleEurc = EURC.balanceOf(address(this));
        uint256 eurcFromLP = _withdrawFromLP(shares, supply);
        uint256 idleEurcToSwap = shares == supply
            ? idleEurc
            : Math.mulDiv(idleEurc, shares, supply);
        uint256 eurcToSwap = idleEurcToSwap + eurcFromLP;
        if (eurcToSwap > 0) _swapEURCtoUSDC(eurcToSwap);
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

        // ERC-4626 deposits price shares before the transferred assets enter
        // totalAssets(). Preserve that invariant for this alternate entry path.
        uint256 assetsBefore = totalAssets();
        uint256 supplyBefore = totalSupply();

        EURC.safeTransferFrom(msg.sender, address(this), eurcAmount);

        // Swap all EURC → USDC at sAMM price
        uint256 usdcOut = _swapEURCtoUSDC(eurcAmount);

        uint256 virtualShares = 10 ** _decimalsOffset();
        shares = Math.mulDiv(
            usdcOut,
            supplyBefore + virtualShares,
            assetsBefore + 1,
            Math.Rounding.Floor
        );
        if (shares == 0) revert Vault__ZeroShares();

        // Share pricing deliberately uses the pre-conversion state. Any LP fee
        // earned by the vault during this atomic conversion is consequently
        // shared pro rata by incumbents and the newly minted shares.

        _mint(receiver, shares);
        _deployToLP(USDC.balanceOf(address(this)));

        // Check the actual strategy value after both swaps and LP deployment.
        // Any failure reverts the complete EURC transfer/conversion atomically.
        uint256 managedAfter = totalAssets();
        if (depositCap > 0 && managedAfter > depositCap) {
            revert Vault__DepositCapExceeded(depositCap, managedAfter);
        }

        emit Deposit(msg.sender, receiver, usdcOut, shares);
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

    /// @dev Remove `shares/totalShares` of LP and return the EURC received.
    ///      The caller combines it with the holder's idle EURC slice so the
    ///      exit uses one price-impacting swap rather than two.
    function _withdrawFromLP(uint256 shares, uint256 totalShares) internal returns (uint256 eurcReceived) {
        uint256 lpBalance = pair.balanceOf(address(this));
        if (lpBalance == 0) return 0;

        uint256 lpToRemove = shares == totalShares ? lpBalance : Math.mulDiv(lpBalance, shares, totalShares);
        if (lpToRemove == 0) return 0;

        // Compute expected outputs for slippage floor
        uint256 supply = pair.totalSupply();
        (uint256 res0, uint256 res1,) = pair.getReserves();

        address tok0 = pair.token0();
        (uint256 resUsdc, uint256 resEurc) = tok0 == address(USDC)
            ? (res0, res1)
            : (res1, res0);

        uint256 expUsdc = Math.mulDiv(resUsdc, lpToRemove, supply);
        uint256 expEurc = Math.mulDiv(resEurc, lpToRemove, supply);

        pair.approve(address(router), lpToRemove);

        (, eurcReceived) = router.removeLiquidity(
            address(USDC),
            address(EURC),
            true,
            lpToRemove,
            _applySlippage(expUsdc),
            _applySlippage(expEurc),
            address(this),
            block.timestamp
        );
        pair.approve(address(router), 0);
    }

    // =========================================================================
    // VALUATION — VIEW
    // =========================================================================

    /// @dev Principal token amounts represented by the vault's LP balance.
    function _lpTokenAmounts() internal view returns (uint256 shareUsdc, uint256 shareEurc) {
        uint256 lpBalance = pair.balanceOf(address(this));
        if (lpBalance == 0) return (0, 0);

        uint256 supply = pair.totalSupply();
        if (supply == 0) return (0, 0);

        (uint256 res0, uint256 res1,) = pair.getReserves();

        address tok0 = pair.token0();
        (uint256 resUsdc, uint256 resEurc) = tok0 == address(USDC)
            ? (res0, res1)
            : (res1, res0);

        shareUsdc = Math.mulDiv(resUsdc, lpBalance, supply);
        shareEurc = Math.mulDiv(resEurc, lpBalance, supply);
    }

    /// @dev Independent oracle value with an exit-cost haircut. Router spot
    ///      quotes are intentionally excluded from ERC-4626 share accounting.
    function _eurcLiquidationValue(uint256 eurcAmount) internal view returns (uint256) {
        if (eurcAmount == 0) return 0;
        return _applyValuationHaircut(priceOracle.quotePairToAsset(eurcAmount));
    }

    // =========================================================================
    // SWAP HELPERS
    // =========================================================================

    function _swapUSDCtoEURC(uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 amountOut)
    {
        uint256 oracleMinimum = _applyValuationHaircut(priceOracle.quoteAssetToPair(amountIn));
        if (minOut < oracleMinimum) revert Vault__UnsafeSwapQuote(minOut, oracleMinimum);

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
        uint256 minOut = _applySlippage(quoted);
        uint256 oracleMinimum = _eurcLiquidationValue(amountIn);
        if (minOut < oracleMinimum) revert Vault__UnsafeSwapQuote(minOut, oracleMinimum);
        return _swapEURCtoUSDC_min(amountIn, minOut);
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
        return Math.mulDiv(amount, BPS - slippageBps, BPS);
    }

    function _applyValuationHaircut(uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, BPS - valuationHaircutBps, BPS);
    }

    // =========================================================================
    // EMERGENCY / ADMIN
    // =========================================================================

    /// @notice Pull all LP and hold tokens idle in the vault (no swap back).
    function emergencyWithdrawLP() external onlyOwner {
        if (!paused()) _pause();

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
    ///         Cannot sweep either managed token or the backing LP token.
    function sweep(IERC20 token, address to, uint256 amount) external onlyOwner {
        require(
            address(token) != address(USDC) && address(token) != address(EURC) && address(token) != address(pair),
            "cannot sweep vault tokens"
        );
        token.safeTransfer(to, amount);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setSlippage(uint256 _bps) external onlyOwner {
        if (_bps > 200) revert Vault__SlippageTooHigh(_bps);
        if (_bps > valuationHaircutBps) {
            revert Vault__ValuationHaircutBelowSlippage(valuationHaircutBps, _bps);
        }
        slippageBps = _bps;
        emit SlippageUpdated(_bps);
    }

    function setValuationHaircut(uint256 _bps) external onlyOwner {
        if (_bps > 2_000) revert Vault__ValuationHaircutTooHigh(_bps);
        if (_bps < slippageBps) revert Vault__ValuationHaircutBelowSlippage(_bps, slippageBps);
        valuationHaircutBps = _bps;
        emit ValuationHaircutUpdated(_bps);
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
