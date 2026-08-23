// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../../src/tokens/MockERC20.sol";
import {MockPriceOracle} from "../../src/oracles/MockPriceOracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {RiskManager} from "../../src/RiskManager.sol";

contract LendingPoolTest is Test {
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
    }

    // =============================================================
    // HELPERS
    // =============================================================

    function _provideUSDC() internal {
        vm.startPrank(bob);

        usdc.approve(address(lendingPool), 10_000 * USDC);

        lendingPool.supply(address(usdc), 10_000 * USDC);

        vm.stopPrank();
    }

    function _createBorrowPosition() internal {
        _provideUSDC();

        vm.startPrank(alice);

        weth.approve(address(lendingPool), 2 * WETH);

        lendingPool.supply(address(weth), 2 * WETH);

        lendingPool.borrow(address(usdc), 1_000 * USDC);

        vm.stopPrank();
    }

    // =============================================================
    // SUPPLY
    // =============================================================

    function test_Supply() public {
        vm.startPrank(alice);

        weth.approve(address(lendingPool), 1 * WETH);

        lendingPool.supply(address(weth), 1 * WETH);

        vm.stopPrank();

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), 1 * WETH);

        assertEq(reserveManager.getTotalSupplied(address(weth)), 1 * WETH);
    }

    function test_Withdraw() public {
        vm.startPrank(alice);

        weth.approve(address(lendingPool), 1 * WETH);

        lendingPool.supply(address(weth), 1 * WETH);

        lendingPool.withdraw(address(weth), 500_000_000_000_000_000);

        vm.stopPrank();

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), 500_000_000_000_000_000);
    }

    function test_RevertIfZeroSupply() public {
        vm.expectRevert("LendingPool: zero supply");

        lendingPool.supply(address(weth), 0);
    }

    function test_RevertIfZeroWithdraw() public {
        vm.expectRevert("LendingPool: zero withdraw");

        lendingPool.withdraw(address(weth), 0);
    }

    function test_RevertIfWithdrawTooMuch() public {
        vm.startPrank(alice);

        weth.approve(address(lendingPool), 1 * WETH);

        lendingPool.supply(address(weth), 1 * WETH);

        vm.expectRevert("LendingPool: insufficient collateral");

        lendingPool.withdraw(address(weth), 2 * WETH);

        vm.stopPrank();
    }

    // =============================================================
    // BORROW
    // =============================================================

    function test_BorrowAgainstCollateral() public {
        _provideUSDC();

        vm.startPrank(alice);

        weth.approve(address(lendingPool), 2 * WETH);

        lendingPool.supply(address(weth), 2 * WETH);

        lendingPool.borrow(address(usdc), 1_000 * USDC);

        vm.stopPrank();

        assertEq(lendingPool.getUserDebt(alice, address(usdc)), 1_000 * USDC);
    }

    function test_BorrowUSDCAgainstWETHCollateral() public {
        _provideUSDC();

        vm.startPrank(alice);

        weth.approve(address(lendingPool), 2 * WETH);

        lendingPool.supply(address(weth), 2 * WETH);

        lendingPool.borrow(address(usdc), 1_000 * USDC);

        vm.stopPrank();

        assertGt(lendingPool.getUserDebt(alice, address(usdc)), 0);
    }

    function test_RevertIfBorrowWithoutCollateral() public {
        _provideUSDC();

        vm.startPrank(alice);

        vm.expectRevert("LendingPool: borrow not allowed");

        lendingPool.borrow(address(usdc), 1_000 * USDC);

        vm.stopPrank();
    }

    function test_RevertIfBorrowExceedsCollateralFactor() public {
        _provideUSDC();

        vm.startPrank(alice);

        weth.approve(address(lendingPool), 1 * WETH);

        lendingPool.supply(address(weth), 1 * WETH);

        vm.expectRevert("LendingPool: borrow not allowed");

        lendingPool.borrow(address(usdc), 3_000 * USDC);

        vm.stopPrank();
    }

    // =============================================================
    // INTEREST
    // =============================================================

    function test_BorrowInterestAccrues() public {
        _createBorrowPosition();

        uint256 beforeDebt = lendingPool.getUserDebt(alice, address(usdc));

        vm.warp(block.timestamp + 365 days);

        uint256 afterDebt = lendingPool.getUserDebt(alice, address(usdc));

        assertGt(afterDebt, beforeDebt);
    }

    function test_SupplyInterestAccrues() public {
        _createBorrowPosition();

        uint256 beforeBalance = lendingPool.getUserCollateral(bob, address(usdc));

        vm.warp(block.timestamp + 365 days);

        uint256 afterBalance = lendingPool.getUserCollateral(bob, address(usdc));

        assertGt(afterBalance, beforeBalance);
    }

    function test_BorrowSnapshotUpdatesAfterAdditionalBorrow() public {
        _provideUSDC();

        vm.startPrank(alice);

        weth.approve(address(lendingPool), 2 * WETH);

        lendingPool.supply(address(weth), 2 * WETH);

        lendingPool.borrow(address(usdc), 500 * USDC);

        vm.warp(block.timestamp + 365 days);

        lendingPool.borrow(address(usdc), 500 * USDC);

        vm.stopPrank();

        assertGt(lendingPool.getUserDebt(alice, address(usdc)), 1_000 * USDC);
    }

    function test_SupplySnapshotUpdatesAfterAdditionalSupply() public {
        _createBorrowPosition();

        vm.warp(block.timestamp + 365 days);

        vm.startPrank(bob);

        usdc.approve(address(lendingPool), 1_000 * USDC);

        lendingPool.supply(address(usdc), 1_000 * USDC);

        vm.stopPrank();

        assertGt(lendingPool.getUserCollateral(bob, address(usdc)), 11_000 * USDC);
    }

    function test_Repay() public {
        _provideUSDC();

        vm.startPrank(alice);

        weth.approve(address(lendingPool), 2 * WETH);

        lendingPool.supply(address(weth), 2 * WETH);

        lendingPool.borrow(address(usdc), 1_000 * USDC);

        /*
         * The original USDC approval was consumed
         * when supplying USDC. Alice therefore needs
         * a new allowance for repayment.
         */
        usdc.approve(address(lendingPool), 500 * USDC);

        lendingPool.repay(address(usdc), 500 * USDC);

        vm.stopPrank();

        assertLt(lendingPool.getUserDebt(alice, address(usdc)), 1_000 * USDC);
    }

    function test_RepayAccruedDebt() public {
        _createBorrowPosition();

        vm.warp(block.timestamp + 365 days);

        uint256 debt = lendingPool.getUserDebt(alice, address(usdc));

        vm.startPrank(alice);

        usdc.mint(alice, debt);

        usdc.approve(address(lendingPool), debt);

        lendingPool.repay(address(usdc), debt);

        vm.stopPrank();

        assertEq(lendingPool.getUserDebt(alice, address(usdc)), 0);
    }

    function test_RepayMoreThanDebt() public {
        _provideUSDC();

        vm.startPrank(alice);

        weth.approve(address(lendingPool), 2 * WETH);

        lendingPool.supply(address(weth), 2 * WETH);

        lendingPool.borrow(address(usdc), 1_000 * USDC);

        usdc.approve(address(lendingPool), 2_000 * USDC);

        lendingPool.repay(address(usdc), 2_000 * USDC);

        vm.stopPrank();

        assertEq(lendingPool.getUserDebt(alice, address(usdc)), 0);
    }

    // =============================================================
    // LIQUIDATION
    // =============================================================

    function test_LiquidateUnderwaterPosition() public {
        // ---------------------------------------------------------
        // 1. Provide USDC liquidity to the pool
        // ---------------------------------------------------------
        vm.startPrank(bob);

        usdc.approve(address(lendingPool), 10_000 * USDC);

        lendingPool.supply(address(usdc), 10_000 * USDC);

        vm.stopPrank();

        // ---------------------------------------------------------
        // 2. Alice supplies WETH and borrows USDC
        // ---------------------------------------------------------
        vm.startPrank(alice);

        weth.approve(address(lendingPool), 2 * WETH);

        lendingPool.supply(address(weth), 2 * WETH);

        lendingPool.borrow(address(usdc), 1_000 * USDC);

        vm.stopPrank();

        // ---------------------------------------------------------
        // 3. WETH price crashes
        // ---------------------------------------------------------
        priceOracle.setPrice(address(weth), 500e8, 8);

        uint256 collateralBefore = lendingPool.getUserCollateral(alice, address(weth));

        // ---------------------------------------------------------
        // 4. Bob liquidates part of Alice's debt
        // ---------------------------------------------------------
        vm.startPrank(bob);

        usdc.approve(address(lendingPool), 900 * USDC);

        lendingPool.liquidate(alice, address(usdc), address(weth), 900 * USDC);

        vm.stopPrank();

        // ---------------------------------------------------------
        // 5. Verify liquidation
        // ---------------------------------------------------------
        assertEq(lendingPool.getUserDebt(alice, address(usdc)), 100 * USDC);

        assertLt(lendingPool.getUserCollateral(alice, address(weth)), collateralBefore);
    }

    function test_RevertIfLiquidateHealthyPosition() public {
        _createBorrowPosition();

        vm.startPrank(bob);

        usdc.approve(address(lendingPool), 1_000 * USDC);

        vm.expectRevert("LendingPool: position healthy");

        lendingPool.liquidate(alice, address(usdc), address(weth), 1_000 * USDC);

        vm.stopPrank();
    }

    // =============================================================
    // MULTI USER
    // =============================================================

    function test_MultipleUsers() public {
        vm.startPrank(alice);

        weth.approve(address(lendingPool), 1 * WETH);

        lendingPool.supply(address(weth), 1 * WETH);

        vm.stopPrank();

        vm.startPrank(bob);

        weth.approve(address(lendingPool), 2 * WETH);

        lendingPool.supply(address(weth), 2 * WETH);

        vm.stopPrank();

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), 1 * WETH);

        assertEq(lendingPool.getUserCollateral(bob, address(weth)), 2 * WETH);
    }

    function test_RevertIfNonOwnerSetsRiskManager() public {
        RiskManager newRiskManager =
            new RiskManager(address(reserveManager), address(priceOracle), address(lendingPool));

        vm.prank(alice);

        vm.expectRevert();
        lendingPool.setRiskManager(address(newRiskManager));
    }

    function test_RevertIfRiskManagerSetTwice() public {
        RiskManager newRiskManager =
            new RiskManager(address(reserveManager), address(priceOracle), address(lendingPool));

        vm.expectRevert("LendingPool: risk manager already set");

        lendingPool.setRiskManager(address(newRiskManager));
    }

    function test_RevertIfZeroRiskManager() public {
        vm.expectRevert("LendingPool: zero risk manager");

        lendingPool.setRiskManager(address(0));
    }

    function testFuzz_Supply(uint256 amount) public {
        amount = bound(amount, 1, 10 * WETH);

        vm.startPrank(alice);

        weth.approve(address(lendingPool), amount);

        lendingPool.supply(address(weth), amount);

        vm.stopPrank();

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), amount);
    }

    function testFuzz_Withdraw(uint256 supplyAmount, uint256 withdrawAmount) public {
        supplyAmount = bound(supplyAmount, 1, 10 * WETH);
        withdrawAmount = bound(withdrawAmount, 1, supplyAmount);

        vm.startPrank(alice);

        weth.approve(address(lendingPool), supplyAmount);

        lendingPool.supply(address(weth), supplyAmount);

        lendingPool.withdraw(address(weth), withdrawAmount);

        vm.stopPrank();

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), supplyAmount - withdrawAmount);
    }

    function testFuzz_Borrow(uint256 borrowAmount) public {
        borrowAmount = bound(borrowAmount, 1 * USDC, 4_000 * USDC);

        _provideUSDC();

        vm.startPrank(alice);

        weth.approve(address(lendingPool), 2 * WETH);

        lendingPool.supply(address(weth), 2 * WETH);

        lendingPool.borrow(address(usdc), borrowAmount);

        vm.stopPrank();

        assertEq(lendingPool.getUserDebt(alice, address(usdc)), borrowAmount);
    }

    function testFuzz_Repay(uint256 repayAmount) public {
        repayAmount = bound(repayAmount, 1 * USDC, 1_000 * USDC);

        _createBorrowPosition();

        vm.startPrank(alice);

        usdc.mint(alice, repayAmount);

        usdc.approve(address(lendingPool), repayAmount);

        lendingPool.repay(address(usdc), repayAmount);

        vm.stopPrank();

        assertLe(lendingPool.getUserDebt(alice, address(usdc)), 1_000 * USDC);
    }

    function testFuzz_BorrowInterestAccrues(uint256 elapsedTime) public {
        elapsedTime = bound(elapsedTime, 1 days, 365 days);

        _createBorrowPosition();

        uint256 beforeDebt = lendingPool.getUserDebt(alice, address(usdc));

        vm.warp(block.timestamp + elapsedTime);

        uint256 afterDebt = lendingPool.getUserDebt(alice, address(usdc));

        assertGt(afterDebt, beforeDebt);
    }

    function testFuzz_LiquidationPrice(uint256 wethPrice) public pure {
        wethPrice = bound(wethPrice, 1e8, 3_000e8);

        // create position
        // change oracle price
        // calculate health factor
        // verify liquidation behavior
    }

    function testFuzz_BorrowWithinCollateralFactor(uint256 borrowAmount) public {
        borrowAmount = bound(borrowAmount, 1 * USDC, 4_800 * USDC);

        _provideUSDC();

        vm.startPrank(alice);

        weth.approve(address(lendingPool), 2 * WETH);

        lendingPool.supply(address(weth), 2 * WETH);

        lendingPool.borrow(address(usdc), borrowAmount);

        vm.stopPrank();

        assertEq(lendingPool.getUserDebt(alice, address(usdc)), borrowAmount);
    }

    function testFuzz_BorrowInterestIsMonotonic(uint256 firstPeriod, uint256 secondPeriod) public {
        firstPeriod = bound(firstPeriod, 1 days, 180 days);
        secondPeriod = bound(secondPeriod, 1 days, 180 days);

        _createBorrowPosition();

        uint256 initialDebt = lendingPool.getUserDebt(alice, address(usdc));

        vm.warp(block.timestamp + firstPeriod);

        uint256 firstDebt = lendingPool.getUserDebt(alice, address(usdc));

        vm.warp(block.timestamp + secondPeriod);

        uint256 secondDebt = lendingPool.getUserDebt(alice, address(usdc));

        assertGe(firstDebt, initialDebt);
        assertGe(secondDebt, firstDebt);
    }
}
