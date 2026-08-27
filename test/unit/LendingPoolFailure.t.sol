// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../../src/tokens/MockERC20.sol";
import {MockPriceOracle} from "../../src/oracles/MockPriceOracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {RiskManager} from "../../src/RiskManager.sol";

contract LendingPoolFailureTest is Test {
    MockERC20 weth;
    MockERC20 usdc;

    MockPriceOracle oracle;
    InterestRateModel interestRateModel;

    ReserveManager reserveManager;
    LendingPool lendingPool;
    RiskManager riskManager;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant WETH = 1e18;
    uint256 constant USDC = 1e6;

    function setUp() public {
        weth = new MockERC20("Mock WETH", "mWETH", 18);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        oracle = new MockPriceOracle();
        interestRateModel = new InterestRateModel();

        reserveManager = new ReserveManager();

        reserveManager.configureReserve(address(weth), 18, 8_000, 8_500, 500);

        reserveManager.configureReserve(address(usdc), 6, 8_000, 8_500, 500);

        lendingPool = new LendingPool(address(reserveManager));

        reserveManager.setLendingPool(address(lendingPool));

        reserveManager.setInterestRateModel(address(weth), address(interestRateModel));

        reserveManager.setInterestRateModel(address(usdc), address(interestRateModel));

        riskManager = new RiskManager(address(reserveManager), address(oracle), address(lendingPool));

        lendingPool.setRiskManager(address(riskManager));

        oracle.setPrice(address(weth), 3000e8, 8);
        oracle.setPrice(address(usdc), 1e8, 8);

        weth.mint(alice, 20 * WETH);
        usdc.mint(alice, 20_000 * USDC);

        weth.mint(bob, 20 * WETH);
        usdc.mint(bob, 20_000 * USDC);
    }

    // =============================================================
    // SUPPLY FAILURE CASES
    // =============================================================

    function test_RevertSupplyZero() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: zero supply");

        lendingPool.supply(address(weth), 0);
    }

    function test_RevertSupplyInactiveAsset() public {
        address unsupported = makeAddr("unsupported");

        vm.prank(alice);

        vm.expectRevert("LendingPool: asset inactive");

        lendingPool.supply(unsupported, 1 ether);
    }

    // =============================================================
    // WITHDRAW FAILURE CASES
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
        uint256 amount = 1 ether;

        vm.startPrank(alice);

        weth.approve(address(lendingPool), amount);

        lendingPool.supply(address(weth), amount);

        vm.expectRevert("LendingPool: insufficient collateral");

        lendingPool.withdraw(address(weth), amount + 1);

        vm.stopPrank();
    }

    // =============================================================
    // BORROW FAILURE CASES
    // =============================================================

    function test_RevertBorrowZero() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: zero borrow");

        lendingPool.borrow(address(usdc), 0);
    }

    function test_RevertBorrowWithoutCollateral() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: borrow not allowed");

        lendingPool.borrow(address(usdc), 1 * USDC);
    }

    function test_RevertBorrowAboveCollateralLimit() public {
        uint256 collateral = 1 * WETH;

        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateral);

        lendingPool.supply(address(weth), collateral);

        /*
         * 1 WETH = $3000
         * 80% collateral factor = $2400
         *
         * Therefore borrowing more than 2400 USDC
         * should fail.
         */

        vm.expectRevert("LendingPool: borrow not allowed");

        lendingPool.borrow(address(usdc), 2_401 * USDC);

        vm.stopPrank();
    }

    // =============================================================
    // REPAY FAILURE CASES
    // =============================================================

    function test_RevertRepayZero() public {
        vm.prank(alice);

        vm.expectRevert("LendingPool: zero repay");

        lendingPool.repay(address(usdc), 0);
    }

    function test_RevertRepayWithoutDebt() public {
        vm.startPrank(alice);

        usdc.approve(address(lendingPool), 1 * USDC);

        vm.expectRevert("LendingPool: no debt");

        lendingPool.repay(address(usdc), 1 * USDC);

        vm.stopPrank();
    }

    // =============================================================
    // LIQUIDATION FAILURE CASES
    // =============================================================

    function test_RevertLiquidationHealthyPosition() public {
        uint256 collateral = 5 * WETH;
        uint256 borrowAmount = 1_000 * USDC;

        // ---------------------------------------------------------
        // Provide USDC liquidity to the LendingPool
        // ---------------------------------------------------------

        vm.startPrank(bob);

        usdc.approve(address(lendingPool), 10_000 * USDC);

        lendingPool.supply(address(usdc), 10_000 * USDC);

        vm.stopPrank();

        // ---------------------------------------------------------
        // Alice supplies WETH collateral and borrows USDC
        // ---------------------------------------------------------

        vm.startPrank(alice);

        weth.approve(address(lendingPool), collateral);

        lendingPool.supply(address(weth), collateral);

        lendingPool.borrow(address(usdc), borrowAmount);

        vm.stopPrank();

        // ---------------------------------------------------------
        // Bob attempts to liquidate Alice
        //
        // Alice's position is healthy:
        //
        // 5 WETH × $3000 = $15,000 collateral
        // $15,000 × 80% = $12,000 borrow capacity
        //
        // Alice debt = $1,000
        //
        // Therefore liquidation must revert.
        // ---------------------------------------------------------

        vm.startPrank(bob);

        usdc.approve(address(lendingPool), borrowAmount);

        vm.expectRevert("LendingPool: position healthy");

        lendingPool.liquidate(alice, address(usdc), address(weth), borrowAmount);

        vm.stopPrank();
    }

    // =============================================================
    // POSITION STATE
    // =============================================================

    function test_PositionStartsEmpty() public view {
        (uint256 supplied, uint256 borrowed) = lendingPool.getUserScaledPosition(alice, address(weth));

        assertEq(supplied, 0);
        assertEq(borrowed, 0);

        assertEq(lendingPool.getUserCollateral(alice, address(weth)), 0);

        assertEq(lendingPool.getUserDebt(alice, address(weth)), 0);
    }
}
