// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../../src/tokens/MockERC20.sol";
import {MockPriceOracle} from "../../src/oracles/MockPriceOracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {RiskManager} from "../../src/RiskManager.sol";
import {LendingPoolHandler} from "./LendingPoolHandler.t.sol";

contract LendingPoolInvariantTest is Test {
    MockERC20 weth;
    MockERC20 usdc;

    MockPriceOracle priceOracle;
    InterestRateModel interestRateModel;

    ReserveManager reserveManager;
    LendingPool lendingPool;
    RiskManager riskManager;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant USDC = 1e6;
    uint256 constant WETH = 1e18;

    LendingPoolHandler public handler;

    function setUp() public {
        weth = new MockERC20("Mock WETH", "mWETH", 18);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        priceOracle = new MockPriceOracle();
        interestRateModel = new InterestRateModel();

        reserveManager = new ReserveManager();

        reserveManager.configureReserve(address(weth), 18, 8_000, 8_500, 500);

        reserveManager.configureReserve(address(usdc), 6, 8_000, 8_500, 500);

        reserveManager.setInterestRateModel(address(weth), address(interestRateModel));

        reserveManager.setInterestRateModel(address(usdc), address(interestRateModel));

        lendingPool = new LendingPool(address(reserveManager));

        reserveManager.setLendingPool(address(lendingPool));

        riskManager = new RiskManager(address(reserveManager), address(priceOracle), address(lendingPool));

        lendingPool.setRiskManager(address(riskManager));

        priceOracle.setPrice(address(weth), 3000e8, 8);
        priceOracle.setPrice(address(usdc), 1e8, 8);

        weth.mint(alice, 20 * WETH);
        weth.mint(bob, 20 * WETH);

        usdc.mint(alice, 20_000 * USDC);
        usdc.mint(bob, 20_000 * USDC);

        handler = new LendingPoolHandler(weth, usdc, reserveManager, lendingPool, alice, bob);

        targetContract(address(handler));
    }

    // =============================================================
    // RESERVE INVARIANTS
    // =============================================================

    function invariant_WETHReserveRemainsActive() public view {
        assertTrue(reserveManager.isActive(address(weth)));
    }

    function invariant_USDCReserveRemainsActive() public view {
        assertTrue(reserveManager.isActive(address(usdc)));
    }

    // =============================================================
    // WETH SOLVENCY
    // =============================================================

    function invariant_WETHProtocolIsSolvent() public view {
        uint256 cash = weth.balanceOf(address(lendingPool));

        uint256 totalSupplied = reserveManager.getTotalSupplied(address(weth));

        uint256 totalBorrowed = reserveManager.getTotalBorrowed(address(weth));

        assertGe(cash + totalBorrowed, totalSupplied, "WETH protocol insolvent");
    }

    // =============================================================
    // USDC SOLVENCY
    // =============================================================

    function invariant_USDCProtocolIsSolvent() public view {
        uint256 cash = usdc.balanceOf(address(lendingPool));

        uint256 totalSupplied = reserveManager.getTotalSupplied(address(usdc));

        uint256 totalBorrowed = reserveManager.getTotalBorrowed(address(usdc));

        assertGe(cash + totalBorrowed, totalSupplied, "USDC protocol insolvent");
    }

    // =============================================================
    // SUPPLY ACCOUNTING
    // =============================================================

    function invariant_USDCSupplyAccounting() public view {
        uint256 cash = usdc.balanceOf(address(lendingPool));

        uint256 totalSupplied = reserveManager.getTotalSupplied(address(usdc));

        uint256 totalBorrowed = reserveManager.getTotalBorrowed(address(usdc));

        assertGe(cash + totalBorrowed, totalSupplied, "USDC supply accounting broken");
    }
}
