// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {ILBRouter} from "./interfaces/ILBRouter.sol";
import {ILBPair} from "./interfaces/ILBPair.sol";
import {IStableVaultOracle} from "./interfaces/IStableVaultOracle.sol";

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
contract LFJStableVault is
    Initializable,
    ERC4626Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    bytes32 private constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // ─── Errors ──────────────────────────────────────────────────────────────
    error Vault__NotRebalancer();
    error Vault__DepositCapExceeded(uint256 cap, uint256 total);
    error Vault__ZeroAmount();
    error Vault__SlippageTooHigh(uint256 bps);
    error Vault__TokenOrderViolation();
    error Vault__InvalidAsset();
    error Vault__AmountTooLargeForQuote(uint256 amount);
    error Vault__InsufficientOutputFromSwap(uint256 got, uint256 min);
    error Vault__ZeroShares();
    error Vault__OracleNotConfigured();
    error Vault__InvalidOracle(address oracle);
    error Vault__UnsafeSwapQuote(uint256 routerMinimum, uint256 oracleMinimum);
    error Vault__ValuationHaircutTooHigh(uint256 bps);
    error Vault__ValuationHaircutBelowSlippage(uint256 haircutBps, uint256 slippageBps);
    error Vault__ExceedsUnaccountedPaired(uint256 requested, uint256 available);
    error Vault__NotOwnerOrProxyAdmin(address caller);

    // ─── Events ──────────────────────────────────────────────────────────────
    event Rebalanced(uint256 assetsRedeployed);
    event BinRangeUpdated(uint256 newRange);
    event SlippageUpdated(uint256 newBps);
    event DepositCapUpdated(uint256 newCap);
    event RebalancerUpdated(address newRebalancer);
    event EmergencyWithdrawn(uint256 amountX, uint256 amountY);
    event OracleConfigured(address indexed oracle, uint256 valuationHaircutBps);
    event ValuationHaircutUpdated(uint256 newBps);
    event PairedDonationAccepted(uint256 amount);
    event UnaccountedPairedSwept(address indexed to, uint256 amount);

    // ─── Strategy Configuration ──────────────────────────────────────────────

    ILBRouter public lbRouter;
    ILBPair public lbPair;

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

    /// @notice Independent asset/paired-token oracle added in implementation v2.
    IStableVaultOracle public priceOracle;

    /// @notice Conservative haircut applied to paired-token oracle value.
    uint16 public valuationHaircutBps;

    /// @notice Idle paired tokens produced by strategy operations and included
    ///         in share value. Unsolicited paired-token transfers are excluded.
    uint256 public accountedIdlePaired;

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
        _initializeBase(
            _asset,
            _tokenX,
            _tokenY,
            _lbRouter,
            _lbPair,
            _version,
            _rebalancer,
            _owner,
            _depositCap,
            _binRange,
            _slippageBps
        );
    }

    /// @notice Initialize a new proxy with independent oracle protection.
    /// @dev Uses version 1 so a legacy proxy that already ran initialize()
    ///      cannot race this entry point after a non-atomic implementation
    ///      upgrade. Legacy proxies must use the authenticated initializeV2().
    function initializeWithOracle(
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
        uint256 _slippageBps,
        IStableVaultOracle _priceOracle,
        uint256 _valuationHaircutBps
    ) external initializer {
        _initializeBase(
            _asset,
            _tokenX,
            _tokenY,
            _lbRouter,
            _lbPair,
            _version,
            _rebalancer,
            _owner,
            _depositCap,
            _binRange,
            _slippageBps
        );
        _configureOracle(_priceOracle, _valuationHaircutBps);
    }

    /// @notice Complete a v1-to-v2 proxy upgrade before reopening deposits.
    /// @dev Governance explicitly selects how much existing idle paired balance
    ///      is strategy backing so a donation cannot front-run the migration.
    function initializeV2(IStableVaultOracle _priceOracle, uint256 _valuationHaircutBps, uint256 _accountedPaired)
        external
        reinitializer(2)
        onlyOwnerOrProxyAdmin
    {
        _configureOracle(_priceOracle, _valuationHaircutBps);
        uint256 balance = _pairedToken().balanceOf(address(this));
        if (_accountedPaired > balance) {
            revert Vault__ExceedsUnaccountedPaired(_accountedPaired, balance);
        }
        accountedIdlePaired = _accountedPaired;
    }

    function _initializeBase(
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
    ) private {
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

        lbRouter = _lbRouter;
        lbPair = _lbPair;
        tokenX = _tokenX;
        tokenY = _tokenY;
        assetIsTokenX = address(_asset) == address(_tokenX);
        BIN_STEP = _lbPair.getBinStep();
        PAIR_VERSION = _version;
        rebalancer = _rebalancer;

        TOKEN_X_DECIMALS = IERC20Metadata(address(_tokenX)).decimals();
        TOKEN_Y_DECIMALS = IERC20Metadata(address(_tokenY)).decimals();
        ASSET_DECIMALS = IERC20Metadata(address(_asset)).decimals();

        _setDepositCap(_depositCap);
        _setBinRange(_binRange);
        _setSlippage(_slippageBps);
    }

    function _configureOracle(IStableVaultOracle _priceOracle, uint256 _valuationHaircutBps) private {
        if (
            address(_priceOracle) == address(0) || _priceOracle.asset() != asset()
                || _priceOracle.pairedToken() != address(_pairedToken())
        ) revert Vault__InvalidOracle(address(_priceOracle));
        if (_valuationHaircutBps > 2_000) revert Vault__ValuationHaircutTooHigh(_valuationHaircutBps);
        if (_valuationHaircutBps < slippageBps) {
            revert Vault__ValuationHaircutBelowSlippage(_valuationHaircutBps, slippageBps);
        }

        priceOracle = _priceOracle;
        // Bound is checked above, so the cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        valuationHaircutBps = uint16(_valuationHaircutBps);
        emit OracleConfigured(address(_priceOracle), _valuationHaircutBps);
    }

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyRebalancer() {
        if (msg.sender != rebalancer && msg.sender != owner()) revert Vault__NotRebalancer();
        _;
    }

    /// @dev Transparent proxies execute upgradeAndCall initializer calldata
    ///      with their stored ProxyAdmin as msg.sender. That contract is itself
    ///      owned by governance, and cannot use the proxy fallback outside the
    ///      atomic upgrade entry point.
    modifier onlyOwnerOrProxyAdmin() {
        address proxyAdmin = StorageSlot.getAddressSlot(ERC1967_ADMIN_SLOT).value;
        if (msg.sender != owner() && msg.sender != proxyAdmin) {
            revert Vault__NotOwnerOrProxyAdmin(msg.sender);
        }
        _;
    }

    // =========================================================================
    // ERC-4626 OVERRIDES
    // =========================================================================

    /// @notice Total asset value managed by the vault (idle + LP value)
    function totalAssets() public view override returns (uint256) {
        _requireOracle();
        return _idleValueInAsset() + _lpValueInAsset();
    }

    /// @notice Max deposit enforces the deposit cap
    function maxDeposit(address) public view override returns (uint256) {
        if (address(priceOracle) == address(0)) return 0;
        if (depositCap == 0) return type(uint256).max;
        uint256 ta = totalAssets();
        if (ta >= depositCap) return 0;
        return depositCap - ta;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        if (address(priceOracle) == address(0)) return 0;
        return convertToShares(maxDeposit(receiver));
    }

    /// @dev Conservative previews deliberately haircut paired-token value. On
    ///      the final redemption, pay and return the complete realized asset
    ///      balance so the haircut surplus cannot become ownerless.
    function redeem(uint256 shares, address receiver, address owner_) public override returns (uint256 assets) {
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

    /// @dev Preserve exact-asset withdrawal semantics when conservative share
    ///      pricing would otherwise burn the final share. Realize the strategy,
    ///      then recompute the shares against the actual asset balance so any
    ///      execution surplus remains claimable by the remaining shares.
    function withdraw(uint256 assets, address receiver, address owner_) public override returns (uint256 shares) {
        uint256 maxAssets = maxWithdraw(owner_);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner_, assets, maxAssets);
        }

        shares = previewWithdraw(assets);
        uint256 supply = totalSupply();
        if (shares > 0 && shares == supply) {
            return _withdrawExactAfterFullLiquidation(_msgSender(), receiver, owner_, assets, supply);
        }

        _withdraw(_msgSender(), receiver, owner_, assets, shares);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
        whenNotPaused
    {
        _requireOracle();
        if (assets == 0) revert Vault__ZeroAmount();
        if (shares == 0) revert Vault__ZeroShares();
        if (depositCap > 0 && totalAssets() + assets > depositCap) {
            revert Vault__DepositCapExceeded(depositCap, totalAssets() + assets);
        }

        super._deposit(caller, receiver, assets, shares);
        _deployToLP(_assetToken().balanceOf(address(this)));
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        _requireOracle();
        uint256 supply = totalSupply();
        _liquidateWithdrawal(shares, supply);
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    function _redeemAll(address caller, address receiver, address owner_, uint256 shares, uint256 supply)
        internal
        nonReentrant
        returns (uint256 assets)
    {
        _requireOracle();
        _liquidateWithdrawal(shares, supply);
        assets = _assetToken().balanceOf(address(this));
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    function _withdrawExactAfterFullLiquidation(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 supply
    ) internal nonReentrant returns (uint256 shares) {
        _requireOracle();
        _liquidateWithdrawal(supply, supply);
        shares = previewWithdraw(assets);
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    function _liquidateWithdrawal(uint256 shares, uint256 supply) internal {
        if (supply == 0 || shares == 0) return;

        uint256 idlePaired = _accountedIdlePairedBalance();
        uint256 pairedFromLP;
        if (depositedBins.length > 0) pairedFromLP = _withdrawFromLP(shares, supply);

        // Combine the holder's pre-existing idle balance with the paired token
        // removed from LP. One swap realizes every paired-token component
        // counted for this redemption without consuming unsolicited donations.
        uint256 idlePairedToSwap = shares == supply ? idlePaired : Math.mulDiv(idlePaired, shares, supply);
        if (shares == supply) {
            // Clear stale accounting as well as the realizable balance. This
            // keeps any future unsolicited transfer unaccounted after a final
            // exit even if the paired token ever experienced a balance shortfall.
            accountedIdlePaired = 0;
        } else if (idlePairedToSwap > 0) {
            accountedIdlePaired -= idlePairedToSwap;
        }
        _liquidatePaired(idlePairedToSwap + pairedFromLP);
    }

    // =========================================================================
    // LP MANAGEMENT — INTERNAL
    // =========================================================================

    /// @dev Deploy `assetAmount` into the LB pair.
    ///      Swaps half of the asset into the paired side, then calls addLiquidity.
    function _deployToLP(uint256 assetAmount) internal {
        if (assetAmount < 2) return; // dust guard

        IERC20 paired = _pairedToken();
        uint256 pairedBefore = paired.balanceOf(address(this));

        uint256 amountX;
        uint256 amountY;

        if (assetIsTokenX) {
            uint256 halfX = assetAmount / 2;
            uint256 remainingX = assetAmount - halfX; // handles odd wei

            amountX = remainingX;
            amountY = _swapXforY(halfX, _applySlippage(_quoteSwapXforY(_toUint128(halfX))));
        } else {
            uint256 halfY = assetAmount / 2;
            uint256 remainingY = assetAmount - halfY;

            amountX = _swapYforX(halfY, _applySlippage(_quoteSwapYforX(_toUint128(halfY))));
            amountY = remainingY;
        }

        // ── 2. Build bin distribution around active bin ──────────────────────
        uint24 activeBin = lbPair.getActiveId();

        (int256[] memory deltaIds, uint256[] memory distX, uint256[] memory distY) = _buildDistribution();

        // ── 3. Approve router ────────────────────────────────────────────────
        tokenX.forceApprove(address(lbRouter), amountX);
        tokenY.forceApprove(address(lbRouter), amountY);

        // ── 4. Add liquidity ─────────────────────────────────────────────────
        ILBRouter.LiquidityParameters memory params = ILBRouter.LiquidityParameters({
            tokenX: tokenX,
            tokenY: tokenY,
            binStep: BIN_STEP,
            amountX: amountX,
            amountY: amountY,
            amountXMin: _applySlippage(amountX),
            amountYMin: _applySlippage(amountY),
            activeIdDesired: activeBin,
            idSlippage: binRange + 1, // extra tolerance for block latency
            deltaIds: deltaIds,
            distributionX: distX,
            distributionY: distY,
            to: address(this),
            refundTo: address(this),
            deadline: block.timestamp
        });

        (,,,, uint256[] memory depositIds, uint256[] memory liquidityMinted) = lbRouter.addLiquidity(params);

        // ── 5. Track bin positions ───────────────────────────────────────────
        for (uint256 i; i < depositIds.length;) {
            uint24 binId = uint24(depositIds[i]);
            if (binLBAmounts[binId] == 0) {
                depositedBins.push(binId);
            }
            binLBAmounts[binId] += liquidityMinted[i];
            unchecked {
                ++i;
            }
        }

        // ── 6. Clear allowances ──────────────────────────────────────────────
        tokenX.forceApprove(address(lbRouter), 0);
        tokenY.forceApprove(address(lbRouter), 0);

        // Only strategy-created refunds become share backing. Any paired token
        // already present before this deployment remains an unsolicited balance.
        uint256 pairedAfter = paired.balanceOf(address(this));
        if (pairedAfter > pairedBefore) accountedIdlePaired += pairedAfter - pairedBefore;
    }

    /// @dev Withdraw `shares/totalShares` proportion of every bin and return
    ///      the non-asset amount. The caller performs the combined liquidation.
    function _withdrawFromLP(uint256 shares, uint256 totalShares) internal returns (uint256 pairedReceived) {
        uint256 len = depositedBins.length;
        if (len == 0) return 0;

        uint256[] memory ids = new uint256[](len);
        uint256[] memory amounts = new uint256[](len);

        uint256 nonZero;
        for (uint256 i; i < len;) {
            uint24 binId = depositedBins[i];
            uint256 total = binLBAmounts[binId];
            uint256 toRemove = shares == totalShares ? total : Math.mulDiv(total, shares, totalShares);

            if (toRemove > 0) {
                ids[nonZero] = binId;
                amounts[nonZero] = toRemove;
                unchecked {
                    ++nonZero;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (nonZero == 0) return 0;

        // Trim arrays to actual non-zero count
        assembly {
            mstore(ids, nonZero)
            mstore(amounts, nonZero)
        }

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
        for (uint256 i; i < nonZero;) {
            uint24 binId = uint24(ids[i]);
            binLBAmounts[binId] -= amounts[i];
            unchecked {
                ++i;
            }
        }
        _cleanEmptyBins();

        pairedReceived = assetIsTokenX ? gotY : gotX;
    }

    // =========================================================================
    // REBALANCING
    // =========================================================================

    /// @notice Called by keeper when active bin has drifted outside our range.
    ///         Pulls all LP, redeposits at the new active bin.
    function rebalance() external onlyRebalancer whenNotPaused nonReentrant {
        _requireOracle();
        // Full withdrawal of all LP
        uint256 supply = totalSupply();
        uint256 accountedPaired = _accountedIdlePairedBalance();
        uint256 pairedFromLP;
        if (supply > 0 && depositedBins.length > 0) {
            pairedFromLP = _withdrawFromLP(supply, supply); // proportion = 1
        }

        // _withdrawFromLP leaves its paired output idle, so this single swap
        // combines LP proceeds with strategy-accounted prior refunds. Direct
        // paired-token donations remain excluded until governance accepts them.
        if (accountedPaired > 0) accountedIdlePaired -= accountedPaired;
        _liquidatePaired(accountedPaired + pairedFromLP);

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
    ///      The paired component uses the independent oracle and haircut.
    function _lpValueInAsset() internal view returns (uint256 totalAssets_) {
        uint256 len = depositedBins.length;
        for (uint256 i; i < len;) {
            uint24 binId = depositedBins[i];
            uint256 lbAmt = binLBAmounts[binId];

            if (lbAmt > 0) {
                (uint128 resX, uint128 resY) = lbPair.getBin(binId);
                uint256 supply = lbPair.totalSupply(binId);

                if (supply > 0) {
                    uint256 shareX = Math.mulDiv(uint256(resX), lbAmt, supply);
                    uint256 shareY = Math.mulDiv(uint256(resY), lbAmt, supply);
                    totalAssets_ += _tokenLiquidationValueInAsset(shareX, true);
                    totalAssets_ += _tokenLiquidationValueInAsset(shareY, false);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Expected tokenX and tokenY from removing `amounts` from `ids`.
    ///      Used to set removeLiquidity min-amount floors.
    function _expectedWithdrawAmounts(uint256[] memory ids, uint256[] memory amounts)
        internal
        view
        returns (uint256 expX, uint256 expY)
    {
        for (uint256 i; i < ids.length;) {
            uint24 binId = uint24(ids[i]);
            uint256 lbAmt = amounts[i];
            uint256 supply = lbPair.totalSupply(binId);

            if (supply > 0) {
                (uint128 resX, uint128 resY) = lbPair.getBin(binId);
                expX += Math.mulDiv(uint256(resX), lbAmt, supply);
                expY += Math.mulDiv(uint256(resY), lbAmt, supply);
            }
            unchecked {
                ++i;
            }
        }
    }

    // =========================================================================
    // SWAP HELPERS
    // =========================================================================

    function _swapXforY(uint256 amountIn, uint256 minOut) internal returns (uint256 amountOut) {
        uint256 oracleMinimum = assetIsTokenX
            ? _applyValuationHaircut(priceOracle.quoteAssetToPair(amountIn))
            : _pairedLiquidationValue(amountIn);
        if (minOut < oracleMinimum) revert Vault__UnsafeSwapQuote(minOut, oracleMinimum);

        tokenX.forceApprove(address(lbRouter), amountIn);

        uint256[] memory pairBinSteps = new uint256[](1);
        ILBRouter.Version[] memory versions = new ILBRouter.Version[](1);
        IERC20[] memory tokenPath = new IERC20[](2);

        pairBinSteps[0] = BIN_STEP;
        versions[0] = PAIR_VERSION;
        tokenPath[0] = tokenX;
        tokenPath[1] = tokenY;

        amountOut = lbRouter.swapExactTokensForTokens(
            amountIn,
            minOut,
            ILBRouter.Path({pairBinSteps: pairBinSteps, versions: versions, tokenPath: tokenPath}),
            address(this),
            block.timestamp
        );

        tokenX.forceApprove(address(lbRouter), 0);

        if (amountOut < minOut) {
            revert Vault__InsufficientOutputFromSwap(amountOut, minOut);
        }
    }

    function _swapYforX(uint256 amountIn, uint256 minOut) internal returns (uint256 amountOut) {
        uint256 oracleMinimum = assetIsTokenX
            ? _pairedLiquidationValue(amountIn)
            : _applyValuationHaircut(priceOracle.quoteAssetToPair(amountIn));
        if (minOut < oracleMinimum) revert Vault__UnsafeSwapQuote(minOut, oracleMinimum);

        tokenY.forceApprove(address(lbRouter), amountIn);

        uint256[] memory pairBinSteps = new uint256[](1);
        ILBRouter.Version[] memory versions = new ILBRouter.Version[](1);
        IERC20[] memory tokenPath = new IERC20[](2);

        pairBinSteps[0] = BIN_STEP;
        versions[0] = PAIR_VERSION;
        tokenPath[0] = tokenY;
        tokenPath[1] = tokenX;

        amountOut = lbRouter.swapExactTokensForTokens(
            amountIn,
            minOut,
            ILBRouter.Path({pairBinSteps: pairBinSteps, versions: versions, tokenPath: tokenPath}),
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
        returns (int256[] memory deltaIds, uint256[] memory distX, uint256[] memory distY)
    {
        uint256 numBins = binRange * 2 + 1;
        deltaIds = new int256[](numBins);
        distX = new uint256[](numBins);
        distY = new uint256[](numBins);

        // How many bins receive X (active + bins above)
        uint256 xBinCount = binRange + 1; // active + binRange above
        // How many bins receive Y (active + bins below)
        uint256 yBinCount = binRange + 1; // active + binRange below

        uint256 perBinX = 1e18 / xBinCount;
        uint256 perBinY = 1e18 / yBinCount;

        uint256 remX = 1e18 - perBinX * xBinCount; // dust remainder
        uint256 remY = 1e18 - perBinY * yBinCount;

        uint256 xAssigned;
        uint256 yAssigned;

        for (uint256 i; i < numBins;) {
            // casting to int256 is safe because binRange is capped at 10, so numBins is at most 21
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 delta = int256(i) - int256(binRange);
            deltaIds[i] = delta;

            if (delta < 0) {
                // Below active: Y only
                bool isLast = (yAssigned == yBinCount - 1);
                distY[i] = isLast ? perBinY + remY : perBinY;
                unchecked {
                    ++yAssigned;
                }
            } else if (delta == 0) {
                // Active bin: split between X and Y
                // X: this is the first X bin
                distX[i] = perBinX;
                unchecked {
                    ++xAssigned;
                }
                // Y: this is the last Y bin
                distY[i] = perBinY + remY;
                unchecked {
                    ++yAssigned;
                }
            } else {
                // Above active: X only
                bool isLast = (xAssigned == xBinCount - 1);
                distX[i] = isLast ? perBinX + remX : perBinX;
                unchecked {
                    ++xAssigned;
                }
            }

            unchecked {
                ++i;
            }
        }
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

    function _assetToken() internal view returns (IERC20) {
        return IERC20(asset());
    }

    function _pairedToken() internal view returns (IERC20) {
        return assetIsTokenX ? tokenY : tokenX;
    }

    function _liquidatePaired(uint256 amount) internal {
        if (amount == 0) return;
        if (assetIsTokenX) {
            uint256 minXOut = _applySlippage(_quoteSwapYforX(_toUint128(amount)));
            _swapYforX(amount, minXOut);
        } else {
            uint256 minYOut = _applySlippage(_quoteSwapXforY(_toUint128(amount)));
            _swapXforY(amount, minYOut);
        }
    }

    function _idleValueInAsset() internal view returns (uint256) {
        return _assetToken().balanceOf(address(this)) + _pairedLiquidationValue(_accountedIdlePairedBalance());
    }

    function _tokenLiquidationValueInAsset(uint256 amount, bool isTokenX_) internal view returns (uint256) {
        bool isAsset = isTokenX_ == assetIsTokenX;
        return isAsset ? amount : _pairedLiquidationValue(amount);
    }

    function _pairedLiquidationValue(uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        return _applyValuationHaircut(priceOracle.quotePairToAsset(amount));
    }

    function _accountedIdlePairedBalance() internal view returns (uint256) {
        uint256 balance = _pairedToken().balanceOf(address(this));
        return accountedIdlePaired < balance ? accountedIdlePaired : balance;
    }

    function _unaccountedPairedBalance() internal view returns (uint256) {
        uint256 balance = _pairedToken().balanceOf(address(this));
        uint256 accounted = _accountedIdlePairedBalance();
        return balance - accounted;
    }

    function _requireOracle() internal view {
        if (address(priceOracle) == address(0)) revert Vault__OracleNotConfigured();
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
        for (uint256 i; i < len;) {
            uint24 binId = depositedBins[i];
            if (binLBAmounts[binId] > 0) {
                if (writeIdx != i) depositedBins[writeIdx] = binId;
                unchecked {
                    ++writeIdx;
                }
            }
            unchecked {
                ++i;
            }
        }
        while (depositedBins.length > writeIdx) depositedBins.pop();
    }

    // =========================================================================
    // EMERGENCY / ADMIN
    // =========================================================================

    /// @notice Pull all LP and leave tokens idle in the vault (no swap back).
    ///         Use after pausing to safely halt the strategy.
    function emergencyWithdrawLP() external onlyOwner {
        if (!paused()) _pause();

        uint256 len = depositedBins.length;
        if (len == 0) return;

        uint256[] memory ids = new uint256[](len);
        uint256[] memory amounts = new uint256[](len);

        for (uint256 i; i < len;) {
            uint24 binId = depositedBins[i];
            ids[i] = binId;
            amounts[i] = binLBAmounts[binId];
            binLBAmounts[binId] = 0;
            unchecked {
                ++i;
            }
        }
        delete depositedBins;

        if (!lbPair.isApprovedForAll(address(this), address(lbRouter))) {
            lbPair.approveForAll(address(lbRouter), true);
        }

        (uint256 gotX, uint256 gotY) = lbRouter.removeLiquidity(
            tokenX,
            tokenY,
            BIN_STEP,
            0, // no min — emergency mode
            0,
            ids,
            amounts,
            address(this),
            block.timestamp
        );

        accountedIdlePaired += assetIsTokenX ? gotY : gotX;

        emit EmergencyWithdrawn(gotX, gotY);
    }

    /// @notice Recover any tokens accidentally sent to this contract.
    ///         Cannot sweep tokenX (asset) or tokenY (pair token) to protect users.
    function sweep(IERC20 token, address to, uint256 amount) external onlyOwner {
        require(address(token) != address(tokenX) && address(token) != address(tokenY), "cannot sweep vault tokens");
        token.safeTransfer(to, amount);
    }

    /// @notice Intentionally include an unsolicited paired-token transfer in
    ///         share accounting. Passing zero accepts the complete excess.
    function acceptPairedDonation(uint256 amount) external onlyOwner {
        uint256 available = _unaccountedPairedBalance();
        if (amount == 0) amount = available;
        if (amount > available) revert Vault__ExceedsUnaccountedPaired(amount, available);
        accountedIdlePaired += amount;
        emit PairedDonationAccepted(amount);
    }

    /// @notice Recover only paired tokens that have never been included in NAV.
    ///         Passing zero sweeps the complete unaccounted excess.
    function sweepUnaccountedPaired(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero recipient");
        uint256 available = _unaccountedPairedBalance();
        if (amount == 0) amount = available;
        if (amount > available) revert Vault__ExceedsUnaccountedPaired(amount, available);
        _pairedToken().safeTransfer(to, amount);
        emit UnaccountedPairedSwept(to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

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

    function setValuationHaircut(uint256 _bps) external onlyOwner {
        if (_bps > 2_000) revert Vault__ValuationHaircutTooHigh(_bps);
        if (_bps < slippageBps) revert Vault__ValuationHaircutBelowSlippage(_bps, slippageBps);
        // Bound is checked above, so the cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        valuationHaircutBps = uint16(_bps);
        emit ValuationHaircutUpdated(_bps);
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
        if (valuationHaircutBps != 0 && _bps > valuationHaircutBps) {
            revert Vault__ValuationHaircutBelowSlippage(valuationHaircutBps, _bps);
        }
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

    function unaccountedPairedBalance() external view returns (uint256) {
        return _unaccountedPairedBalance();
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

    uint256[48] private __gap;
}
