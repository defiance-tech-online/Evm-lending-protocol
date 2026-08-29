// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {
    AggregatorV3Interface
} from "../../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

contract ChainlinkPriceOracle is IPriceOracle, Ownable {
    struct FeedConfig {
        address feed;
        uint256 maxStaleness;
    }

    mapping(address => FeedConfig) private feeds;

    event FeedConfigured(address indexed asset, address indexed feed, uint256 maxStaleness);

    constructor() Ownable(msg.sender) {}

    // =============================================================
    // ADMIN
    // =============================================================

    function setFeed(address asset, address feed, uint256 maxStaleness) external onlyOwner {
        require(asset != address(0), "Oracle: zero asset");
        require(feed != address(0), "Oracle: zero feed");
        require(maxStaleness > 0, "Oracle: zero staleness");

        uint8 decimals = AggregatorV3Interface(feed).decimals();

        require(decimals <= 18, "Oracle: decimals too high");

        feeds[asset] = FeedConfig({feed: feed, maxStaleness: maxStaleness});

        emit FeedConfigured(asset, feed, maxStaleness);
    }

    // =============================================================
    // PRICE
    // =============================================================

    function getPrice(address asset) external view override returns (uint256) {
        FeedConfig memory config = feeds[asset];

        require(config.feed != address(0), "Oracle: feed not configured");

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(config.feed).latestRoundData();

        require(answer > 0, "Oracle: invalid price");
        require(updatedAt != 0, "Oracle: incomplete round");

        require(answeredInRound >= roundId, "Oracle: stale round");

        require(updatedAt <= block.timestamp, "Oracle: future timestamp");

        require(block.timestamp - updatedAt <= config.maxStaleness, "Oracle: stale price");

        return uint256(answer);
    }

    // =============================================================
    // DECIMALS
    // =============================================================

    function getPriceDecimals(address asset) external view override returns (uint8) {
        FeedConfig memory config = feeds[asset];

        require(config.feed != address(0), "Oracle: feed not configured");

        return AggregatorV3Interface(config.feed).decimals();
    }

    // =============================================================
    // CONFIG VIEW
    // =============================================================

    function getFeed(address asset) external view returns (address feed, uint256 maxStaleness) {
        FeedConfig memory config = feeds[asset];

        return (config.feed, config.maxStaleness);
    }
}
