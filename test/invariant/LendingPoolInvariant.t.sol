// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../../src/tokens/MockERC20.sol";
import {MockPriceOracle} from "../../src/oracles/MockPriceOracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {RiskManager} from "../../src/RiskManager.sol";

import {LendingPoolHandler} from "./LendingPoolHandler.t.sol";

contract LendingPoolInvariantTest is StdInvariant, Test {
    MockERC20 weth;
    MockERC20 usdc;

    MockPriceOracle priceOracle;
    InterestRateModel interestRateModel;

    ReserveManager reserveManager;
    LendingPool lendingPool;
    RiskManager riskManager;

    LendingPoolHandler handler;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant USDC = 1e6;
    uint256 constant WETH = 1e18;

    /*
     * The protocol uses scaled accounting.
     *
     * Actual balances are reconstructed from:
     *
     *     scaledAmount * index / WAD
     *
     * Individual positions and aggregate reserve accounting can
     * differ by very small amounts because of integer division.
     */
    uint256 constant MAX_ROUNDING_DUST = 20;

    function setUp() public {
        // =========================================================
        // TOKENS
        // =========================================================

        weth = new MockERC20("Mock WETH", "mWETH", 18);

        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        // =========================================================
        // ORACLE / INTEREST MODEL
        // =========================================================

        priceOracle = new MockPriceOracle();

        interestRateModel = new InterestRateModel();

        // =========================================================
        // RESERVE MANAGER
        // =========================================================

        reserveManager = new ReserveManager();

        reserveManager.configureReserve(address(weth), 18, 8_000, 8_500, 500);

        reserveManager.configureReserve(address(usdc), 6, 8_000, 8_500, 500);

        // =========================================================
        // LENDING POOL
        // =========================================================

        lendingPool = new LendingPool(address(reserveManager));

        reserveManager.setLendingPool(address(lendingPool));

        // =========================================================
        // INTEREST RATE MODEL
        // =========================================================

        reserveManager.setInterestRateModel(address(weth), address(interestRateModel));

        reserveManager.setInterestRateModel(address(usdc), address(interestRateModel));

        // =========================================================
        // RISK MANAGER
        // =========================================================

        riskManager = new RiskManager(address(reserveManager), address(priceOracle), address(lendingPool));

        lendingPool.setRiskManager(address(riskManager));

        // =========================================================
        // ORACLE PRICES
        // =========================================================

        priceOracle.setPrice(address(weth), 3000e8, 8);

        priceOracle.setPrice(address(usdc), 1e8, 8);

        // =========================================================
        // INITIAL USER BALANCES
        // =========================================================

        weth.mint(alice, 20 * WETH);

        weth.mint(bob, 20 * WETH);

        usdc.mint(alice, 20_000 * USDC);

        usdc.mint(bob, 20_000 * USDC);

        // =========================================================
        // HANDLER
        // =========================================================

        handler = new LendingPoolHandler(weth, usdc, reserveManager, lendingPool, alice, bob);

        targetContract(address(handler));
    }

    // =============================================================
    // RESERVE CONFIGURATION
    // =============================================================

    function invariant_WETHReserveAlwaysActive() public view {
        assertTrue(reserveManager.isActive(address(weth)));
    }

    function invariant_USDCReserveAlwaysActive() public view {
        assertTrue(reserveManager.isActive(address(usdc)));
    }

    function invariant_WETHBorrowAlwaysEnabled() public view {
        assertTrue(reserveManager.isBorrowEnabled(address(weth)));
    }

    function invariant_USDCBorrowAlwaysEnabled() public view {
        assertTrue(reserveManager.isBorrowEnabled(address(usdc)));
    }

    // =============================================================
    // SCALED SUPPLY ACCOUNTING
    // =============================================================

    function invariant_WETHScaledSupplyAccounting() public view {
        uint256 reserveScaled = reserveManager.getTotalScaledSupplied(address(weth));

        (uint256 aliceScaled,) = lendingPool.getUserScaledPosition(alice, address(weth));

        (uint256 bobScaled,) = lendingPool.getUserScaledPosition(bob, address(weth));

        assertEq(reserveScaled, aliceScaled + bobScaled, "WETH scaled supply mismatch");
    }

    function invariant_USDCScaledSupplyAccounting() public view {
        uint256 reserveScaled = reserveManager.getTotalScaledSupplied(address(usdc));

        (uint256 aliceScaled,) = lendingPool.getUserScaledPosition(alice, address(usdc));

        (uint256 bobScaled,) = lendingPool.getUserScaledPosition(bob, address(usdc));

        assertEq(reserveScaled, aliceScaled + bobScaled, "USDC scaled supply mismatch");
    }

    // =============================================================
    // SCALED BORROW ACCOUNTING
    // =============================================================

    function invariant_WETHScaledBorrowAccounting() public view {
        uint256 reserveScaled = reserveManager.getTotalScaledBorrowed(address(weth));

        (, uint256 aliceScaled) = lendingPool.getUserScaledPosition(alice, address(weth));

        (, uint256 bobScaled) = lendingPool.getUserScaledPosition(bob, address(weth));

        assertEq(reserveScaled, aliceScaled + bobScaled, "WETH scaled borrow mismatch");
    }

    function invariant_USDCScaledBorrowAccounting() public view {
        uint256 reserveScaled = reserveManager.getTotalScaledBorrowed(address(usdc));

        (, uint256 aliceScaled) = lendingPool.getUserScaledPosition(alice, address(usdc));

        (, uint256 bobScaled) = lendingPool.getUserScaledPosition(bob, address(usdc));

        assertEq(reserveScaled, aliceScaled + bobScaled, "USDC scaled borrow mismatch");
    }

    // =============================================================
    // ACTUAL SUPPLY ACCOUNTING
    // =============================================================

    function invariant_WETHActualSupplyAccounting() public view {
        uint256 reserveTotal = reserveManager.getTotalSupplied(address(weth));

        uint256 aliceSupply = lendingPool.getUserCollateral(alice, address(weth));

        uint256 bobSupply = lendingPool.getUserCollateral(bob, address(weth));

        assertApproxEqAbs(reserveTotal, aliceSupply + bobSupply, MAX_ROUNDING_DUST, "WETH actual supply mismatch");
    }

    function invariant_USDCActualSupplyAccounting() public view {
        uint256 reserveTotal = reserveManager.getTotalSupplied(address(usdc));

        uint256 aliceSupply = lendingPool.getUserCollateral(alice, address(usdc));

        uint256 bobSupply = lendingPool.getUserCollateral(bob, address(usdc));

        assertApproxEqAbs(reserveTotal, aliceSupply + bobSupply, MAX_ROUNDING_DUST, "USDC actual supply mismatch");
    }

    // =============================================================
    // ACTUAL DEBT ACCOUNTING
    // =============================================================

    function invariant_WETHActualDebtAccounting() public view {
        uint256 reserveDebt = reserveManager.getTotalBorrowed(address(weth));

        uint256 aliceDebt = lendingPool.getUserDebt(alice, address(weth));

        uint256 bobDebt = lendingPool.getUserDebt(bob, address(weth));

        assertApproxEqAbs(reserveDebt, aliceDebt + bobDebt, MAX_ROUNDING_DUST, "WETH actual debt mismatch");
    }

    function invariant_USDCActualDebtAccounting() public view {
        uint256 reserveDebt = reserveManager.getTotalBorrowed(address(usdc));

        uint256 aliceDebt = lendingPool.getUserDebt(alice, address(usdc));

        uint256 bobDebt = lendingPool.getUserDebt(bob, address(usdc));

        assertApproxEqAbs(reserveDebt, aliceDebt + bobDebt, MAX_ROUNDING_DUST, "USDC actual debt mismatch");
    }

    // =============================================================
    // INDEX SAFETY
    // =============================================================

    function invariant_WETHBorrowIndexNonZero() public view {
        assertGt(reserveManager.getBorrowIndex(address(weth)), 0);
    }

    function invariant_WETHSupplyIndexNonZero() public view {
        assertGt(reserveManager.getSupplyIndex(address(weth)), 0);
    }

    function invariant_USDCBorrowIndexNonZero() public view {
        assertGt(reserveManager.getBorrowIndex(address(usdc)), 0);
    }

    function invariant_USDCSupplyIndexNonZero() public view {
        assertGt(reserveManager.getSupplyIndex(address(usdc)), 0);
    }

    // =============================================================
    // INDEX MONOTONICITY
    // =============================================================

    function invariant_WETHBorrowIndexAtLeastOne() public view {
        assertGe(reserveManager.getBorrowIndex(address(weth)), 1e18);
    }

    function invariant_WETHSupplyIndexAtLeastOne() public view {
        assertGe(reserveManager.getSupplyIndex(address(weth)), 1e18);
    }

    function invariant_USDCBorrowIndexAtLeastOne() public view {
        assertGe(reserveManager.getBorrowIndex(address(usdc)), 1e18);
    }

    function invariant_USDCSupplyIndexAtLeastOne() public view {
        assertGe(reserveManager.getSupplyIndex(address(usdc)), 1e18);
    }

    // =============================================================
    // POSITION CONSISTENCY
    // =============================================================

    function invariant_AliceWETHPositionConsistency() public view {
        (uint256 scaledSupply, uint256 scaledBorrow) = lendingPool.getUserScaledPosition(alice, address(weth));

        uint256 actualSupply = lendingPool.getUserCollateral(alice, address(weth));

        uint256 actualDebt = lendingPool.getUserDebt(alice, address(weth));

        if (scaledSupply == 0) {
            assertEq(actualSupply, 0);
        } else {
            assertGt(actualSupply, 0);
        }

        if (scaledBorrow == 0) {
            assertEq(actualDebt, 0);
        } else {
            assertGt(actualDebt, 0);
        }
    }

    function invariant_BobWETHPositionConsistency() public view {
        (uint256 scaledSupply, uint256 scaledBorrow) = lendingPool.getUserScaledPosition(bob, address(weth));

        uint256 actualSupply = lendingPool.getUserCollateral(bob, address(weth));

        uint256 actualDebt = lendingPool.getUserDebt(bob, address(weth));

        if (scaledSupply == 0) {
            assertEq(actualSupply, 0);
        } else {
            assertGt(actualSupply, 0);
        }

        if (scaledBorrow == 0) {
            assertEq(actualDebt, 0);
        } else {
            assertGt(actualDebt, 0);
        }
    }

    function invariant_AliceUSDCPositionConsistency() public view {
        (uint256 scaledSupply, uint256 scaledBorrow) = lendingPool.getUserScaledPosition(alice, address(usdc));

        uint256 actualSupply = lendingPool.getUserCollateral(alice, address(usdc));

        uint256 actualDebt = lendingPool.getUserDebt(alice, address(usdc));

        if (scaledSupply == 0) {
            assertEq(actualSupply, 0);
        } else {
            assertGt(actualSupply, 0);
        }

        if (scaledBorrow == 0) {
            assertEq(actualDebt, 0);
        } else {
            assertGt(actualDebt, 0);
        }
    }

    function invariant_BobUSDCPositionConsistency() public view {
        (uint256 scaledSupply, uint256 scaledBorrow) = lendingPool.getUserScaledPosition(bob, address(usdc));

        uint256 actualSupply = lendingPool.getUserCollateral(bob, address(usdc));

        uint256 actualDebt = lendingPool.getUserDebt(bob, address(usdc));

        if (scaledSupply == 0) {
            assertEq(actualSupply, 0);
        } else {
            assertGt(actualSupply, 0);
        }

        if (scaledBorrow == 0) {
            assertEq(actualDebt, 0);
        } else {
            assertGt(actualDebt, 0);
        }
    }

    // =============================================================
    // SUPPLY / DEBT EXISTENCE
    // =============================================================

    function invariant_WETHScaledSupplyImpliesActualSupply() public view {
        uint256 scaledSupply = reserveManager.getTotalScaledSupplied(address(weth));

        uint256 actualSupply = reserveManager.getTotalSupplied(address(weth));

        if (scaledSupply > 0) {
            assertGt(actualSupply, 0);
        }
    }

    function invariant_USDCScaledSupplyImpliesActualSupply() public view {
        uint256 scaledSupply = reserveManager.getTotalScaledSupplied(address(usdc));

        uint256 actualSupply = reserveManager.getTotalSupplied(address(usdc));

        if (scaledSupply > 0) {
            assertGt(actualSupply, 0);
        }
    }

    function invariant_WETHScaledDebtImpliesActualDebt() public view {
        uint256 scaledDebt = reserveManager.getTotalScaledBorrowed(address(weth));

        uint256 actualDebt = reserveManager.getTotalBorrowed(address(weth));

        if (scaledDebt > 0) {
            assertGt(actualDebt, 0);
        }
    }

    function invariant_USDCScaledDebtImpliesActualDebt() public view {
        uint256 scaledDebt = reserveManager.getTotalScaledBorrowed(address(usdc));

        uint256 actualDebt = reserveManager.getTotalBorrowed(address(usdc));

        if (scaledDebt > 0) {
            assertGt(actualDebt, 0);
        }
    }

    // =============================================================
    // PROTOCOL SOLVENCY
    // =============================================================

    function invariant_USDCProtocolSolvent() public view {
        uint256 cash = usdc.balanceOf(address(lendingPool));

        uint256 supplied =
            lendingPool.getUserCollateral(alice, address(usdc)) + lendingPool.getUserCollateral(bob, address(usdc));

        uint256 debt = lendingPool.getUserDebt(alice, address(usdc)) + lendingPool.getUserDebt(bob, address(usdc));

        assertGe(cash + debt + MAX_ROUNDING_DUST, supplied, "USDC protocol insolvent");
    }

    function invariant_WETHProtocolSolvent() public view {
        uint256 cash = weth.balanceOf(address(lendingPool));

        uint256 supplied =
            lendingPool.getUserCollateral(alice, address(weth)) + lendingPool.getUserCollateral(bob, address(weth));

        uint256 debt = lendingPool.getUserDebt(alice, address(weth)) + lendingPool.getUserDebt(bob, address(weth));

        assertGe(cash + debt + MAX_ROUNDING_DUST, supplied, "WETH protocol insolvent");
    }
}
