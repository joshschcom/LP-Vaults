// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {IPeridotPriceOracle, PeridotPharaohShareOracle} from "../contracts/oracles/PeridotPharaohShareOracle.sol";

contract MockPeridotBaseOracle is IPeridotPriceOracle {
    mapping(address => uint256) public prices;

    function setPrice(address pToken, uint256 price) external {
        prices[pToken] = price;
    }

    function getUnderlyingPrice(address pToken) external view returns (uint256) {
        return prices[pToken];
    }
}

contract MockPeridotMarket {
    address public immutable underlying;

    constructor(address underlying_) {
        underlying = underlying_;
    }
}

contract MockOracleToken {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

contract MockOracleVault {
    address public immutable asset;
    uint8 public immutable decimals;
    uint256 public assetsPerWholeShare;
    bool public shouldRevert;

    constructor(address asset_, uint8 decimals_, uint256 assetsPerWholeShare_) {
        asset = asset_;
        decimals = decimals_;
        assetsPerWholeShare = assetsPerWholeShare_;
    }

    function setAssetsPerWholeShare(uint256 value) external {
        assetsPerWholeShare = value;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (shouldRevert) revert("unsafe vault price");
        return Math.mulDiv(shares, assetsPerWholeShare, 10 ** decimals);
    }
}

contract MockOracleFeed is AggregatorV3Interface {
    uint8 public immutable override decimals;
    int256 public answer;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;
    uint256 public updatedAt;
    bool public shouldRevert;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setRound(int256 answer_, uint256 updatedAt_, uint80 roundId_, uint80 answeredInRound_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        roundId = roundId_;
        answeredInRound = answeredInRound_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function description() external pure returns (string memory) {
        return "MOCK / USD";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("not implemented");
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (shouldRevert) revert("feed unavailable");
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

    contract PeridotPharaohShareOracleTest is Test {
        MockPeridotBaseOracle private baseOracle;
        PeridotPharaohShareOracle private oracle;

        function setUp() public {
            vm.warp(10 days);
            baseOracle = new MockPeridotBaseOracle();
            oracle = new PeridotPharaohShareOracle(address(this), baseOracle);
        }

        function test_usdcShareUsesCompoundDecimalScaling() public {
            MockOracleToken asset = new MockOracleToken(6);
            MockOracleVault vault = new MockOracleVault(address(asset), 6, 1_010_000);
            MockOracleFeed feed = new MockOracleFeed(8, 99_900_000);
            MockPeridotMarket market = new MockPeridotMarket(address(vault));

            oracle.registerVault(IERC4626(address(vault)), feed, 1 hours);

            uint256 wholeShareUsd18 = Math.mulDiv(1_010_000, 999e15, 1e6);
            assertEq(oracle.getShareUsdPrice(address(vault)), wholeShareUsd18);
            assertEq(oracle.getUnderlyingPrice(address(market)), wholeShareUsd18 * 1e12);
        }

        function test_wavaxShareUsesEighteenDecimalScaling() public {
            MockOracleToken asset = new MockOracleToken(18);
            MockOracleVault vault = new MockOracleVault(address(asset), 18, 1.02 ether);
            MockOracleFeed feed = new MockOracleFeed(8, 30e8);
            MockPeridotMarket market = new MockPeridotMarket(address(vault));

            oracle.registerVault(IERC4626(address(vault)), feed, 1 hours);

            assertEq(oracle.getShareUsdPrice(address(vault)), 30.6 ether);
            assertEq(oracle.getUnderlyingPrice(address(market)), 30.6 ether);
        }

        function test_unknownMarketDelegatesToBaseOracle() public {
            MockPeridotMarket market = new MockPeridotMarket(address(0xBEEF));
            baseOracle.setPrice(address(market), 123e18);
            assertEq(oracle.getUnderlyingPrice(address(market)), 123e18);
        }

        function test_staleFeedFailsClosed() public {
            (MockOracleVault vault, MockOracleFeed feed, MockPeridotMarket market) = _registeredVault();
            feed.setRound(1e8, block.timestamp - 2 hours, 2, 2);

            assertEq(oracle.getShareUsdPrice(address(vault)), 0);
            assertEq(oracle.getUnderlyingPrice(address(market)), 0);
        }

        function test_invalidRoundFailsClosed() public {
            (MockOracleVault vault, MockOracleFeed feed, MockPeridotMarket market) = _registeredVault();
            feed.setRound(1e8, block.timestamp, 2, 1);

            assertEq(oracle.getShareUsdPrice(address(vault)), 0);
            assertEq(oracle.getUnderlyingPrice(address(market)), 0);
        }

        function test_feedRevertFailsClosed() public {
            (MockOracleVault vault, MockOracleFeed feed, MockPeridotMarket market) = _registeredVault();
            feed.setShouldRevert(true);

            assertEq(oracle.getShareUsdPrice(address(vault)), 0);
            assertEq(oracle.getUnderlyingPrice(address(market)), 0);
        }

        function test_vaultPriceRevertFailsClosed() public {
            (MockOracleVault vault,, MockPeridotMarket market) = _registeredVault();
            vault.setShouldRevert(true);

            assertEq(oracle.getShareUsdPrice(address(vault)), 0);
            assertEq(oracle.getUnderlyingPrice(address(market)), 0);
        }

        function test_onlyOwnerCanRegisterOrRemove() public {
            MockOracleToken asset = new MockOracleToken(6);
            MockOracleVault vault = new MockOracleVault(address(asset), 6, 1e6);
            MockOracleFeed feed = new MockOracleFeed(8, 1e8);

            vm.startPrank(address(0xBEEF));
            vm.expectRevert();
            oracle.registerVault(IERC4626(address(vault)), feed, 1 hours);
            vm.expectRevert();
            oracle.removeVault(address(vault));
            vm.stopPrank();
        }

        function _registeredVault()
            private
            returns (MockOracleVault vault, MockOracleFeed feed, MockPeridotMarket market)
        {
            MockOracleToken asset = new MockOracleToken(6);
            vault = new MockOracleVault(address(asset), 6, 1e6);
            feed = new MockOracleFeed(8, 1e8);
            market = new MockPeridotMarket(address(vault));
            oracle.registerVault(IERC4626(address(vault)), feed, 1 hours);
        }
    }
