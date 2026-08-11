// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {ISAVAX} from "../contracts/interfaces/ISAVAX.sol";
import {ChainlinkRatioOracle} from "../contracts/oracles/ChainlinkRatioOracle.sol";
import {SAVAXRateOracle} from "../contracts/oracles/SAVAXRateOracle.sol";

contract OracleTestToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }
}

contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 public immutable override decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setRound(int256 answer_, uint256 updatedAt_, uint80 answeredInRound_) external {
        roundId++;
        answer = answer_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function description() external pure override returns (string memory) {
        return "mock";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

    contract MockSAVAX is OracleTestToken, ISAVAX {
        uint256 public rate = 1.25 ether;

        constructor() OracleTestToken("sAVAX", 18) {}

        function setRate(uint256 rate_) external {
            rate = rate_;
        }

        function getPooledAvaxByShares(uint256 sharesAmount) external view override returns (uint256) {
            return (sharesAmount * rate) / 1 ether;
        }

        function getSharesByPooledAvax(uint256 avaxAmount) external view override returns (uint256) {
            return (avaxAmount * 1 ether) / rate;
        }
    }

    contract PharaohOraclesTest is Test {
        OracleTestToken private usdc;
        OracleTestToken private usdt;
        MockAggregatorV3 private usdcFeed;
        MockAggregatorV3 private usdtFeed;
        ChainlinkRatioOracle private ratioOracle;

        function setUp() public {
            usdc = new OracleTestToken("USDC", 6);
            usdt = new OracleTestToken("USDt", 6);
            usdcFeed = new MockAggregatorV3(8, 1e8);
            usdtFeed = new MockAggregatorV3(8, 99_000_000);
            ratioOracle = new ChainlinkRatioOracle(address(usdc), address(usdt), usdcFeed, usdtFeed, 1 hours);
        }

        function test_chainlinkRatioHandlesPricesAndRawTokenDecimals() public view {
            assertEq(ratioOracle.quotePairToAsset(100e6), 99e6);
            assertEq(ratioOracle.quoteAssetToPair(99e6), 100e6);

            (uint256 assetPrice, uint256 pairedPrice) = ratioOracle.prices();
            assertEq(assetPrice, 1 ether);
            assertEq(pairedPrice, 0.99 ether);
        }

        function test_chainlinkRatioRejectsStaleRound() public {
            vm.warp(block.timestamp + 2 hours);
            vm.expectRevert();
            ratioOracle.quotePairToAsset(1e6);
        }

        function test_chainlinkRatioRejectsInvalidRound() public {
            usdtFeed.setRound(-1, block.timestamp, usdtFeed.roundId() + 1);
            vm.expectRevert();
            ratioOracle.quotePairToAsset(1e6);
        }

        function test_sAVAXOracleUsesProtocolExchangeRate() public {
            OracleTestToken wavax = new OracleTestToken("WAVAX", 18);
            MockSAVAX sAVAX = new MockSAVAX();
            SAVAXRateOracle oracle = new SAVAXRateOracle(address(wavax), sAVAX);

            assertEq(oracle.quotePairToAsset(2 ether), 2.5 ether);
            assertEq(oracle.quoteAssetToPair(2.5 ether), 2 ether);

            sAVAX.setRate(1.3 ether);
            assertEq(oracle.quotePairToAsset(2 ether), 2.6 ether);
        }
    }
