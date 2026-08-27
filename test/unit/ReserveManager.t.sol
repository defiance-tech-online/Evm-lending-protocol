// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {ReserveTypes} from "../../src/libraries/ReserveTypes.sol";
import {IInterestRateModel} from "../../src/interfaces/IInterestRateModel.sol";

contract MockInterestRateModel is IInterestRateModel {
    uint256 public borrowRate;
    uint256 public supplyRate;

    constructor(uint256 borrowRate_, uint256 supplyRate_) {
        borrowRate = borrowRate_;
        supplyRate = supplyRate_;
    }

    function getBorrowRate(uint256, uint256) external view override returns (uint256) {
        return borrowRate;
    }

    function getSupplyRate(uint256, uint256) external view override returns (uint256) {
        return supplyRate;
    }
}

contract ReserveManagerTest is Test {
    ReserveManager manager;

    address weth = makeAddr("weth");
    address usdc = makeAddr("usdc");

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        manager = new ReserveManager();
    }

    // =============================================================
    // RESERVE CONFIGURATION
    // =============================================================

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

    function test_RevertIfThresholdTooHigh() public {
        vm.expectRevert("Reserve: invalid liquidation threshold");

        manager.configureReserve(weth, 18, 8_000, 10_001, 500);
    }

    function test_RevertIfLiquidationBonusTooHigh() public {
        vm.expectRevert("Reserve: invalid liquidation bonus");

        manager.configureReserve(weth, 18, 8_000, 8_500, 10_001);
    }

    function test_RevertIfConfigureZeroAddress() public {
        vm.expectRevert("Reserve: zero asset");

        manager.configureReserve(address(0), 18, 8_000, 8_500, 500);
    }

    function test_RevertIfConfigureReserveTwice() public {
        manager.configureReserve(usdc, 6, 7_500, 8_000, 500);

        vm.expectRevert("Reserve: already configured");

        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);
    }

    function test_RevertIfNotConfigured() public {
        vm.expectRevert("Reserve: not configured");

        manager.setReserveStatus(weth, false, false);
    }

    function test_RevertIfConfigureReserveNotOwner() public {
        vm.prank(alice);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));

        manager.configureReserve(weth, 18, 8_000, 8_500, 500);
    }

    function test_RevertIfSetReserveStatusNotOwner() public {
        manager.configureReserve(weth, 18, 8_000, 8_500, 500);

        vm.prank(alice);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));

        manager.setReserveStatus(weth, false, false);
    }

    // =============================================================
    // LENDING POOL CONFIGURATION
    // =============================================================

    function test_SetLendingPool() public {
        address lendingPool = makeAddr("lendingPool");

        manager.setLendingPool(lendingPool);

        assertEq(manager.lendingPool(), lendingPool);
    }

    function test_RevertIfLendingPoolZeroAddress() public {
        vm.expectRevert("Reserve: zero lending pool");

        manager.setLendingPool(address(0));
    }

    function test_RevertIfLendingPoolSetTwice() public {
        address firstLendingPool = makeAddr("firstLendingPool");
        address secondLendingPool = makeAddr("secondLendingPool");

        manager.setLendingPool(firstLendingPool);

        vm.expectRevert("Reserve: lending pool already set");

        manager.setLendingPool(secondLendingPool);
    }

    function test_RevertIfLendingPoolSetNotOwner() public {
        vm.prank(alice);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));

        manager.setLendingPool(address(this));
    }

    // =============================================================
    // INTEREST RATE MODEL MANAGEMENT
    // =============================================================

    function test_SetInterestRateModel() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        InterestRateModel model = new InterestRateModel();

        manager.setInterestRateModel(usdc, address(model));

        assertEq(manager.getInterestRateModel(usdc), address(model));
    }

    function test_RevertIfInterestRateModelZeroAddress() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        vm.expectRevert("Reserve: zero model");

        manager.setInterestRateModel(usdc, address(0));
    }

    function test_RevertIfInterestRateModelAssetZeroAddress() public {
        InterestRateModel model = new InterestRateModel();

        vm.expectRevert("Reserve: zero asset");

        manager.setInterestRateModel(address(0), address(model));
    }

    function test_RevertIfInterestRateModelUnconfiguredReserve() public {
        InterestRateModel model = new InterestRateModel();

        vm.expectRevert("Reserve: not configured");

        manager.setInterestRateModel(usdc, address(model));
    }

    function test_RevertIfInterestRateModelNotOwner() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        InterestRateModel model = new InterestRateModel();

        vm.prank(alice);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));

        manager.setInterestRateModel(usdc, address(model));
    }

    function test_RevertIfSameInterestRateModel() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        InterestRateModel model = new InterestRateModel();

        manager.setInterestRateModel(usdc, address(model));

        vm.expectRevert("Reserve: same interest rate model");

        manager.setInterestRateModel(usdc, address(model));
    }

    function test_InterestRateModelChangeAccruesOldModelFirst() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        MockInterestRateModel oldModel = new MockInterestRateModel(1_000, 500);

        MockInterestRateModel newModel = new MockInterestRateModel(2_000, 1_000);

        manager.setInterestRateModel(usdc, address(oldModel));

        manager.setLendingPool(address(this));

        manager.increaseTotalSupplied(usdc, 1_000);

        manager.increaseTotalBorrowed(usdc, 500);

        uint256 initialBorrowIndex = manager.getBorrowIndex(usdc);

        uint256 initialSupplyIndex = manager.getSupplyIndex(usdc);

        vm.warp(block.timestamp + 365 days);

        manager.setInterestRateModel(usdc, address(newModel));

        uint256 borrowIndexAfterChange = manager.getBorrowIndex(usdc);

        uint256 supplyIndexAfterChange = manager.getSupplyIndex(usdc);

        assertEq(borrowIndexAfterChange, 1.1e18);

        assertEq(supplyIndexAfterChange, 1.05e18);

        assertGt(borrowIndexAfterChange, initialBorrowIndex);

        assertGt(supplyIndexAfterChange, initialSupplyIndex);

        assertEq(manager.getInterestRateModel(usdc), address(newModel));
    }

    // =============================================================
    // LENDING POOL ACCESS CONTROL
    // =============================================================

    function test_RevertIfIncreaseSupplyNotLendingPool() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        vm.expectRevert("Reserve: unauthorized");

        manager.increaseTotalSupplied(usdc, 1_000);
    }

    function test_RevertIfDecreaseSupplyNotLendingPool() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        vm.expectRevert("Reserve: unauthorized");

        manager.decreaseTotalSupplied(usdc, 1_000);
    }

    function test_RevertIfDecreaseScaledSupplyNotLendingPool() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        vm.expectRevert("Reserve: unauthorized");

        manager.decreaseTotalScaledSupplied(usdc, 1);
    }

    function test_RevertIfIncreaseBorrowNotLendingPool() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        vm.expectRevert("Reserve: unauthorized");

        manager.increaseTotalBorrowed(usdc, 1_000);
    }

    function test_RevertIfDecreaseBorrowNotLendingPool() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        vm.expectRevert("Reserve: unauthorized");

        manager.decreaseTotalBorrowed(usdc, 1_000);
    }

    function test_RevertIfDecreaseScaledBorrowNotLendingPool() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        vm.expectRevert("Reserve: unauthorized");

        manager.decreaseTotalScaledBorrowed(usdc, 1);
    }

    // =============================================================
    // SCALED ACCOUNTING EDGE CASES
    // =============================================================

    function test_RevertIfIncreaseSupplyZeroAmount() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        manager.setLendingPool(address(this));

        vm.expectRevert("Reserve: zero amount");

        manager.increaseTotalSupplied(usdc, 0);
    }

    function test_RevertIfIncreaseBorrowZeroAmount() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        manager.setLendingPool(address(this));

        vm.expectRevert("Reserve: zero amount");

        manager.increaseTotalBorrowed(usdc, 0);
    }

    function test_RevertIfDecreaseSupplyZeroAmount() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        manager.setLendingPool(address(this));

        vm.expectRevert("Reserve: zero amount");

        manager.decreaseTotalSupplied(usdc, 0);
    }

    function test_RevertIfDecreaseBorrowZeroAmount() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        manager.setLendingPool(address(this));

        vm.expectRevert("Reserve: zero amount");

        manager.decreaseTotalBorrowed(usdc, 0);
    }

    function test_RevertIfDecreaseScaledSupplyZeroAmount() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        manager.setLendingPool(address(this));

        vm.expectRevert("Reserve: zero amount");

        manager.decreaseTotalScaledSupplied(usdc, 0);
    }

    function test_RevertIfDecreaseScaledBorrowZeroAmount() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        manager.setLendingPool(address(this));

        vm.expectRevert("Reserve: zero amount");

        manager.decreaseTotalScaledBorrowed(usdc, 0);
    }

    function test_RevertIfWithdrawMoreThanScaledSupply() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        manager.setLendingPool(address(this));

        manager.increaseTotalSupplied(usdc, 1_000);

        vm.expectRevert("Reserve: insufficient supply");

        manager.decreaseTotalSupplied(usdc, 2_000);
    }

    function test_RevertIfRepayMoreThanScaledBorrow() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        manager.setLendingPool(address(this));

        manager.increaseTotalBorrowed(usdc, 1_000);

        vm.expectRevert("Reserve: insufficient borrow");

        manager.decreaseTotalBorrowed(usdc, 2_000);
    }

    // =============================================================
    // INTEREST ACCRUAL
    // =============================================================

    function test_AccrueInterestForOneYear() public {
        manager.configureReserve(address(usdc), 6, 8_000, 8_500, 1_000);

        InterestRateModel model = new InterestRateModel();

        manager.setInterestRateModel(address(usdc), address(model));

        manager.setLendingPool(address(this));

        manager.increaseTotalSupplied(address(usdc), 1_000);

        manager.increaseTotalBorrowed(address(usdc), 500);

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

        manager.accrueInterest(address(usdc));

        assertEq(manager.getBorrowIndex(address(usdc)), initialBorrowIndex);

        assertEq(manager.getSupplyIndex(address(usdc)), initialSupplyIndex);
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

    function test_RevertIfAccrueInterestUnconfigured() public {
        vm.expectRevert("Reserve: not configured");

        manager.accrueInterest(usdc);
    }

    function test_RevertIfAccrueInterestWithoutModel() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        vm.warp(block.timestamp + 365 days);

        vm.expectRevert("Reserve: model not set");

        manager.accrueInterest(usdc);
    }

    // =============================================================
    // INDEX PREVIEW
    // =============================================================

    function test_CurrentIndexPreviewMatchesAccruedIndex() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        InterestRateModel model = new InterestRateModel();

        manager.setInterestRateModel(usdc, address(model));

        manager.setLendingPool(address(this));

        manager.increaseTotalSupplied(usdc, 1_000);

        manager.increaseTotalBorrowed(usdc, 500);

        vm.warp(block.timestamp + 365 days);

        uint256 previewBorrowIndex = manager.getCurrentBorrowIndex(usdc);

        uint256 previewSupplyIndex = manager.getCurrentSupplyIndex(usdc);

        manager.accrueInterest(usdc);

        uint256 accruedBorrowIndex = manager.getBorrowIndex(usdc);

        uint256 accruedSupplyIndex = manager.getSupplyIndex(usdc);

        assertEq(previewBorrowIndex, accruedBorrowIndex);

        assertEq(previewSupplyIndex, accruedSupplyIndex);
    }

    // =============================================================
    // TOTAL ACCOUNTING
    // =============================================================

    function test_TotalScaledSupplyAccounting() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        manager.setLendingPool(address(this));

        manager.increaseTotalSupplied(usdc, 1_000e6);

        assertEq(manager.getTotalScaledSupplied(usdc), 1_000e6);

        assertEq(manager.getTotalSupplied(usdc), 1_000e6);
    }

    function test_TotalScaledBorrowAccounting() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        manager.setLendingPool(address(this));

        manager.increaseTotalBorrowed(usdc, 500e6);

        assertEq(manager.getTotalScaledBorrowed(usdc), 500e6);

        assertEq(manager.getTotalBorrowed(usdc), 500e6);
    }

    function test_FullScaledSupplyReduction() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        manager.setLendingPool(address(this));

        manager.increaseTotalSupplied(usdc, 1_000e6);

        manager.decreaseTotalScaledSupplied(usdc, 1_000e6);

        assertEq(manager.getTotalScaledSupplied(usdc), 0);

        assertEq(manager.getTotalSupplied(usdc), 0);
    }

    function test_FullScaledBorrowReduction() public {
        manager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        manager.setLendingPool(address(this));

        manager.increaseTotalBorrowed(usdc, 1_000e6);

        manager.decreaseTotalScaledBorrowed(usdc, 1_000e6);

        assertEq(manager.getTotalScaledBorrowed(usdc), 0);

        assertEq(manager.getTotalBorrowed(usdc), 0);
    }
}
