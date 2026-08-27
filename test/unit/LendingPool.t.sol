// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingPool} from "../../src/LendingPool.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {RiskManager} from "../../src/RiskManager.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {MockPriceOracle} from "../../src/oracles/MockPriceOracle.sol";
import {MockERC20} from "../../src/tokens/MockERC20.sol";

contract LendingPoolTest is Test {
    LendingPool pool;
    ReserveManager reserveManager;
    RiskManager riskManager;
    InterestRateModel interestRateModel;
    MockPriceOracle oracle;

    MockERC20 usdc;
    MockERC20 weth;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address liquidator = makeAddr("liquidator");

    uint256 constant USDC_AMOUNT = 1_000e6;
    uint256 constant WETH_AMOUNT = 10e18;

    function setUp() public {
        reserveManager = new ReserveManager();
        oracle = new MockPriceOracle();
        interestRateModel = new InterestRateModel();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        pool = new LendingPool(address(reserveManager));

        reserveManager.setLendingPool(address(pool));

        riskManager = new RiskManager(address(reserveManager), address(oracle), address(pool));

        pool.setRiskManager(address(riskManager));

        reserveManager.configureReserve(address(usdc), 6, 8_000, 8_500, 500);

        reserveManager.configureReserve(address(weth), 18, 8_000, 8_500, 500);

        reserveManager.setInterestRateModel(address(usdc), address(interestRateModel));

        reserveManager.setInterestRateModel(address(weth), address(interestRateModel));

        oracle.setPrice(address(usdc), 1e8, 8);
        oracle.setPrice(address(weth), 2_000e8, 8);

        // ---------------------------------------------------------
        // Mint user balances
        // ---------------------------------------------------------

        usdc.mint(alice, USDC_AMOUNT * 10);
        usdc.mint(bob, USDC_AMOUNT * 20);
        usdc.mint(liquidator, USDC_AMOUNT * 10);

        weth.mint(alice, WETH_AMOUNT * 10);
        weth.mint(bob, WETH_AMOUNT * 10);

        // ---------------------------------------------------------
        // Approvals
        // ---------------------------------------------------------

        vm.startPrank(alice);

        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);

        vm.stopPrank();

        vm.startPrank(bob);

        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);

        vm.stopPrank();

        vm.startPrank(liquidator);

        usdc.approve(address(pool), type(uint256).max);

        vm.stopPrank();

        // ---------------------------------------------------------
        // Seed USDC liquidity
        //
        // Borrowers cannot borrow unless the pool actually owns
        // enough USDC.
        // ---------------------------------------------------------

        vm.prank(bob);
        pool.supply(address(usdc), 10_000e6);
    }

    // =============================================================
    // SUPPLY
    // =============================================================

    function test_Supply() public {
        uint256 amount = 1_000e6;

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        pool.supply(address(usdc), amount);

        assertEq(pool.getUserCollateral(alice, address(usdc)), amount);

        (uint256 scaledSupply,) = pool.getUserScaledPosition(alice, address(usdc));

        assertEq(scaledSupply, amount);

        assertEq(reserveManager.getTotalScaledSupplied(address(usdc)), 11_000e6);

        assertEq(reserveManager.getTotalSupplied(address(usdc)), 11_000e6);

        assertEq(usdc.balanceOf(address(pool)), 11_000e6);

        assertEq(usdc.balanceOf(alice), aliceBefore - amount);
    }

    function test_SupplyMultipleTimes() public {
        vm.startPrank(alice);

        pool.supply(address(usdc), 500e6);
        pool.supply(address(usdc), 700e6);

        vm.stopPrank();

        assertEq(pool.getUserCollateral(alice, address(usdc)), 1_200e6);

        (uint256 scaledSupply,) = pool.getUserScaledPosition(alice, address(usdc));

        assertEq(scaledSupply, 1_200e6);
    }

    function test_RevertIfSupplyZero() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: zero supply");

        pool.supply(address(usdc), 0);
    }

    // =============================================================
    // WITHDRAW
    // =============================================================

    function test_Withdraw() public {
        uint256 amount = 1_000e6;

        vm.startPrank(alice);

        pool.supply(address(usdc), amount);

        pool.withdraw(address(usdc), 400e6);

        vm.stopPrank();

        assertEq(pool.getUserCollateral(alice, address(usdc)), 600e6);

        (uint256 scaledSupply,) = pool.getUserScaledPosition(alice, address(usdc));

        assertEq(scaledSupply, 600e6);

        assertEq(reserveManager.getTotalScaledSupplied(address(usdc)), 10_600e6);

        assertEq(reserveManager.getTotalSupplied(address(usdc)), 10_600e6);

        assertEq(usdc.balanceOf(alice), USDC_AMOUNT * 10 - 600e6);
    }

    function test_RevertIfWithdrawZero() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: zero withdraw");

        pool.withdraw(address(usdc), 0);
    }

    function test_RevertIfWithdrawTooMuch() public {
        vm.startPrank(alice);

        pool.supply(address(usdc), 1_000e6);

        vm.expectRevert("LendingPool: insufficient collateral");

        pool.withdraw(address(usdc), 1_001e6);

        vm.stopPrank();
    }

    function test_RevertIfWithdrawWithoutCollateral() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: insufficient collateral");

        pool.withdraw(address(usdc), 1e6);
    }

    // =============================================================
    // BORROW
    // =============================================================

    function test_Borrow() public {
        vm.startPrank(alice);

        pool.supply(address(weth), 1e18);

        pool.borrow(address(usdc), 1_000e6);

        vm.stopPrank();

        assertEq(pool.getUserDebt(alice, address(usdc)), 1_000e6);

        (, uint256 scaledDebt) = pool.getUserScaledPosition(alice, address(usdc));

        assertEq(scaledDebt, 1_000e6);

        assertEq(reserveManager.getTotalScaledBorrowed(address(usdc)), 1_000e6);

        assertEq(usdc.balanceOf(alice), USDC_AMOUNT * 10 + 1_000e6);
    }

    function test_RevertIfBorrowZero() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: zero borrow");

        pool.borrow(address(usdc), 0);
    }

    function test_RevertIfBorrowExceedsCollateral() public {
        vm.startPrank(alice);

        pool.supply(address(weth), 1e18);

        vm.expectRevert("LendingPool: borrow not allowed");

        pool.borrow(address(usdc), 2_000e6);

        vm.stopPrank();
    }

    function test_RevertIfBorrowWithoutLiquidity() public {
        // Drain the seeded USDC liquidity by withdrawing Bob's supply.
        vm.startPrank(bob);

        pool.withdraw(address(usdc), 10_000e6);

        vm.stopPrank();

        vm.startPrank(alice);

        pool.supply(address(weth), 1e18);

        vm.expectRevert("LendingPool: insufficient liquidity");

        pool.borrow(address(usdc), 1_000e6);

        vm.stopPrank();
    }

    // =============================================================
    // REPAY
    // =============================================================

    function test_PartialRepay() public {
        vm.startPrank(alice);

        pool.supply(address(weth), 1e18);
        pool.borrow(address(usdc), 1_000e6);

        pool.repay(address(usdc), 400e6);

        vm.stopPrank();

        assertEq(pool.getUserDebt(alice, address(usdc)), 600e6);

        (, uint256 scaledDebt) = pool.getUserScaledPosition(alice, address(usdc));

        assertEq(scaledDebt, 600e6);

        assertEq(reserveManager.getTotalScaledBorrowed(address(usdc)), 600e6);
    }

    function test_FullRepay() public {
        vm.startPrank(alice);

        pool.supply(address(weth), 1e18);
        pool.borrow(address(usdc), 1_000e6);

        pool.repay(address(usdc), type(uint256).max);

        vm.stopPrank();

        assertEq(pool.getUserDebt(alice, address(usdc)), 0);

        (, uint256 scaledDebt) = pool.getUserScaledPosition(alice, address(usdc));

        assertEq(scaledDebt, 0);

        assertEq(reserveManager.getTotalScaledBorrowed(address(usdc)), 0);
    }

    function test_RepayCannotExceedDebt() public {
        vm.startPrank(alice);

        pool.supply(address(weth), 1e18);
        pool.borrow(address(usdc), 1_000e6);

        pool.repay(address(usdc), 2_000e6);

        vm.stopPrank();

        assertEq(pool.getUserDebt(alice, address(usdc)), 0);

        (, uint256 scaledDebt) = pool.getUserScaledPosition(alice, address(usdc));

        assertEq(scaledDebt, 0);
    }

    function test_RevertIfRepayZero() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: zero repay");

        pool.repay(address(usdc), 0);
    }

    function test_RevertIfRepayWithoutDebt() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: no debt");

        pool.repay(address(usdc), 1e6);
    }

    // =============================================================
    // INTEREST
    // =============================================================

    function test_DebtAccruesInterest() public {
        vm.startPrank(alice);

        pool.supply(address(weth), 1e18);
        pool.borrow(address(usdc), 1_000e6);

        vm.stopPrank();

        uint256 initialDebt = pool.getUserDebt(alice, address(usdc));

        vm.warp(block.timestamp + 365 days);

        uint256 finalDebt = pool.getUserDebt(alice, address(usdc));

        assertGt(finalDebt, initialDebt);
    }

    function test_CollateralAccruesInterest() public {
        vm.prank(alice);
        pool.supply(address(usdc), 1_000e6);

        vm.startPrank(bob);

        pool.supply(address(weth), 1e18);
        pool.borrow(address(usdc), 500e6);

        vm.stopPrank();

        uint256 initialCollateral = pool.getUserCollateral(alice, address(usdc));

        vm.warp(block.timestamp + 365 days);

        uint256 finalCollateral = pool.getUserCollateral(alice, address(usdc));

        assertGt(finalCollateral, initialCollateral);
    }

    function test_ScaledDebtDoesNotChangeFromInterest() public {
        vm.startPrank(alice);

        pool.supply(address(weth), 1e18);
        pool.borrow(address(usdc), 1_000e6);

        vm.stopPrank();

        (, uint256 scaledBefore) = pool.getUserScaledPosition(alice, address(usdc));

        vm.warp(block.timestamp + 365 days);

        // View functions preview the current index.
        uint256 debt = pool.getUserDebt(alice, address(usdc));

        (, uint256 scaledAfter) = pool.getUserScaledPosition(alice, address(usdc));

        assertGt(debt, 1_000e6);
        assertEq(scaledAfter, scaledBefore);
    }

    // =============================================================
    // MULTI USER
    // =============================================================

    function test_MultipleUsersSupply() public {
        vm.prank(alice);
        pool.supply(address(usdc), 1_000e6);

        vm.prank(bob);
        pool.supply(address(usdc), 2_000e6);

        assertEq(reserveManager.getTotalScaledSupplied(address(usdc)), 13_000e6);

        assertEq(pool.getUserCollateral(alice, address(usdc)), 1_000e6);

        assertEq(pool.getUserCollateral(bob, address(usdc)), 12_000e6);
    }

    function test_MultipleUsersBorrow() public {
        vm.prank(alice);
        pool.supply(address(weth), 2e18);

        vm.prank(bob);
        pool.supply(address(weth), 2e18);

        vm.prank(alice);
        pool.borrow(address(usdc), 1_000e6);

        vm.prank(bob);
        pool.borrow(address(usdc), 1_000e6);

        assertEq(reserveManager.getTotalScaledBorrowed(address(usdc)), 2_000e6);
    }

    // =============================================================
    // POSITION VIEWS
    // =============================================================

    function test_GetUserPosition() public {
        vm.startPrank(alice);

        pool.supply(address(weth), 1e18);
        pool.borrow(address(usdc), 1_000e6);

        vm.stopPrank();

        (uint256 supplied, uint256 borrowed, uint256 supplyIndex, uint256 borrowIndex) =
            pool.getUserPosition(alice, address(weth));

        assertEq(supplied, 1e18);
        assertEq(borrowed, 0);
        assertGt(supplyIndex, 0);
        assertGt(borrowIndex, 0);

        (uint256 usdcSupplied, uint256 usdcBorrowed, uint256 usdcSupplyIndex, uint256 usdcBorrowIndex) =
            pool.getUserPosition(alice, address(usdc));

        assertEq(usdcSupplied, 0);
        assertEq(usdcBorrowed, 1_000e6);
        assertGt(usdcSupplyIndex, 0);
        assertGt(usdcBorrowIndex, 0);
    }

    function test_GetUserScaledPosition() public {
        vm.startPrank(alice);

        pool.supply(address(weth), 1e18);
        pool.borrow(address(usdc), 1_000e6);

        vm.stopPrank();

        (uint256 supplied, uint256 borrowed) = pool.getUserScaledPosition(alice, address(weth));

        assertEq(supplied, 1e18);
        assertEq(borrowed, 0);

        (, borrowed) = pool.getUserScaledPosition(alice, address(usdc));

        assertEq(borrowed, 1_000e6);
    }

    function test_GetSupportedAssets() public {
        vm.prank(alice);
        pool.supply(address(weth), 1e18);

        vm.prank(alice);
        pool.supply(address(usdc), 1_000e6);

        address[] memory assets = pool.getSupportedAssets();

        assertEq(assets.length, 2);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(weth));
    }

    // =============================================================
    // HEALTH FACTOR
    // =============================================================

    function test_HealthFactor() public {
        vm.startPrank(alice);

        pool.supply(address(weth), 1e18);
        pool.borrow(address(usdc), 1_000e6);

        vm.stopPrank();

        uint256 healthFactor = pool.getHealthFactor(alice);

        assertGt(healthFactor, 1e18);
    }

    // =============================================================
    // LIQUIDATION
    // =============================================================

    function _createUnhealthyPosition() internal {
        vm.startPrank(alice);

        pool.supply(address(weth), 1e18);

        // At $2,000 WETH:
        // collateral = $2,000
        // liquidation threshold = 85%
        // max debt before liquidation = $1,700
        //
        // Borrow $1,600 so full debt liquidation remains
        // within the available collateral after the bonus.

        pool.borrow(address(usdc), 1_600e6);

        vm.stopPrank();

        // Price falls from $2,000 to $1,500.
        oracle.setPrice(address(weth), 1_500e8, 8);
    }

    function test_RevertIfLiquidateHealthyPosition() public {
        vm.startPrank(alice);

        pool.supply(address(weth), 1e18);
        pool.borrow(address(usdc), 1_000e6);

        vm.stopPrank();

        vm.prank(liquidator);

        vm.expectRevert("LendingPool: position healthy");

        pool.liquidate(alice, address(usdc), address(weth), 500e6);
    }

    function test_PartialLiquidation() public {
        _createUnhealthyPosition();

        uint256 liquidatorUSDCBefore = usdc.balanceOf(liquidator);

        uint256 liquidatorWETHBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);

        pool.liquidate(alice, address(usdc), address(weth), 500e6);

        // $500 debt + 5% liquidation bonus = $525 collateral.
        // At $1,500/WETH:
        // 525 / 1500 = 0.35 WETH.
        assertEq(weth.balanceOf(liquidator), liquidatorWETHBefore + 0.35e18);

        assertEq(usdc.balanceOf(liquidator), liquidatorUSDCBefore - 500e6);

        assertEq(pool.getUserDebt(alice, address(usdc)), 1_100e6);

        assertEq(pool.getUserCollateral(alice, address(weth)), 0.65e18);
    }

    function test_FullDebtLiquidation() public {
        _createUnhealthyPosition();

        // Alice has 1 WETH and $1,600 debt.
        // At $1,500/WETH, 1.12 WETH is required including
        // the 5% liquidation bonus, so full liquidation cannot
        // succeed with only 1 WETH.
        vm.prank(liquidator);

        vm.expectRevert("LendingPool: liquidation exceeds collateral");

        pool.liquidate(alice, address(usdc), address(weth), 1_600e6);
    }

    function test_RevertIfLiquidationExceedsCollateral() public {
        _createUnhealthyPosition();

        vm.prank(liquidator);

        vm.expectRevert("LendingPool: liquidation exceeds collateral");

        pool.liquidate(alice, address(usdc), address(weth), 1_600e6);
    }

    function test_RevertIfLiquidationExceedsDebt() public {
        _createUnhealthyPosition();

        vm.prank(liquidator);

        vm.expectRevert("LendingPool: liquidation exceeds debt");

        pool.liquidate(alice, address(usdc), address(weth), 2_000e6);
    }

    // =============================================================
    // ASSET REGISTRATION
    // =============================================================

    function test_AssetRegisteredOnlyOnce() public {
        vm.startPrank(alice);

        pool.supply(address(usdc), 1e6);
        pool.supply(address(usdc), 2e6);
        pool.supply(address(weth), 1e18);

        vm.stopPrank();

        address[] memory assets = pool.getSupportedAssets();

        assertEq(assets.length, 2);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(weth));
    }
}
