// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ChainlinkPriceOracle} from "../../src/oracles/ChainlinkPriceOracle.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

contract ChainlinkPriceOracleTest is Test {
    ChainlinkPriceOracle internal oracle;
    MockAggregatorV3 internal feed;

    address internal constant ASSET = address(0x1234);
    address internal constant NON_OWNER = address(0xBEEF);

    uint256 internal constant MAX_STALENESS = 1 hours;

    function setUp() public {
        oracle = new ChainlinkPriceOracle();
        feed = new MockAggregatorV3(8);

        feed.setRoundData(1, 3_000e8, block.timestamp, block.timestamp, 1);
    }

    function test_SetFeed() public {
        oracle.setFeed(ASSET, address(feed), MAX_STALENESS);

        (address configuredFeed, uint256 maxStaleness) = oracle.getFeed(ASSET);

        assertEq(configuredFeed, address(feed));
        assertEq(maxStaleness, MAX_STALENESS);
    }

    function test_GetPrice() public {
        oracle.setFeed(ASSET, address(feed), MAX_STALENESS);

        assertEq(oracle.getPrice(ASSET), 3_000e8);
    }

    function test_GetPriceDecimals() public {
        oracle.setFeed(ASSET, address(feed), MAX_STALENESS);

        assertEq(oracle.getPriceDecimals(ASSET), 8);
    }

    function test_RevertSetFeedNotOwner() public {
        vm.prank(NON_OWNER);

        vm.expectRevert();

        oracle.setFeed(ASSET, address(feed), MAX_STALENESS);
    }

    function test_RevertZeroAsset() public {
        vm.expectRevert("Oracle: zero asset");

        oracle.setFeed(address(0), address(feed), MAX_STALENESS);
    }

    function test_RevertZeroFeed() public {
        vm.expectRevert("Oracle: zero feed");

        oracle.setFeed(ASSET, address(0), MAX_STALENESS);
    }

    function test_RevertZeroStaleness() public {
        vm.expectRevert("Oracle: zero staleness");

        oracle.setFeed(ASSET, address(feed), 0);
    }

    function test_RevertUnconfiguredFeed() public {
        vm.expectRevert("Oracle: feed not configured");

        oracle.getPrice(ASSET);
    }

    function test_RevertInvalidPriceZero() public {
        oracle.setFeed(ASSET, address(feed), MAX_STALENESS);

        feed.setRoundData(1, 0, block.timestamp, block.timestamp, 1);

        vm.expectRevert("Oracle: invalid price");

        oracle.getPrice(ASSET);
    }

    function test_RevertNegativePrice() public {
        oracle.setFeed(ASSET, address(feed), MAX_STALENESS);

        feed.setRoundData(1, -1, block.timestamp, block.timestamp, 1);

        vm.expectRevert("Oracle: invalid price");

        oracle.getPrice(ASSET);
    }

    function test_RevertIncompleteRound() public {
        oracle.setFeed(ASSET, address(feed), MAX_STALENESS);

        feed.setRoundData(1, 3_000e8, block.timestamp, 0, 1);

        vm.expectRevert("Oracle: incomplete round");

        oracle.getPrice(ASSET);
    }

    function test_RevertStaleRound() public {
        oracle.setFeed(ASSET, address(feed), MAX_STALENESS);

        feed.setRoundData(2, 3_000e8, block.timestamp, block.timestamp, 1);

        vm.expectRevert("Oracle: stale round");

        oracle.getPrice(ASSET);
    }

    function test_RevertStalePrice() public {
        oracle.setFeed(ASSET, address(feed), MAX_STALENESS);

        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert("Oracle: stale price");

        oracle.getPrice(ASSET);
    }

    function test_RevertFutureTimestamp() public {
        oracle.setFeed(ASSET, address(feed), MAX_STALENESS);

        feed.setRoundData(1, 3_000e8, block.timestamp, block.timestamp + 1, 1);

        vm.expectRevert("Oracle: future timestamp");

        oracle.getPrice(ASSET);
    }

    function test_RevertDecimalsTooHigh() public {
        MockAggregatorV3 badFeed = new MockAggregatorV3(19);

        vm.expectRevert("Oracle: decimals too high");

        oracle.setFeed(ASSET, address(badFeed), MAX_STALENESS);
    }
}
