// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {ReserveTypes} from "../../src/libraries/ReserveTypes.sol";

contract ReserveManagerTest is Test {
    ReserveManager manager;

    address weth = makeAddr("weth");
    address usdc = makeAddr("usdc");

    address alice = makeAddr("alice");

    function setUp() public {
        manager = new ReserveManager();
    }

    function test_ConfigureWETH() public {
        manager.configureReserve(weth, 18, 8_000, 8_500, 500);

        assertTrue(manager.isActive(weth));
        assertTrue(manager.isBorrowEnabled(weth));

        assertEq(manager.getDecimals(weth), 18);

        assertEq(manager.getCollateralFactor(weth), 8_000);

        assertEq(manager.getLiquidationThreshold(weth), 8_500);

        assertEq(manager.getLiquidationBonus(weth), 500);
    }

    function test_ConfigureUSDC() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        assertTrue(manager.isActive(usdc));

        assertEq(manager.getDecimals(usdc), 6);
    }

    function test_BorrowIndexStartsAtOne() public {
        manager.configureReserve(weth, 18, 8_000, 8_500, 500);

        assertEq(manager.getBorrowIndex(weth), 1e18);
    }

    function test_SupplyIndexStartsAtOne() public {
        manager.configureReserve(weth, 18, 8_000, 8_500, 500);

        assertEq(manager.getSupplyIndex(weth), 1e18);
    }

    function test_SetReserveStatus() public {
        manager.configureReserve(weth, 18, 8_000, 8_500, 500);

        manager.setReserveStatus(weth, true, false);

        assertTrue(manager.isActive(weth));
        assertFalse(manager.isBorrowEnabled(weth));
    }

    function test_RevertIfCollateralFactorTooHigh() public {
        vm.expectRevert("Reserve: invalid collateral factor");

        manager.configureReserve(weth, 18, 10_001, 8_500, 500);
    }

    function test_RevertIfThresholdBelowCollateral() public {
        vm.expectRevert("Reserve: threshold below collateral");

        manager.configureReserve(weth, 18, 8_500, 8_000, 500);
    }

    function test_RevertIfNotConfigured() public {
        vm.expectRevert("Reserve: not configured");

        manager.setReserveStatus(weth, false, false);
    }

    function test_RevertIfNotOwner() public {
        vm.prank(alice);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));

        manager.configureReserve(weth, 18, 8_000, 8_500, 500);
    }

    function test_AccrueInterestForOneYear() public {
        // Configure the reserve
        manager.configureReserve(address(usdc), 6, 8_000, 8_500, 1_000);

        // Deploy and configure the interest rate model
        InterestRateModel model = new InterestRateModel();

        manager.setInterestRateModel(address(usdc), address(model));

        // We need LendingPool authorization because the reserve
        // accounting functions are protected.
        manager.setLendingPool(address(this));

        // Simulate 1,000 supplied and 500 borrowed.
        manager.increaseTotalSupplied(address(usdc), 1_000);
        manager.increaseTotalBorrowed(address(usdc), 500);

        // Move time forward by one year.
        vm.warp(block.timestamp + 365 days);

        manager.accrueInterest(address(usdc));

        uint256 borrowIndex = manager.getBorrowIndex(address(usdc));
        uint256 supplyIndex = manager.getSupplyIndex(address(usdc));

        assertEq(borrowIndex, 1.07e18);
        assertEq(supplyIndex, 1.035e18);
    }

    function test_AccrueInterestWithZeroElapsedTime() public {
        manager.configureReserve(address(usdc), 6, 8_000, 8_500, 1_000);

        InterestRateModel model = new InterestRateModel();

        manager.setInterestRateModel(address(usdc), address(model));

        manager.setLendingPool(address(this));

        manager.increaseTotalSupplied(address(usdc), 1_000);
        manager.increaseTotalBorrowed(address(usdc), 500);

        uint256 initialBorrowIndex = manager.getBorrowIndex(address(usdc));

        uint256 initialSupplyIndex = manager.getSupplyIndex(address(usdc));

        // No time passes.
        manager.accrueInterest(address(usdc));

        uint256 finalBorrowIndex = manager.getBorrowIndex(address(usdc));

        uint256 finalSupplyIndex = manager.getSupplyIndex(address(usdc));

        assertEq(finalBorrowIndex, initialBorrowIndex);
        assertEq(finalSupplyIndex, initialSupplyIndex);
    }

    function test_AccrueInterestForSixMonths() public {
        manager.configureReserve(address(usdc), 6, 8_000, 8_500, 1_000);

        InterestRateModel model = new InterestRateModel();

        manager.setInterestRateModel(address(usdc), address(model));

        manager.setLendingPool(address(this));

        manager.increaseTotalSupplied(address(usdc), 1_000);
        manager.increaseTotalBorrowed(address(usdc), 500);

        vm.warp(block.timestamp + 182 days);

        manager.accrueInterest(address(usdc));

        uint256 borrowIndex = manager.getBorrowIndex(address(usdc));

        uint256 supplyIndex = manager.getSupplyIndex(address(usdc));

        assertEq(borrowIndex, 1.034904109589041095e18);
        assertEq(supplyIndex, 1.017452054794520547e18);
    }

    function test_AccrueInterestMultipleTimes() public {
        manager.configureReserve(address(usdc), 6, 8_000, 8_500, 1_000);

        InterestRateModel model = new InterestRateModel();

        manager.setInterestRateModel(address(usdc), address(model));

        manager.setLendingPool(address(this));

        manager.increaseTotalSupplied(address(usdc), 1_000);
        manager.increaseTotalBorrowed(address(usdc), 500);

        vm.warp(block.timestamp + 182 days);
        manager.accrueInterest(address(usdc));

        uint256 firstBorrowIndex = manager.getBorrowIndex(address(usdc));

        uint256 firstSupplyIndex = manager.getSupplyIndex(address(usdc));

        vm.warp(block.timestamp + 182 days);
        manager.accrueInterest(address(usdc));

        uint256 secondBorrowIndex = manager.getBorrowIndex(address(usdc));

        uint256 secondSupplyIndex = manager.getSupplyIndex(address(usdc));

        assertGt(secondBorrowIndex, firstBorrowIndex);
        assertGt(secondSupplyIndex, firstSupplyIndex);
    }

    function test_AccrueInterestUpdatesTimestamp() public {
        manager.configureReserve(address(usdc), 6, 8_000, 8_500, 1_000);

        InterestRateModel model = new InterestRateModel();

        manager.setInterestRateModel(address(usdc), address(model));

        manager.setLendingPool(address(this));

        manager.increaseTotalSupplied(address(usdc), 1_000);
        manager.increaseTotalBorrowed(address(usdc), 500);

        uint256 initialTimestamp = block.timestamp;

        vm.warp(block.timestamp + 182 days);

        manager.accrueInterest(address(usdc));

        ReserveTypes.Reserve memory reserve = manager.getReserve(address(usdc));

        assertEq(reserve.lastUpdateTimestamp, initialTimestamp + 182 days);
    }

    function test_AccrueInterestWithNoBorrowing() public {
        manager.configureReserve(address(usdc), 6, 8_000, 8_500, 1_000);

        InterestRateModel model = new InterestRateModel();

        manager.setInterestRateModel(address(usdc), address(model));

        manager.setLendingPool(address(this));

        manager.increaseTotalSupplied(address(usdc), 1_000);

        uint256 initialSupplyIndex = manager.getSupplyIndex(address(usdc));

        vm.warp(block.timestamp + 182 days);

        manager.accrueInterest(address(usdc));

        uint256 finalSupplyIndex = manager.getSupplyIndex(address(usdc));

        assertEq(finalSupplyIndex, initialSupplyIndex);
    }

    function test_AccrueInterestWithNoSupply() public {
        manager.configureReserve(address(usdc), 6, 8_000, 8_500, 1_000);

        InterestRateModel model = new InterestRateModel();

        manager.setInterestRateModel(address(usdc), address(model));

        manager.setLendingPool(address(this));

        manager.increaseTotalBorrowed(address(usdc), 500);

        uint256 initialBorrowIndex = manager.getBorrowIndex(address(usdc));

        vm.warp(block.timestamp + 182 days);

        manager.accrueInterest(address(usdc));

        uint256 finalBorrowIndex = manager.getBorrowIndex(address(usdc));

        assertGt(finalBorrowIndex, initialBorrowIndex);
    }

    function test_AccrueInterestWithZeroUtilization() public {
        manager.configureReserve(address(usdc), 6, 8_000, 8_500, 1_000);

        InterestRateModel model = new InterestRateModel();

        manager.setInterestRateModel(address(usdc), address(model));

        manager.setLendingPool(address(this));

        manager.increaseTotalSupplied(address(usdc), 1_000);

        uint256 initialBorrowIndex = manager.getBorrowIndex(address(usdc));

        uint256 initialSupplyIndex = manager.getSupplyIndex(address(usdc));

        vm.warp(block.timestamp + 365 days);

        manager.accrueInterest(address(usdc));

        uint256 finalBorrowIndex = manager.getBorrowIndex(address(usdc));

        uint256 finalSupplyIndex = manager.getSupplyIndex(address(usdc));

        assertGt(finalBorrowIndex, initialBorrowIndex);
        assertEq(finalSupplyIndex, initialSupplyIndex);
    }
}
