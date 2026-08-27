// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../../src/tokens/MockERC20.sol";
import {MockPriceOracle} from "../../src/oracles/MockPriceOracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {RiskManager} from "../../src/RiskManager.sol";

contract LendingPoolSecurityTest is Test {
    MockERC20 weth;
    MockERC20 usdc;

    MockPriceOracle priceOracle;
    InterestRateModel interestRateModel;

    ReserveManager reserveManager;
    LendingPool lendingPool;
    RiskManager riskManager;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    uint256 constant WETH = 1e18;
    uint256 constant USDC = 1e6;

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

        reserveManager.setInterestRateModel(address(weth), address(interestRateModel));

        reserveManager.setInterestRateModel(address(usdc), address(interestRateModel));

        // =========================================================
        // RISK MANAGER
        // =========================================================

        riskManager = new RiskManager(address(reserveManager), address(priceOracle), address(lendingPool));

        lendingPool.setRiskManager(address(riskManager));

        // =========================================================
        // ORACLE
        // =========================================================

        priceOracle.setPrice(address(weth), 3000e8, 8);
        priceOracle.setPrice(address(usdc), 1e8, 8);

        // =========================================================
        // INITIAL BALANCES
        // =========================================================

        weth.mint(alice, 20 * WETH);
        weth.mint(bob, 20 * WETH);

        usdc.mint(alice, 20_000 * USDC);
        usdc.mint(bob, 20_000 * USDC);

        usdc.mint(address(this), 100_000 * USDC);
    }

    // =============================================================
    // RESERVE MANAGER ACCESS CONTROL
    // =============================================================

    function test_RevertUnauthorizedConfigureReserve() public {
        address newAsset = makeAddr("newAsset");

        vm.prank(attacker);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));

        reserveManager.configureReserve(newAsset, 18, 8_000, 8_500, 500);
    }

    function test_RevertUnauthorizedSetLendingPool() public {
        address newPool = makeAddr("newPool");

        vm.prank(attacker);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));

        reserveManager.setLendingPool(newPool);
    }

    function test_RevertUnauthorizedSetReserveStatus() public {
        vm.prank(attacker);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));

        reserveManager.setReserveStatus(address(weth), false, false);
    }

    function test_RevertUnauthorizedSetInterestRateModel() public {
        InterestRateModel newModel = new InterestRateModel();

        vm.prank(attacker);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));

        reserveManager.setInterestRateModel(address(weth), address(newModel));
    }

    // =============================================================
    // RESERVE MANAGER ZERO ADDRESS PROTECTION
    // =============================================================

    function test_RevertConfigureZeroAsset() public {
        vm.expectRevert("Reserve: zero asset");

        reserveManager.configureReserve(address(0), 18, 8_000, 8_500, 500);
    }

    function test_RevertSetZeroLendingPool() public {
        // Use a fresh manager because the set-once rule is intentional.
        ReserveManager freshManager = new ReserveManager();

        vm.expectRevert("Reserve: zero lending pool");

        freshManager.setLendingPool(address(0));
    }

    function test_RevertSetZeroInterestRateModel() public {
        vm.expectRevert("Reserve: zero model");

        reserveManager.setInterestRateModel(address(weth), address(0));
    }

    function test_RevertSetModelForZeroAsset() public {
        InterestRateModel newModel = new InterestRateModel();

        vm.expectRevert("Reserve: zero asset");

        reserveManager.setInterestRateModel(address(0), address(newModel));
    }

    // =============================================================
    // RESERVE CONFIGURATION HARDENING
    // =============================================================

    function test_RevertConfigureReserveTwice() public {
        vm.expectRevert("Reserve: already configured");

        reserveManager.configureReserve(address(weth), 18, 8_000, 8_500, 500);
    }

    function test_RevertSetLendingPoolTwice() public {
        ReserveManager freshManager = new ReserveManager();

        address firstPool = makeAddr("firstPool");
        address secondPool = makeAddr("secondPool");

        freshManager.setLendingPool(firstPool);

        vm.expectRevert("Reserve: lending pool already set");

        freshManager.setLendingPool(secondPool);
    }

    function test_RevertSameInterestRateModel() public {
        vm.expectRevert("Reserve: same interest rate model");

        reserveManager.setInterestRateModel(address(weth), address(interestRateModel));
    }

    function test_RevertInvalidCollateralFactor() public {
        ReserveManager freshManager = new ReserveManager();

        vm.expectRevert("Reserve: invalid collateral factor");

        freshManager.configureReserve(makeAddr("asset"), 18, 10_001, 8_500, 500);
    }

    function test_RevertInvalidLiquidationThreshold() public {
        ReserveManager freshManager = new ReserveManager();

        vm.expectRevert("Reserve: invalid liquidation threshold");

        freshManager.configureReserve(makeAddr("asset"), 18, 8_000, 10_001, 500);
    }

    function test_RevertInvalidLiquidationBonus() public {
        ReserveManager freshManager = new ReserveManager();

        vm.expectRevert("Reserve: invalid liquidation bonus");

        freshManager.configureReserve(makeAddr("asset"), 18, 8_000, 8_500, 10_001);
    }

    // =============================================================
    // RESERVE STATUS
    // =============================================================

    function test_OnlyOwnerCanDisableBorrowing() public {
        vm.prank(attacker);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));

        reserveManager.setReserveStatus(address(weth), true, false);
    }

    function test_OwnerCanDisableBorrowing() public {
        reserveManager.setReserveStatus(address(weth), true, false);

        assertTrue(reserveManager.isActive(address(weth)));
        assertFalse(reserveManager.isBorrowEnabled(address(weth)));
    }

    function test_OwnerCanDeactivateReserve() public {
        reserveManager.setReserveStatus(address(weth), false, false);

        assertFalse(reserveManager.isActive(address(weth)));
        assertFalse(reserveManager.isBorrowEnabled(address(weth)));
    }

    // =============================================================
    // LENDING POOL ADMIN SECURITY
    // =============================================================

    function test_RevertSetZeroRiskManager() public {
        // A fresh pool is required because the current pool already
        // has its RiskManager configured.
        LendingPool freshPool = new LendingPool(address(reserveManager));

        vm.expectRevert("LendingPool: zero risk manager");

        freshPool.setRiskManager(address(0));
    }

    function test_RevertSetRiskManagerTwice() public {
        vm.expectRevert("LendingPool: risk manager already set");

        lendingPool.setRiskManager(address(riskManager));
    }

    function test_RevertUnauthorizedSetRiskManager() public {
        LendingPool freshPool = new LendingPool(address(reserveManager));

        vm.prank(attacker);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));

        freshPool.setRiskManager(address(riskManager));
    }

    // =============================================================
    // SUPPLY EDGE CASES
    // =============================================================

    function test_RevertSupplyZero() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: zero supply");

        lendingPool.supply(address(weth), 0);
    }

    function test_RevertSupplyInactiveReserve() public {
        reserveManager.setReserveStatus(address(weth), false, false);

        vm.prank(alice);

        vm.expectRevert("LendingPool: asset inactive");

        lendingPool.supply(address(weth), 1 * WETH);
    }

    function test_RevertSupplyWithoutBalance() public {
        address poorUser = makeAddr("poorUser");

        vm.prank(poorUser);

        weth.approve(address(lendingPool), 1 * WETH);

        vm.prank(poorUser);

        vm.expectRevert();

        lendingPool.supply(address(weth), 1 * WETH);
    }

    function test_SupplyUpdatesUserPosition() public {
        uint256 amount = 2 * WETH;

        vm.startPrank(alice);

        weth.approve(address(lendingPool), amount);

        lendingPool.supply(address(weth), amount);

        vm.stopPrank();

        uint256 collateral = lendingPool.getUserCollateral(alice, address(weth));

        assertEq(collateral, amount);
    }

    // =============================================================
    // WITHDRAW EDGE CASES
    // =============================================================

    function test_RevertWithdrawZero() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: zero withdraw");

        lendingPool.withdraw(address(weth), 0);
    }

    function test_RevertWithdrawWithoutSupply() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: insufficient collateral");

        lendingPool.withdraw(address(weth), 1);
    }

    function test_RevertWithdrawMoreThanSupply() public {
        uint256 supplyAmount = 1 * WETH;

        vm.startPrank(alice);

        weth.approve(address(lendingPool), supplyAmount);

        lendingPool.supply(address(weth), supplyAmount);

        vm.expectRevert("LendingPool: insufficient collateral");

        lendingPool.withdraw(address(weth), supplyAmount + 1);

        vm.stopPrank();
    }

    function test_WithdrawFullSupply() public {
        uint256 amount = 1 * WETH;

        vm.startPrank(alice);

        weth.approve(address(lendingPool), amount);

        lendingPool.supply(address(weth), amount);

        lendingPool.withdraw(address(weth), amount);

        vm.stopPrank();

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), 0);
    }

    // =============================================================
    // BORROW EDGE CASES
    // =============================================================

    function test_RevertBorrowZero() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: zero borrow");

        lendingPool.borrow(address(usdc), 0);
    }

    function test_RevertBorrowWithoutCollateral() public {
        // Provide USDC liquidity to the pool.
        uint256 liquidity = 10_000 * USDC;

        usdc.approve(address(lendingPool), liquidity);

        lendingPool.supply(address(usdc), liquidity);

        vm.prank(alice);

        vm.expectRevert("LendingPool: borrow not allowed");

        lendingPool.borrow(address(usdc), 1 * USDC);
    }

    function test_RevertBorrowAboveCollateralLimit() public {
        uint256 collateral = 1 * WETH;
        uint256 liquidity = 10_000 * USDC;

        // Alice supplies WETH.
        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateral);

        lendingPool.supply(address(weth), collateral);

        vm.stopPrank();

        // Pool receives USDC liquidity.
        usdc.approve(address(lendingPool), liquidity);

        lendingPool.supply(address(usdc), liquidity);

        // $3000 * 80% = $2400.
        uint256 maxBorrow = 2_400 * USDC;

        vm.prank(alice);

        vm.expectRevert("LendingPool: borrow not allowed");

        lendingPool.borrow(address(usdc), maxBorrow + 1);
    }

    function test_BorrowWithinCollateralLimit() public {
        uint256 collateral = 1 * WETH;
        uint256 liquidity = 10_000 * USDC;
        uint256 borrowAmount = 1_000 * USDC;

        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateral);

        lendingPool.supply(address(weth), collateral);

        vm.stopPrank();

        usdc.approve(address(lendingPool), liquidity);

        lendingPool.supply(address(usdc), liquidity);

        vm.prank(alice);

        lendingPool.borrow(address(usdc), borrowAmount);

        assertEq(lendingPool.getUserDebt(alice, address(usdc)), borrowAmount);
    }

    // =============================================================
    // REPAY EDGE CASES
    // =============================================================

    function test_RevertRepayZero() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: zero repay");

        lendingPool.repay(address(usdc), 0);
    }

    function test_RevertRepayWithoutDebt() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: no debt");

        lendingPool.repay(address(usdc), 1);
    }

    function test_RepayExactDebtClearsPosition() public {
        uint256 collateral = 1 * WETH;
        uint256 liquidity = 10_000 * USDC;
        uint256 borrowAmount = 1_000 * USDC;

        // Supply collateral.
        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateral);

        lendingPool.supply(address(weth), collateral);

        vm.stopPrank();

        // Supply liquidity.
        usdc.approve(address(lendingPool), liquidity);

        lendingPool.supply(address(usdc), liquidity);

        // Borrow.
        vm.prank(alice);

        lendingPool.borrow(address(usdc), borrowAmount);

        // Alice needs enough USDC to repay.
        usdc.mint(alice, borrowAmount);

        vm.startPrank(alice);

        usdc.approve(address(lendingPool), borrowAmount);

        lendingPool.repay(address(usdc), borrowAmount);

        vm.stopPrank();

        assertEq(lendingPool.getUserDebt(alice, address(usdc)), 0);
    }

    function test_RepayMoreThanDebtOnlyRepaysDebt() public {
        uint256 collateral = 1 * WETH;
        uint256 liquidity = 10_000 * USDC;
        uint256 borrowAmount = 1_000 * USDC;

        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateral);

        lendingPool.supply(address(weth), collateral);

        vm.stopPrank();

        usdc.approve(address(lendingPool), liquidity);

        lendingPool.supply(address(usdc), liquidity);

        vm.prank(alice);

        lendingPool.borrow(address(usdc), borrowAmount);

        usdc.mint(alice, borrowAmount * 2);

        vm.startPrank(alice);

        usdc.approve(address(lendingPool), borrowAmount * 2);

        lendingPool.repay(address(usdc), borrowAmount * 2);

        vm.stopPrank();

        assertEq(lendingPool.getUserDebt(alice, address(usdc)), 0);
    }

    // =============================================================
    // INTEREST ACCRUAL EDGE CASES
    // =============================================================

    function test_InterestIndexStartsAtOne() public {
        assertEq(reserveManager.getBorrowIndex(address(weth)), 1e18);

        assertEq(reserveManager.getSupplyIndex(address(weth)), 1e18);
    }

    function test_AccrualWithZeroElapsedTimeDoesNotChangeIndex() public {
        uint256 borrowIndex = reserveManager.getBorrowIndex(address(weth));

        uint256 supplyIndex = reserveManager.getSupplyIndex(address(weth));

        reserveManager.accrueInterest(address(weth));

        assertEq(reserveManager.getBorrowIndex(address(weth)), borrowIndex);

        assertEq(reserveManager.getSupplyIndex(address(weth)), supplyIndex);
    }

    function test_AccrualIncreasesBorrowIndex() public {
        // Create actual debt so interest accrual is meaningful.
        uint256 collateral = 2 * WETH;
        uint256 liquidity = 10_000 * USDC;
        uint256 borrowAmount = 1_000 * USDC;

        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateral);

        lendingPool.supply(address(weth), collateral);

        vm.stopPrank();

        usdc.approve(address(lendingPool), liquidity);

        lendingPool.supply(address(usdc), liquidity);

        vm.prank(alice);

        lendingPool.borrow(address(usdc), borrowAmount);

        uint256 initialIndex = reserveManager.getBorrowIndex(address(usdc));

        vm.warp(block.timestamp + 365 days);

        reserveManager.accrueInterest(address(usdc));

        uint256 finalIndex = reserveManager.getBorrowIndex(address(usdc));

        assertGt(finalIndex, initialIndex);
    }

    function test_AccrualWithNoBorrowingDoesNotIncreaseBorrowIndex() public {
        uint256 initialIndex = reserveManager.getBorrowIndex(address(usdc));

        vm.warp(block.timestamp + 365 days);

        reserveManager.accrueInterest(address(usdc));

        uint256 finalIndex = reserveManager.getBorrowIndex(address(usdc));

        // The index itself may remain at the same rate-independent
        // starting value because no borrow exists.
        assertEq(finalIndex, initialIndex);
    }

    // =============================================================
    // LIQUIDATION SAFETY
    // =============================================================

    function test_RevertLiquidationHealthyPosition() public {
        uint256 collateral = 2 * WETH;
        uint256 liquidity = 10_000 * USDC;
        uint256 borrowAmount = 1_000 * USDC;

        // Alice supplies WETH collateral.
        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateral);

        lendingPool.supply(address(weth), collateral);

        vm.stopPrank();

        // Supply USDC liquidity.
        usdc.approve(address(lendingPool), liquidity);

        lendingPool.supply(address(usdc), liquidity);

        // Alice borrows USDC.
        vm.prank(alice);

        lendingPool.borrow(address(usdc), borrowAmount);

        // Bob attempts to liquidate a healthy position.
        vm.startPrank(bob);

        usdc.approve(address(lendingPool), borrowAmount);

        vm.expectRevert("LendingPool: position healthy");

        lendingPool.liquidate(alice, address(usdc), address(weth), borrowAmount);

        vm.stopPrank();
    }

    function test_RevertLiquidationZeroDebtAmount() public {
        vm.prank(bob);

        vm.expectRevert("LendingPool: zero debt amount");

        lendingPool.liquidate(alice, address(usdc), address(weth), 0);
    }

    // =============================================================
    // POSITION CONSISTENCY
    // =============================================================

    function test_PositionStartsEmpty() public {
        (uint256 supplied, uint256 borrowed) = lendingPool.getUserScaledPosition(alice, address(weth));

        assertEq(supplied, 0);
        assertEq(borrowed, 0);

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), 0);

        assertEq(lendingPool.getUserDebt(alice, address(weth)), 0);
    }

    function test_ScaledSupplyMatchesUserPosition() public {
        uint256 amount = 5 * WETH;

        vm.startPrank(alice);

        weth.approve(address(lendingPool), amount);

        lendingPool.supply(address(weth), amount);

        vm.stopPrank();

        uint256 reserveScaled = reserveManager.getTotalScaledSupplied(address(weth));

        (uint256 userScaled,) = lendingPool.getUserScaledPosition(alice, address(weth));

        assertEq(reserveScaled, userScaled);
    }

    function test_ScaledBorrowMatchesUserPosition() public {
        uint256 collateral = 2 * WETH;
        uint256 liquidity = 10_000 * USDC;
        uint256 borrowAmount = 1_000 * USDC;

        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateral);

        lendingPool.supply(address(weth), collateral);

        vm.stopPrank();

        usdc.approve(address(lendingPool), liquidity);

        lendingPool.supply(address(usdc), liquidity);

        vm.prank(alice);

        lendingPool.borrow(address(usdc), borrowAmount);

        uint256 reserveScaled = reserveManager.getTotalScaledBorrowed(address(usdc));

        (, uint256 userScaled) = lendingPool.getUserScaledPosition(alice, address(usdc));

        assertEq(reserveScaled, userScaled);
    }

    // =============================================================
    // INTEREST MODEL SECURITY
    // =============================================================

    function test_ChangingInterestModelAccruesOldModelFirst() public {
        InterestRateModel newModel = new InterestRateModel();

        uint256 initialBorrowIndex = reserveManager.getBorrowIndex(address(usdc));

        vm.warp(block.timestamp + 365 days);

        reserveManager.setInterestRateModel(address(usdc), address(newModel));

        uint256 finalBorrowIndex = reserveManager.getBorrowIndex(address(usdc));

        // No borrow exists, but the model change itself must succeed.
        assertEq(reserveManager.getInterestRateModel(address(usdc)), address(newModel));

        assertEq(initialBorrowIndex, finalBorrowIndex);
    }

    // =============================================================
    // SUPPORTED ASSET REGISTRATION
    // =============================================================

    function test_SupportedAssetRegisteredAfterSupply() public {
        uint256 amount = 1 * WETH;

        vm.startPrank(alice);

        weth.approve(address(lendingPool), amount);

        lendingPool.supply(address(weth), amount);

        vm.stopPrank();

        address[] memory assets = lendingPool.getSupportedAssets();

        assertEq(assets.length, 1);
        assertEq(assets[0], address(weth));
    }

    function test_SupportedAssetNotDuplicated() public {
        uint256 amount = 1 * WETH;

        vm.startPrank(alice);

        weth.approve(address(lendingPool), amount * 2);

        lendingPool.supply(address(weth), amount);

        lendingPool.supply(address(weth), amount);

        vm.stopPrank();

        address[] memory assets = lendingPool.getSupportedAssets();

        assertEq(assets.length, 1);
        assertEq(assets[0], address(weth));
    }
}
