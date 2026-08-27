// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../../src/tokens/MockERC20.sol";
import {MockPriceOracle} from "../../src/oracles/MockPriceOracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {RiskManager} from "../../src/RiskManager.sol";

contract LendingPoolFuzzTest is Test {
    MockERC20 weth;
    MockERC20 usdc;

    MockPriceOracle priceOracle;
    InterestRateModel interestRateModel;

    ReserveManager reserveManager;
    LendingPool lendingPool;
    RiskManager riskManager;

    address alice = makeAddr("alice");

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

        lendingPool = new LendingPool(address(reserveManager));

        reserveManager.setLendingPool(address(lendingPool));

        reserveManager.setInterestRateModel(address(weth), address(interestRateModel));

        reserveManager.setInterestRateModel(address(usdc), address(interestRateModel));

        riskManager = new RiskManager(address(reserveManager), address(priceOracle), address(lendingPool));

        lendingPool.setRiskManager(address(riskManager));

        priceOracle.setPrice(address(weth), 3000e8, 8);
        priceOracle.setPrice(address(usdc), 1e8, 8);

        weth.mint(alice, 20 * WETH);
        usdc.mint(alice, 20_000 * USDC);
    }

    // =============================================================
    // SUPPLY FUZZ TESTS
    // =============================================================

    function testFuzz_Supply(uint256 amount) public {
        amount = bound(amount, 1, 20 * WETH);

        vm.startPrank(alice);

        weth.approve(address(lendingPool), amount);

        lendingPool.supply(address(weth), amount);

        vm.stopPrank();

        uint256 collateral = lendingPool.getUserCollateral(alice, address(weth));

        assertGt(collateral, 0);
        assertLe(collateral, amount + 1);
    }

    // =============================================================
    // WITHDRAW FUZZ TESTS
    // =============================================================

    function testFuzz_SupplyThenWithdraw(uint256 supplyAmount, uint256 withdrawAmount) public {
        supplyAmount = bound(supplyAmount, 1, 20 * WETH);

        vm.startPrank(alice);

        weth.approve(address(lendingPool), supplyAmount);

        lendingPool.supply(address(weth), supplyAmount);

        uint256 collateral = lendingPool.getUserCollateral(alice, address(weth));

        withdrawAmount = bound(withdrawAmount, 1, collateral);

        lendingPool.withdraw(address(weth), withdrawAmount);

        vm.stopPrank();

        uint256 remaining = lendingPool.getUserCollateral(alice, address(weth));

        assertLe(remaining, supplyAmount);
    }

    // =============================================================
    // BORROW FUZZ TESTS
    // =============================================================

    function testFuzz_BorrowWithinCollateral(uint256 collateralAmount, uint256 borrowAmount) public {
        collateralAmount = bound(collateralAmount, 1 ether, 10 ether);

        // Keep enough USDC available as pool liquidity.
        uint256 liquidity = 20_000e6;

        // Alice supplies WETH collateral.
        weth.mint(alice, collateralAmount);

        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateralAmount);

        lendingPool.supply(address(weth), collateralAmount);

        vm.stopPrank();

        // A lender provides USDC liquidity.
        usdc.mint(address(this), liquidity);

        usdc.approve(address(lendingPool), liquidity);

        lendingPool.supply(address(usdc), liquidity);

        /*
         * WETH = $3,000
         *
         * collateral value:
         *
         * collateralAmount * 3000 USD
         *
         * 80% collateral factor.
         */
        uint256 collateralValue = (collateralAmount * 3000e8) / 1e18;

        uint256 maxBorrowUsd = (collateralValue * 8_000) / 10_000;

        // USD has 8 decimals, USDC has 6.
        uint256 maxBorrow = maxBorrowUsd / 1e2;

        uint256 poolLiquidity = usdc.balanceOf(address(lendingPool));

        if (maxBorrow > poolLiquidity) {
            maxBorrow = poolLiquidity;
        }

        if (maxBorrow == 0) {
            return;
        }

        borrowAmount = bound(borrowAmount, 1, maxBorrow);

        vm.prank(alice);

        lendingPool.borrow(address(usdc), borrowAmount);

        uint256 debt = lendingPool.getUserDebt(alice, address(usdc));

        assertGe(debt, borrowAmount);
    }

    // =============================================================
    // REPAY FUZZ TESTS
    // =============================================================

    function testFuzz_BorrowThenRepay(uint256 collateralAmount, uint256 borrowAmount, uint256 repayAmount) public {
        collateralAmount = bound(collateralAmount, 1 ether, 10 ether);

        uint256 liquidity = 20_000e6;

        // =========================================================
        // SUPPLY WETH COLLATERAL
        // =========================================================

        weth.mint(alice, collateralAmount);

        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateralAmount);

        lendingPool.supply(address(weth), collateralAmount);

        vm.stopPrank();

        // =========================================================
        // SUPPLY USDC LIQUIDITY
        // =========================================================

        usdc.mint(address(this), liquidity);

        usdc.approve(address(lendingPool), liquidity);

        lendingPool.supply(address(usdc), liquidity);

        // =========================================================
        // CALCULATE MAX BORROW
        // =========================================================

        uint256 collateralValue = (collateralAmount * 3000e8) / 1e18;

        uint256 maxBorrowUsd = (collateralValue * 8_000) / 10_000;

        uint256 maxBorrow = maxBorrowUsd / 1e2;

        uint256 poolLiquidity = usdc.balanceOf(address(lendingPool));

        if (maxBorrow > poolLiquidity) {
            maxBorrow = poolLiquidity;
        }

        if (maxBorrow == 0) {
            return;
        }

        borrowAmount = bound(borrowAmount, 1, maxBorrow);

        // =========================================================
        // BORROW
        // =========================================================

        vm.prank(alice);

        lendingPool.borrow(address(usdc), borrowAmount);

        uint256 debtBefore = lendingPool.getUserDebt(alice, address(usdc));

        assertGe(debtBefore, borrowAmount);

        // =========================================================
        // REPAY
        // =========================================================

        uint256 aliceBalance = usdc.balanceOf(alice);

        if (aliceBalance == 0) {
            return;
        }

        repayAmount = bound(repayAmount, 1, debtBefore < aliceBalance ? debtBefore : aliceBalance);

        vm.startPrank(alice);

        usdc.approve(address(lendingPool), repayAmount);

        lendingPool.repay(address(usdc), repayAmount);

        vm.stopPrank();

        uint256 debtAfter = lendingPool.getUserDebt(alice, address(usdc));

        assertLt(debtAfter, debtBefore);
    }

    // =============================================================
    // INTEREST ACCRUAL FUZZ TEST
    // =============================================================

    function testFuzz_AccrualDoesNotDecreaseBorrowIndex(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 365 days);

        vm.startPrank(alice);

        weth.approve(address(lendingPool), 1 * WETH);

        lendingPool.supply(address(weth), 1 * WETH);

        vm.stopPrank();

        usdc.mint(address(lendingPool), 500 * USDC);

        vm.prank(alice);

        lendingPool.borrow(address(usdc), 100 * USDC);

        uint256 beforeIndex = reserveManager.getBorrowIndex(address(usdc));

        vm.warp(block.timestamp + elapsed);

        reserveManager.accrueInterest(address(usdc));

        uint256 afterIndex = reserveManager.getBorrowIndex(address(usdc));

        assertGe(afterIndex, beforeIndex);
    }

    // =============================================================
    // POSITION CONSISTENCY
    // =============================================================

    function testFuzz_ScaledPositionProducesValidBalance(uint256 amount) public {
        amount = bound(amount, 1, 20 * USDC);

        vm.startPrank(alice);

        usdc.approve(address(lendingPool), amount);

        lendingPool.supply(address(usdc), amount);

        vm.stopPrank();

        (uint256 scaledSupply, uint256 scaledBorrow) = lendingPool.getUserScaledPosition(alice, address(usdc));

        uint256 actualSupply = lendingPool.getUserCollateral(alice, address(usdc));

        uint256 actualDebt = lendingPool.getUserDebt(alice, address(usdc));

        assertGt(scaledSupply, 0);
        assertEq(scaledBorrow, 0);

        assertGt(actualSupply, 0);
        assertEq(actualDebt, 0);
    }
}
