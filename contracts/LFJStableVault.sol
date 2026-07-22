// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable}  from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20}         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20}      from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {ILBRouter} from "./interfaces/ILBRouter.sol";
import {ILBPair}   from "./interfaces/ILBPair.sol";

/// ============================================================
/// @title  LFJStableVault
/// @notice ERC-4626 vault that deposits into an LFJ Liquidity Book
///         stable pair (e.g. USDC/AUSD, 1bps bin step) to earn swap
///         fees. Designed to back Peridot boosted markets.
///
/// @dev    Architecture
///           User deposits the ERC-4626 asset (either tokenX or tokenY)
///           └─ Vault swaps ~50% to the paired token via LFJ
///           └─ Deposits both sides into LB pair across `binRange` bins
///           └─ Mints ERC-4626 shares backed by LP value in asset terms
///           Rebalancer (keeper / Gelato) calls rebalance() when active
///           bin drifts outside deposited range.
///
/// @dev    Token ordering
///           LFJ pairs have fixed tokenX/tokenY ordering. The constructor
///           checks the supplied tokens against pair.getTokenX()/getTokenY().
///
/// ============================================================
contract LFJStableVault is Initializable, ERC4626Upgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ─── Errors ──────────────────────────────────────────────────────────────
    error Vault__NotRebalancer();
    error Vault__DepositCapExceeded(uint256 cap, uint256 total);
    error Vault__ZeroAmount();
    error Vault__SlippageTooHigh(uint256 bps);
    error Vault__TokenOrderViolation();
    error Vault__InvalidAsset();
    error Vault__AmountTooLargeForQuote(uint256 amount);
    error Vault__InsufficientOutputFromSwap(uint256 got, uint256 min);

    // ─── Events ──────────────────────────────────────────────────────────────
    event Rebalanced(uint256 assetsRedeployed);
    event BinRangeUpdated(uint256 newRange);
    event SlippageUpdated(uint256 newBps);
    event DepositCapUpdated(uint256 newCap);
    event RebalancerUpdated(address newRebalancer);
    event EmergencyWithdrawn(uint256 amountX, uint256 amountY);

    // ─── Strategy Configuration ──────────────────────────────────────────────

    ILBRouter public lbRouter;
    ILBPair   public lbPair;

    /// @notice tokenX of the LB pair
    IERC20 public tokenX;
    /// @notice tokenY of the LB pair
    IERC20 public tokenY;

    /// @notice True when ERC-4626 asset() is LFJ tokenX, false when it is tokenY.
    bool public assetIsTokenX;

    uint16 public BIN_STEP;

    /// @notice LFJ router version for the target pair (V2_1 or V2_2).
    ///         Must match the version the pair was created with.
    ILBRouter.Version public PAIR_VERSION;

    uint8 public TOKEN_X_DECIMALS;
    uint8 public TOKEN_Y_DECIMALS;
    uint8 public ASSET_DECIMALS;

    // ─── Storage ─────────────────────────────────────────────────────────────

    /// @notice Bins we have liquidity in (no duplicates, cleaned on exit)
    uint24[] public depositedBins;
    /// @notice LB-token balance per bin (pair.totalSupply(id) denomination)
    mapping(uint24 => uint256) public binLBAmounts;

    /// @notice Bins on each side to spread around the active bin (default 2)
    uint256 public binRange = 2;

    /// @notice Max slippage in basis points (default 30 = 0.3%)
    uint256 public slippageBps = 30;

    /// @notice Hard cap on total assets (0 = uncapped)
    uint256 public depositCap;

    /// @notice Address allowed to call rebalance()
    address public rebalancer;

    // ─── Initialization ──────────────────────────────────────────────────────

    constructor() {
        _disableInitializers();
    }

    /// @param _asset     ERC-4626 deposit asset. Must be either _tokenX or _tokenY.
    /// @param _tokenX    LFJ pair tokenX — must be pair.getTokenX()
    /// @param _tokenY    LFJ pair tokenY — must be pair.getTokenY()
    /// @param _lbRouter  LFJ LBRouter
    /// @param _lbPair    Target LB pair (USDC/AUSD)
    /// @param _version   Router version matching the pair (V2_1 or V2_2)
    /// @param _rebalancer Keeper address
    function initialize(
        IERC20 _asset,
        IERC20 _tokenX,
        IERC20 _tokenY,
        ILBRouter _lbRouter,
        ILBPair _lbPair,
        ILBRouter.Version _version,
        address _rebalancer,
        address _owner,
        uint256 _depositCap,
        uint256 _binRange,
        uint256 _slippageBps
    ) external initializer {
        __ERC20_init("Peridot LFJ USDC/AUSD Vault", "pLFJ-USDC");
        __ERC4626_init(_asset);
        __Ownable_init(_owner);
        __Pausable_init();
        __ReentrancyGuard_init();

        if (address(_asset) != address(_tokenX) && address(_asset) != address(_tokenY)) {
            revert Vault__InvalidAsset();
        }
        if (_lbPair.getTokenX() != address(_tokenX) || _lbPair.getTokenY() != address(_tokenY)) {
            revert Vault__TokenOrderViolation();
        }

        lbRouter     = _lbRouter;
        lbPair       = _lbPair;
        tokenX       = _tokenX;
        tokenY       = _tokenY;
        assetIsTokenX = address(_asset) == address(_tokenX);
        BIN_STEP     = _lbPair.getBinStep();
        PAIR_VERSION = _version;
        rebalancer   = _rebalancer;

        TOKEN_X_DECIMALS = IERC20Metadata(address(_tokenX)).decimals();
        TOKEN_Y_DECIMALS = IERC20Metadata(address(_tokenY)).decimals();
        ASSET_DECIMALS   = IERC20Metadata(address(_asset)).decimals();

        _setDepositCap(_depositCap);
        _setBinRange(_binRange);
        _setSlippage(_slippageBps);
    }

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyRebalancer() {
        if (msg.sender != rebalancer && msg.sender != owner()) revert Vault__NotRebalancer();
        _;
    }

    // =========================================================================
    // ERC-4626 OVERRIDES
    // =========================================================================

    /// @notice Total asset value managed by the vault (idle + LP value)
    function totalAssets() public view override returns (uint256) {
        return _idleValueInAsset() + _lpValueInAsset();
    }

    /// @notice Max deposit enforces the deposit cap
    function maxDeposit(address) public view override returns (uint256) {
        if (depositCap == 0) return type(uint256).max;
        uint256 ta = totalAssets();
        if (ta >= depositCap) return 0;
        return depositCap - ta;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

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
        _deployToLP(_assetToken().balanceOf(address(this)));
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override nonReentrant {
        // Pull proportional share of LP before executing the transfer
        uint256 supply = totalSupply();
        if (supply > 0 && depositedBins.length > 0) {
            _withdrawFromLP(shares, supply);
        }
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    // =========================================================================
    // LP MANAGEMENT — INTERNAL
    // =========================================================================

    /// @dev Deploy `assetAmount` into the LB pair.
    ///      Swaps half of the asset into the paired side, then calls addLiquidity.
    function _deployToLP(uint256 assetAmount) internal {
        if (assetAmount < 2) return; // dust guard

        uint256 amountX;
        uint256 amountY;

        if (assetIsTokenX) {
            uint256 halfX      = assetAmount / 2;
            uint256 remainingX = assetAmount - halfX; // handles odd wei

            amountX = remainingX;
            amountY = _swapXforY(halfX, _applySlippage(_quoteSwapXforY(_toUint128(halfX))));
        } else {
            uint256 halfY      = assetAmount / 2;
            uint256 remainingY = assetAmount - halfY;

            amountX = _swapYforX(halfY, _applySlippage(_quoteSwapYforX(_toUint128(halfY))));
            amountY = remainingY;
        }

        // ── 2. Build bin distribution around active bin ──────────────────────
        uint24 activeBin = lbPair.getActiveId();

        (
            int256[]  memory deltaIds,
            uint256[] memory distX,
            uint256[] memory distY
        ) = _buildDistribution();

        // ── 3. Approve router ────────────────────────────────────────────────
        tokenX.forceApprove(address(lbRouter), amountX);
        tokenY.forceApprove(address(lbRouter), amountY);

        // ── 4. Add liquidity ─────────────────────────────────────────────────
        ILBRouter.LiquidityParameters memory params = ILBRouter.LiquidityParameters({
            tokenX:          tokenX,
            tokenY:          tokenY,
            binStep:         BIN_STEP,
            amountX:         amountX,
            amountY:         amountY,
            amountXMin:      _applySlippage(amountX),
            amountYMin:      _applySlippage(amountY),
            activeIdDesired: activeBin,
            idSlippage:      binRange + 1, // extra tolerance for block latency
            deltaIds:        deltaIds,
            distributionX:   distX,
            distributionY:   distY,
            to:              address(this),
            refundTo:        address(this),
            deadline:        block.timestamp
        });

        (,,,, uint256[] memory depositIds, uint256[] memory liquidityMinted) =
            lbRouter.addLiquidity(params);

        // ── 5. Track bin positions ───────────────────────────────────────────
        for (uint256 i; i < depositIds.length; ) {
            uint24 binId = uint24(depositIds[i]);
            if (binLBAmounts[binId] == 0) {
                depositedBins.push(binId);
            }
            binLBAmounts[binId] += liquidityMinted[i];
            unchecked { ++i; }
        }

        // ── 6. Clear allowances ──────────────────────────────────────────────
        tokenX.forceApprove(address(lbRouter), 0);
        tokenY.forceApprove(address(lbRouter), 0);
    }

    /// @dev Withdraw `shares/totalShares` proportion of every bin,
    ///      then swap returned non-asset tokens back to the ERC-4626 asset.
    function _withdrawFromLP(uint256 shares, uint256 totalShares) internal {
        uint256 len = depositedBins.length;
        if (len == 0) return;

        uint256[] memory ids     = new uint256[](len);
        uint256[] memory amounts = new uint256[](len);

        uint256 nonZero;
        for (uint256 i; i < len; ) {
            uint24 binId  = depositedBins[i];
            uint256 total = binLBAmounts[binId];
            uint256 toRemove = (total * shares) / totalShares;

            if (toRemove > 0) {
                ids[nonZero]     = binId;
                amounts[nonZero] = toRemove;
                unchecked { ++nonZero; }
            }
            unchecked { ++i; }
        }

        if (nonZero == 0) return;

        // Trim arrays to actual non-zero count
        assembly { mstore(ids, nonZero) mstore(amounts, nonZero) }

        // Compute min amounts from bin reserves (proportional, slippage applied)
        (uint256 expectedX, uint256 expectedY) = _expectedWithdrawAmounts(ids, amounts);

        // Approve router to burn LB tokens (ERC-1155-style approval on pair)
        if (!lbPair.isApprovedForAll(address(this), address(lbRouter))) {
            lbPair.approveForAll(address(lbRouter), true);
        }

        (uint256 gotX, uint256 gotY) = lbRouter.removeLiquidity(
            tokenX,
            tokenY,
            BIN_STEP,
            _applySlippage(expectedX),
            _applySlippage(expectedY),
            ids,
            amounts,
            address(this),
            block.timestamp
        );

        // Update tracking
        for (uint256 i; i < nonZero; ) {
            uint24 binId = uint24(ids[i]);
            binLBAmounts[binId] -= amounts[i];
            unchecked { ++i; }
        }
        _cleanEmptyBins();

        if (assetIsTokenX && gotY > 0) {
            uint256 minXOut = _applySlippage(_quoteSwapYforX(_toUint128(gotY)));
            _swapYforX(gotY, minXOut);
        } else if (!assetIsTokenX && gotX > 0) {
            uint256 minYOut = _applySlippage(_quoteSwapXforY(_toUint128(gotX)));
            _swapXforY(gotX, minYOut);
        }
    }

    // =========================================================================
    // REBALANCING
    // =========================================================================

    /// @notice Called by keeper when active bin has drifted outside our range.
    ///         Pulls all LP, redeposits at the new active bin.
    function rebalance() external onlyRebalancer whenNotPaused nonReentrant {
        // Full withdrawal of all LP
        uint256 supply = totalSupply();
        if (supply > 0 && depositedBins.length > 0) {
            _withdrawFromLP(supply, supply); // proportion = 1
        }

        uint256 balance = _assetToken().balanceOf(address(this));
        if (balance > 1) {
            _deployToLP(balance);
        }

        emit Rebalanced(balance);
    }

    // =========================================================================
    // VALUATION — VIEW
    // =========================================================================

    /// @dev Compute vault's LP position value in ERC-4626 asset terms.
    ///      Uses a 1:1 stable peg assumption between pair tokens.
    ///      At 1:1 peg this is exact; a depeg will over/understate value.
    function _lpValueInAsset() internal view returns (uint256 totalAssets_) {
        uint256 len = depositedBins.length;
        for (uint256 i; i < len; ) {
            uint24 binId    = depositedBins[i];
            uint256 lbAmt   = binLBAmounts[binId];

            if (lbAmt > 0) {
                (uint128 resX, uint128 resY) = lbPair.getBin(binId);
                uint256 supply = lbPair.totalSupply(binId);

                if (supply > 0) {
                    uint256 shareX = (uint256(resX) * lbAmt) / supply;
                    uint256 shareY = (uint256(resY) * lbAmt) / supply;
                    totalAssets_ += _tokenLiquidationValueInAsset(shareX, true);
                    totalAssets_ += _tokenLiquidationValueInAsset(shareY, false);
                }
            }
            unchecked { ++i; }
        }
    }

    /// @dev Expected tokenX and tokenY from removing `amounts` from `ids`.
    ///      Used to set removeLiquidity min-amount floors.
    function _expectedWithdrawAmounts(
        uint256[] memory ids,
        uint256[] memory amounts
    ) internal view returns (uint256 expX, uint256 expY) {
        for (uint256 i; i < ids.length; ) {
            uint24 binId = uint24(ids[i]);
            uint256 lbAmt = amounts[i];
            uint256 supply = lbPair.totalSupply(binId);

            if (supply > 0) {
                (uint128 resX, uint128 resY) = lbPair.getBin(binId);
                expX += (uint256(resX) * lbAmt) / supply;
                expY += (uint256(resY) * lbAmt) / supply;
            }
            unchecked { ++i; }
        }
    }

    // =========================================================================
    // SWAP HELPERS
    // =========================================================================

    function _swapXforY(uint256 amountIn, uint256 minOut) internal returns (uint256 amountOut) {
        tokenX.forceApprove(address(lbRouter), amountIn);

        uint256[] memory pairBinSteps = new uint256[](1);
        ILBRouter.Version[] memory versions = new ILBRouter.Version[](1);
        IERC20[] memory tokenPath = new IERC20[](2);

        pairBinSteps[0] = BIN_STEP;
        versions[0]     = PAIR_VERSION;
        tokenPath[0]    = tokenX;
        tokenPath[1]    = tokenY;

        amountOut = lbRouter.swapExactTokensForTokens(
            amountIn,
            minOut,
            ILBRouter.Path({
                pairBinSteps: pairBinSteps,
                versions:     versions,
                tokenPath:    tokenPath
            }),
            address(this),
            block.timestamp
        );

        tokenX.forceApprove(address(lbRouter), 0);

        if (amountOut < minOut) {
            revert Vault__InsufficientOutputFromSwap(amountOut, minOut);
        }
    }

    function _swapYforX(uint256 amountIn, uint256 minOut) internal returns (uint256 amountOut) {
        tokenY.forceApprove(address(lbRouter), amountIn);

        uint256[] memory pairBinSteps = new uint256[](1);
        ILBRouter.Version[] memory versions = new ILBRouter.Version[](1);
        IERC20[] memory tokenPath = new IERC20[](2);

        pairBinSteps[0] = BIN_STEP;
        versions[0]     = PAIR_VERSION;
        tokenPath[0]    = tokenY;
        tokenPath[1]    = tokenX;

        amountOut = lbRouter.swapExactTokensForTokens(
            amountIn,
            minOut,
            ILBRouter.Path({
                pairBinSteps: pairBinSteps,
                versions:     versions,
                tokenPath:    tokenPath
            }),
            address(this),
            block.timestamp
        );

        tokenY.forceApprove(address(lbRouter), 0);

        if (amountOut < minOut) {
            revert Vault__InsufficientOutputFromSwap(amountOut, minOut);
        }
    }

    function _quoteSwapXforY(uint128 amountIn) internal view returns (uint256) {
        (, uint128 amountOut,) = lbRouter.getSwapOut(lbPair, amountIn, true); // true = swapForY
        return amountOut;
    }

    function _quoteSwapYforX(uint128 amountIn) internal view returns (uint256) {
        (, uint128 amountOut,) = lbRouter.getSwapOut(lbPair, amountIn, false); // false = swapForX
        return amountOut;
    }

    // =========================================================================
    // BIN DISTRIBUTION
    // =========================================================================

    /// @dev Build delta-id offsets and per-bin distributions for addLiquidity.
    ///
    ///      For a stable pair:
    ///        - Bins BELOW active: Y only  (distX=0, distY>0)
    ///        - Active bin:        split   (distX>0, distY>0)
    ///        - Bins ABOVE active: X only  (distX>0, distY=0)
    ///
    ///      Each distribution array must sum to EXACTLY 1e18.
    ///      We use integer division with remainder assigned to the last bin
    ///      to guarantee exact sum.
    function _buildDistribution()
        internal
        view
        returns (
            int256[]  memory deltaIds,
            uint256[] memory distX,
            uint256[] memory distY
        )
    {
        uint256 numBins = binRange * 2 + 1;
        deltaIds = new int256[](numBins);
        distX    = new uint256[](numBins);
        distY    = new uint256[](numBins);

        // How many bins receive X (active + bins above)
        uint256 xBinCount = binRange + 1;  // active + binRange above
        // How many bins receive Y (active + bins below)
        uint256 yBinCount = binRange + 1;  // active + binRange below

        uint256 perBinX = 1e18 / xBinCount;
        uint256 perBinY = 1e18 / yBinCount;

        uint256 remX = 1e18 - perBinX * xBinCount; // dust remainder
        uint256 remY = 1e18 - perBinY * yBinCount;

        uint256 xAssigned;
        uint256 yAssigned;

        for (uint256 i; i < numBins; ) {
            // casting to int256 is safe because binRange is capped at 10, so numBins is at most 21
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 delta = int256(i) - int256(binRange);
            deltaIds[i]  = delta;

            if (delta < 0) {
                // Below active: Y only
                bool isLast = (yAssigned == yBinCount - 1);
                distY[i] = isLast ? perBinY + remY : perBinY;
                unchecked { ++yAssigned; }
            } else if (delta == 0) {
                // Active bin: split between X and Y
                // X: this is the first X bin
                distX[i] = perBinX;
                unchecked { ++xAssigned; }
                // Y: this is the last Y bin
                distY[i] = perBinY + remY;
                unchecked { ++yAssigned; }
            } else {
                // Above active: X only
                bool isLast = (xAssigned == xBinCount - 1);
                distX[i] = isLast ? perBinX + remX : perBinX;
                unchecked { ++xAssigned; }
            }

            unchecked { ++i; }
        }
    }

    // =========================================================================
    // UTILITY
    // =========================================================================

    function _applySlippage(uint256 amount) internal view returns (uint256) {
        return (amount * (10_000 - slippageBps)) / 10_000;
    }

    function _assetToken() internal view returns (IERC20) {
        return IERC20(asset());
    }

    function _idleValueInAsset() internal view returns (uint256) {
        return _tokenLiquidationValueInAsset(tokenX.balanceOf(address(this)), true)
            + _tokenLiquidationValueInAsset(tokenY.balanceOf(address(this)), false);
    }

    function _tokenValueInAsset(uint256 amount, bool isTokenX_) internal view returns (uint256) {
        uint8 tokenDecimals = isTokenX_ ? TOKEN_X_DECIMALS : TOKEN_Y_DECIMALS;
        if (tokenDecimals == ASSET_DECIMALS) return amount;
        if (tokenDecimals > ASSET_DECIMALS) return amount / (10 ** (tokenDecimals - ASSET_DECIMALS));
        return amount * (10 ** (ASSET_DECIMALS - tokenDecimals));
    }

    function _tokenLiquidationValueInAsset(uint256 amount, bool isTokenX_) internal view returns (uint256) {
        uint256 normalized = _tokenValueInAsset(amount, isTokenX_);
        bool isAsset = isTokenX_ == assetIsTokenX;
        return isAsset ? normalized : _applySlippage(normalized);
    }

    function _toUint128(uint256 amount) internal pure returns (uint128) {
        if (amount > type(uint128).max) revert Vault__AmountTooLargeForQuote(amount);
        // casting to uint128 is safe because the bound is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(amount);
    }

    /// @dev Remove bins with zero LB-token balance from the tracked array
    function _cleanEmptyBins() internal {
        uint256 writeIdx;
        uint256 len = depositedBins.length;
        for (uint256 i; i < len; ) {
            uint24 binId = depositedBins[i];
            if (binLBAmounts[binId] > 0) {
                if (writeIdx != i) depositedBins[writeIdx] = binId;
                unchecked { ++writeIdx; }
            }
            unchecked { ++i; }
        }
        while (depositedBins.length > writeIdx) depositedBins.pop();
    }

    // =========================================================================
    // EMERGENCY / ADMIN
    // =========================================================================

    /// @notice Pull all LP and leave tokens idle in the vault (no swap back).
    ///         Use after pausing to safely halt the strategy.
    function emergencyWithdrawLP() external onlyOwner {
        _pause();

        uint256 len = depositedBins.length;
        if (len == 0) return;

        uint256[] memory ids     = new uint256[](len);
        uint256[] memory amounts = new uint256[](len);

        for (uint256 i; i < len; ) {
            uint24 binId = depositedBins[i];
            ids[i]     = binId;
            amounts[i] = binLBAmounts[binId];
            binLBAmounts[binId] = 0;
            unchecked { ++i; }
        }
        delete depositedBins;

        if (!lbPair.isApprovedForAll(address(this), address(lbRouter))) {
            lbPair.approveForAll(address(lbRouter), true);
        }

        (uint256 gotX, uint256 gotY) = lbRouter.removeLiquidity(
            tokenX,
            tokenY,
            BIN_STEP,
            0,   // no min — emergency mode
            0,
            ids,
            amounts,
            address(this),
            block.timestamp
        );

        emit EmergencyWithdrawn(gotX, gotY);
    }

    /// @notice Recover any tokens accidentally sent to this contract.
    ///         Cannot sweep tokenX (asset) or tokenY (pair token) to protect users.
    function sweep(IERC20 token, address to, uint256 amount) external onlyOwner {
        require(address(token) != address(tokenX) && address(token) != address(tokenY), "cannot sweep vault tokens");
        token.safeTransfer(to, amount);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setRebalancer(address _r) external onlyOwner {
        rebalancer = _r;
        emit RebalancerUpdated(_r);
    }

    function setBinRange(uint256 _r) external onlyOwner {
        _setBinRange(_r);
    }

    /// @param _bps Max 200 (2%) — revert if caller tries to set looser
    function setSlippage(uint256 _bps) external onlyOwner {
        _setSlippage(_bps);
    }

    function setDepositCap(uint256 _cap) external onlyOwner {
        _setDepositCap(_cap);
    }

    function _setBinRange(uint256 _r) internal {
        require(_r >= 1 && _r <= 10, "range 1-10");
        binRange = _r;
        emit BinRangeUpdated(_r);
    }

    function _setSlippage(uint256 _bps) internal {
        if (_bps > 200) revert Vault__SlippageTooHigh(_bps);
        slippageBps = _bps;
        emit SlippageUpdated(_bps);
    }

    function _setDepositCap(uint256 _cap) internal {
        depositCap = _cap;
        emit DepositCapUpdated(_cap);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    function getDepositedBins() external view returns (uint24[] memory) {
        return depositedBins;
    }

    function getBinPosition(uint24 binId) external view returns (uint256 lbAmount) {
        return binLBAmounts[binId];
    }

    /// @notice Check whether active bin has drifted outside our deposited range.
    ///         Keepers can use this to decide whether to call rebalance().
    function needsRebalance() external view returns (bool) {
        if (depositedBins.length == 0) return false;
        uint24 active = lbPair.getActiveId();
        uint24 lo = depositedBins[0];
        uint24 hi = depositedBins[depositedBins.length - 1];
        return active < lo || active > hi;
    }

    uint256[50] private __gap;
}
