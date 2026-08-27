// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../../src/tokens/MockERC20.sol";
import {MockPriceOracle} from "../../src/oracles/MockPriceOracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {RiskManager} from "../../src/RiskManager.sol";

contract LendingPoolIntegrationTest is Test {
    // =============================================================
    // CONTRACTS
    // =============================================================

    MockERC20 weth;
    MockERC20 usdc;

    MockPriceOracle priceOracle;
    InterestRateModel interestRateModel;

    ReserveManager reserveManager;
    LendingPool lendingPool;
    RiskManager riskManager;

    // =============================================================
    // ACTORS
    // =============================================================

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // =============================================================
    // CONSTANTS
    // =============================================================

    uint256 constant WETH = 1e18;
    uint256 constant USDC = 1e6;

    // =============================================================
    // SETUP
    // =============================================================

    function setUp() public {
        // =========================================================
        // TOKENS
        // =========================================================

        weth = new MockERC20("Mock WETH", "mWETH", 18);

        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        // =========================================================
        // ORACLE
        // =========================================================

        priceOracle = new MockPriceOracle();

        priceOracle.setPrice(address(weth), 3000e8, 8);

        priceOracle.setPrice(address(usdc), 1e8, 8);

        // =========================================================
        // INTEREST RATE MODEL
        // =========================================================

        interestRateModel = new InterestRateModel();

        // =========================================================
        // RESERVE MANAGER
        // =========================================================

        reserveManager = new ReserveManager();

        reserveManager.configureReserve(address(weth), 18, 8_000, 8_500, 500);

        reserveManager.configureReserve(address(usdc), 6, 8_000, 8_500, 500);

        reserveManager.setInterestRateModel(address(weth), address(interestRateModel));

        reserveManager.setInterestRateModel(address(usdc), address(interestRateModel));

        // =========================================================
        // LENDING POOL
        // =========================================================

        lendingPool = new LendingPool(address(reserveManager));

        reserveManager.setLendingPool(address(lendingPool));

        // =========================================================
        // RISK MANAGER
        // =========================================================

        riskManager = new RiskManager(address(reserveManager), address(priceOracle), address(lendingPool));

        lendingPool.setRiskManager(address(riskManager));

        // =========================================================
        // USER BALANCES
        // =========================================================

        weth.mint(alice, 20 * WETH);

        weth.mint(bob, 20 * WETH);

        usdc.mint(alice, 20_000 * USDC);

        usdc.mint(bob, 20_000 * USDC);
    }

    // =============================================================
    // BASIC SUPPLY INTEGRATION
    // =============================================================

    function testIntegration_SupplyAndWithdraw() public {
        uint256 supplyAmount = 5 * WETH;

        // ---------------------------------------------------------
        // Alice supplies WETH
        // ---------------------------------------------------------

        vm.startPrank(alice);

        weth.approve(address(lendingPool), supplyAmount);

        lendingPool.supply(address(weth), supplyAmount);

        vm.stopPrank();

        // ---------------------------------------------------------
        // Verify supply
        // ---------------------------------------------------------

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), supplyAmount, "Alice collateral incorrect");

        assertEq(weth.balanceOf(address(lendingPool)), supplyAmount, "Pool WETH balance incorrect");

        // ---------------------------------------------------------
        // Alice withdraws WETH
        // ---------------------------------------------------------

        vm.prank(alice);

        lendingPool.withdraw(address(weth), supplyAmount);

        // ---------------------------------------------------------
        // Verify withdrawal
        // ---------------------------------------------------------

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), 0, "Alice collateral should be zero");

        assertEq(weth.balanceOf(alice), 20 * WETH, "Alice WETH balance incorrect");

        assertEq(weth.balanceOf(address(lendingPool)), 0, "Pool WETH balance should be zero");
    }

    // =============================================================
    // BORROW INTEGRATION
    // =============================================================

    function testIntegration_SupplyBorrowRepay() public {
        uint256 collateralAmount = 5 * WETH;
        uint256 liquidityAmount = 15_000 * USDC;
        uint256 borrowAmount = 10_000 * USDC;

        // ---------------------------------------------------------
        // Bob supplies USDC liquidity
        // ---------------------------------------------------------

        vm.startPrank(bob);

        usdc.approve(address(lendingPool), liquidityAmount);

        lendingPool.supply(address(usdc), liquidityAmount);

        vm.stopPrank();

        // ---------------------------------------------------------
        // Alice supplies WETH collateral
        // ---------------------------------------------------------

        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateralAmount);

        lendingPool.supply(address(weth), collateralAmount);

        vm.stopPrank();

        // ---------------------------------------------------------
        // Verify collateral
        // ---------------------------------------------------------

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), collateralAmount, "Collateral not recorded");

        // ---------------------------------------------------------
        // Alice borrows USDC
        // ---------------------------------------------------------

        vm.prank(alice);

        lendingPool.borrow(address(usdc), borrowAmount);

        // ---------------------------------------------------------
        // Verify debt
        // ---------------------------------------------------------

        uint256 aliceDebt = lendingPool.getUserDebt(alice, address(usdc));

        assertEq(aliceDebt, borrowAmount, "Initial debt incorrect");

        // ---------------------------------------------------------
        // Verify USDC transfer
        // ---------------------------------------------------------

        assertEq(usdc.balanceOf(alice), 20_000 * USDC + borrowAmount, "Alice USDC balance incorrect");

        assertEq(usdc.balanceOf(address(lendingPool)), liquidityAmount - borrowAmount, "Pool USDC liquidity incorrect");

        // ---------------------------------------------------------
        // Alice repays the debt
        // ---------------------------------------------------------

        vm.startPrank(alice);

        usdc.approve(address(lendingPool), borrowAmount);

        lendingPool.repay(address(usdc), borrowAmount);

        vm.stopPrank();

        // ---------------------------------------------------------
        // Verify debt is zero
        // ---------------------------------------------------------

        assertEq(lendingPool.getUserDebt(alice, address(usdc)), 0, "Debt should be zero after repayment");

        // ---------------------------------------------------------
        // Verify collateral remains
        // ---------------------------------------------------------

        assertEq(
            lendingPool.getUserCollateral(alice, address(weth)), collateralAmount, "Collateral unexpectedly changed"
        );
    }

    // =============================================================
    // INTEREST ACCRUAL INTEGRATION
    // =============================================================

    function testIntegration_BorrowAccruesInterest() public {
        uint256 collateralAmount = 5 * WETH;
        uint256 liquidityAmount = 15_000 * USDC;
        uint256 borrowAmount = 10_000 * USDC;

        // ---------------------------------------------------------
        // Bob supplies USDC
        // ---------------------------------------------------------

        vm.startPrank(bob);

        usdc.approve(address(lendingPool), liquidityAmount);

        lendingPool.supply(address(usdc), liquidityAmount);

        vm.stopPrank();

        // ---------------------------------------------------------
        // Alice supplies WETH
        // ---------------------------------------------------------

        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateralAmount);

        lendingPool.supply(address(weth), collateralAmount);

        vm.stopPrank();

        // ---------------------------------------------------------
        // Alice borrows
        // ---------------------------------------------------------

        vm.prank(alice);

        lendingPool.borrow(address(usdc), borrowAmount);

        uint256 initialDebt = lendingPool.getUserDebt(alice, address(usdc));

        assertEq(initialDebt, borrowAmount, "Initial debt incorrect");

        // ---------------------------------------------------------
        // Advance time
        // ---------------------------------------------------------

        vm.warp(block.timestamp + 180 days);

        // ---------------------------------------------------------
        // Accrue interest
        // ---------------------------------------------------------

        reserveManager.accrueInterest(address(usdc));

        // ---------------------------------------------------------
        // Verify debt increased
        // ---------------------------------------------------------

        uint256 accruedDebt = lendingPool.getUserDebt(alice, address(usdc));

        assertGt(accruedDebt, initialDebt, "Debt did not accrue interest");

        // ---------------------------------------------------------
        // Verify borrow index increased
        // ---------------------------------------------------------

        assertGt(reserveManager.getBorrowIndex(address(usdc)), 1e18, "Borrow index did not increase");
    }

    // =============================================================
    // INTEREST + FULL REPAYMENT INTEGRATION
    // =============================================================

    function testIntegration_BorrowAccrueAndRepayFullDebt() public {
        uint256 collateralAmount = 5 * WETH;
        uint256 liquidityAmount = 15_000 * USDC;
        uint256 borrowAmount = 10_000 * USDC;

        // ---------------------------------------------------------
        // Bob provides liquidity
        // ---------------------------------------------------------

        vm.startPrank(bob);

        usdc.approve(address(lendingPool), liquidityAmount);

        lendingPool.supply(address(usdc), liquidityAmount);

        vm.stopPrank();

        // ---------------------------------------------------------
        // Alice provides collateral
        // ---------------------------------------------------------

        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateralAmount);

        lendingPool.supply(address(weth), collateralAmount);

        vm.stopPrank();

        // ---------------------------------------------------------
        // Alice borrows
        // ---------------------------------------------------------

        vm.prank(alice);

        lendingPool.borrow(address(usdc), borrowAmount);

        // ---------------------------------------------------------
        // Advance time
        // ---------------------------------------------------------

        vm.warp(block.timestamp + 180 days);

        // ---------------------------------------------------------
        // Accrue interest
        // ---------------------------------------------------------

        reserveManager.accrueInterest(address(usdc));

        uint256 debtAfterInterest = lendingPool.getUserDebt(alice, address(usdc));

        assertGt(debtAfterInterest, borrowAmount, "Interest was not accrued");

        // ---------------------------------------------------------
        // Repay complete debt
        // ---------------------------------------------------------

        vm.startPrank(alice);

        usdc.approve(address(lendingPool), debtAfterInterest);

        lendingPool.repay(address(usdc), debtAfterInterest);

        vm.stopPrank();

        // ---------------------------------------------------------
        // Verify debt is zero
        // ---------------------------------------------------------

        assertEq(lendingPool.getUserDebt(alice, address(usdc)), 0, "Debt not fully repaid");

        // ---------------------------------------------------------
        // Verify collateral still exists
        // ---------------------------------------------------------

        assertEq(
            lendingPool.getUserCollateral(alice, address(weth)), collateralAmount, "Collateral changed after repayment"
        );
    }

    // =============================================================
    // COMPLETE USER LIFECYCLE
    // =============================================================

    function testIntegration_CompleteLendingLifecycle() public {
        uint256 collateralAmount = 5 * WETH;
        uint256 liquidityAmount = 15_000 * USDC;
        uint256 borrowAmount = 10_000 * USDC;

        // =========================================================
        // STEP 1: Bob supplies liquidity
        // =========================================================

        vm.startPrank(bob);

        usdc.approve(address(lendingPool), liquidityAmount);

        lendingPool.supply(address(usdc), liquidityAmount);

        vm.stopPrank();

        assertEq(lendingPool.getUserCollateral(bob, address(usdc)), liquidityAmount);

        // =========================================================
        // STEP 2: Alice supplies collateral
        // =========================================================

        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateralAmount);

        lendingPool.supply(address(weth), collateralAmount);

        vm.stopPrank();

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), collateralAmount);

        // =========================================================
        // STEP 3: Alice borrows USDC
        // =========================================================

        vm.prank(alice);

        lendingPool.borrow(address(usdc), borrowAmount);

        uint256 debt = lendingPool.getUserDebt(alice, address(usdc));

        assertEq(debt, borrowAmount, "Borrow amount incorrect");

        // =========================================================
        // STEP 4: Time passes
        // =========================================================

        vm.warp(block.timestamp + 180 days);

        // =========================================================
        // STEP 5: Interest accrues
        // =========================================================

        reserveManager.accrueInterest(address(usdc));

        uint256 debtWithInterest = lendingPool.getUserDebt(alice, address(usdc));

        assertGt(debtWithInterest, borrowAmount, "Interest did not accrue");

        // =========================================================
        // STEP 6: Alice repays full debt
        // =========================================================

        vm.startPrank(alice);

        usdc.approve(address(lendingPool), debtWithInterest);

        lendingPool.repay(address(usdc), debtWithInterest);

        vm.stopPrank();

        assertEq(lendingPool.getUserDebt(alice, address(usdc)), 0, "Alice debt not zero");

        // =========================================================
        // STEP 7: Alice withdraws collateral
        // =========================================================

        vm.prank(alice);

        lendingPool.withdraw(address(weth), collateralAmount);

        // =========================================================
        // FINAL STATE
        // =========================================================

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), 0, "Alice collateral not withdrawn");

        assertEq(weth.balanceOf(alice), 20 * WETH, "Alice did not recover WETH");

        assertEq(lendingPool.getUserDebt(alice, address(usdc)), 0, "Alice still has debt");
    }
}
