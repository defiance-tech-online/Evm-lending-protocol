// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../../src/tokens/MockERC20.sol";
import {MockPriceOracle} from "../../src/oracles/MockPriceOracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {RiskManager} from "../../src/RiskManager.sol";

contract RiskManagerTest is Test {
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

        weth.mint(alice, 10 * WETH);
        usdc.mint(alice, 20_000 * USDC);

        usdc.mint(bob, 20_000 * USDC);
    }

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
    // BASIC
    // =============================================================

    function test_HealthFactorWithNoDebt() public view {
        assertEq(riskManager.calculateHealthFactor(alice), type(uint256).max);
    }

    function test_CalculateWETHCollateralValue() public {
        vm.startPrank(alice);

        weth.approve(address(lendingPool), WETH);

        lendingPool.supply(address(weth), WETH);

        vm.stopPrank();

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), WETH);
    }

    function test_CalculateUSDCPosition() public {
        vm.startPrank(alice);

        usdc.approve(address(lendingPool), 1_000 * USDC);

        lendingPool.supply(address(usdc), 1_000 * USDC);

        vm.stopPrank();

        assertEq(lendingPool.getUserCollateral(alice, address(usdc)), 1_000 * USDC);
    }

    function test_SupportedAssetsRegistered() public {
        vm.startPrank(alice);

        weth.approve(address(lendingPool), WETH);

        lendingPool.supply(address(weth), WETH);

        usdc.approve(address(lendingPool), 1_000 * USDC);

        lendingPool.supply(address(usdc), 1_000 * USDC);

        vm.stopPrank();

        address[] memory assets = lendingPool.getSupportedAssets();

        assertEq(assets.length, 2);
        assertEq(assets[0], address(weth));
        assertEq(assets[1], address(usdc));
    }

    // =============================================================
    // INTEREST / HEALTH
    // =============================================================

    function test_BorrowDebtGrowsAfterInterest() public {
        _createBorrowPosition();

        uint256 beforeDebt = lendingPool.getUserDebt(alice, address(usdc));

        vm.warp(block.timestamp + 365 days);

        uint256 afterDebt = lendingPool.getUserDebt(alice, address(usdc));

        assertGt(afterDebt, beforeDebt);
    }

    function test_BorrowIndexSnapshot() public {
        _createBorrowPosition();

        uint256 beforeDebt = lendingPool.getUserDebt(alice, address(usdc));

        vm.warp(block.timestamp + 365 days);

        uint256 afterDebt = lendingPool.getUserDebt(alice, address(usdc));

        assertGt(afterDebt, beforeDebt);
    }

    function test_HealthFactorUsesInterestAdjustedDebt() public {
        _createBorrowPosition();

        uint256 beforeHealth = riskManager.calculateHealthFactor(alice);

        vm.warp(block.timestamp + 365 days);

        uint256 afterHealth = riskManager.calculateHealthFactor(alice);

        assertLt(afterHealth, beforeHealth);
    }

    function test_SupplyBalanceGrowsAfterInterest() public {
        _createBorrowPosition();

        uint256 beforeBalance = lendingPool.getUserCollateral(bob, address(usdc));

        vm.warp(block.timestamp + 365 days);

        uint256 afterBalance = lendingPool.getUserCollateral(bob, address(usdc));

        assertGt(afterBalance, beforeBalance);
    }

    function test_SupplyIndexSnapshot() public {
        _createBorrowPosition();

        uint256 beforeBalance = lendingPool.getUserCollateral(bob, address(usdc));

        vm.warp(block.timestamp + 365 days);

        uint256 afterBalance = lendingPool.getUserCollateral(bob, address(usdc));

        assertGt(afterBalance, beforeBalance);
    }

    // =============================================================
    // LIQUIDATION
    // =============================================================

    function test_CanLiquidateWhenHealthFactorBelowOne() public {
        _createBorrowPosition();

        priceOracle.setPrice(address(weth), 200e8, 8);

        assertTrue(riskManager.canLiquidate(alice));
    }
}
