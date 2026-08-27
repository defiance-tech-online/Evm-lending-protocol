// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../../src/tokens/MockERC20.sol";
import {MockPriceOracle} from "../../src/oracles/MockPriceOracle.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {RiskManager} from "../../src/RiskManager.sol";
import {LendingPoolHandler} from "./LendingPoolHandler.t.sol";

contract LendingPoolInvariantTest is Test {
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

    uint256 constant MAX_ROUNDING_DUST = 20;

    LendingPoolHandler public handler;

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

        // =========================================================
        // INITIAL BALANCES
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
    // RESERVE INVARIANTS
    // =============================================================

    function invariant_WETHReserveRemainsActive() public view {
        assertTrue(reserveManager.isActive(address(weth)), "WETH reserve inactive");
    }

    function invariant_USDCReserveRemainsActive() public view {
        assertTrue(reserveManager.isActive(address(usdc)), "USDC reserve inactive");
    }

    function invariant_WETHBorrowRemainsEnabled() public view {
        assertTrue(reserveManager.isBorrowEnabled(address(weth)), "WETH borrowing disabled");
    }

    function invariant_USDCBorrowRemainsEnabled() public view {
        assertTrue(reserveManager.isBorrowEnabled(address(usdc)), "USDC borrowing disabled");
    }

    // =============================================================
    // SCALED SUPPLY ACCOUNTING
    // =============================================================

    function invariant_WETHScaledSupplyMatchesUsers() public view {
        uint256 reserveScaled = reserveManager.getTotalScaledSupplied(address(weth));

        (uint256 aliceScaled,) = lendingPool.getUserScaledPosition(alice, address(weth));

        (uint256 bobScaled,) = lendingPool.getUserScaledPosition(bob, address(weth));

        assertEq(reserveScaled, aliceScaled + bobScaled, "WETH scaled supply mismatch");
    }

    function invariant_USDCScaledSupplyMatchesUsers() public view {
        uint256 reserveScaled = reserveManager.getTotalScaledSupplied(address(usdc));

        (uint256 aliceScaled,) = lendingPool.getUserScaledPosition(alice, address(usdc));

        (uint256 bobScaled,) = lendingPool.getUserScaledPosition(bob, address(usdc));

        assertEq(reserveScaled, aliceScaled + bobScaled, "USDC scaled supply mismatch");
    }

    // =============================================================
    // SCALED BORROW ACCOUNTING
    // =============================================================

    function invariant_WETHScaledBorrowMatchesUsers() public view {
        uint256 reserveScaled = reserveManager.getTotalScaledBorrowed(address(weth));

        (, uint256 aliceScaled) = lendingPool.getUserScaledPosition(alice, address(weth));

        (, uint256 bobScaled) = lendingPool.getUserScaledPosition(bob, address(weth));

        assertEq(reserveScaled, aliceScaled + bobScaled, "WETH scaled borrow mismatch");
    }

    function invariant_USDCScaledBorrowMatchesUsers() public view {
        uint256 reserveScaled = reserveManager.getTotalScaledBorrowed(address(usdc));

        (, uint256 aliceScaled) = lendingPool.getUserScaledPosition(alice, address(usdc));

        (, uint256 bobScaled) = lendingPool.getUserScaledPosition(bob, address(usdc));

        assertEq(reserveScaled, aliceScaled + bobScaled, "USDC scaled borrow mismatch");
    }

    // =============================================================
    // ACTUAL SUPPLY ACCOUNTING
    // =============================================================

    function invariant_WETHCollateralAccounting() public view {
        uint256 reserveTotal = reserveManager.getTotalSupplied(address(weth));

        uint256 aliceCollateral = lendingPool.getUserCollateral(alice, address(weth));

        uint256 bobCollateral = lendingPool.getUserCollateral(bob, address(weth));

        assertApproxEqAbs(
            reserveTotal, aliceCollateral + bobCollateral, MAX_ROUNDING_DUST, "WETH collateral accounting mismatch"
        );
    }

    function invariant_USDCCollateralAccounting() public view {
        uint256 reserveTotal = reserveManager.getTotalSupplied(address(usdc));

        uint256 aliceCollateral = lendingPool.getUserCollateral(alice, address(usdc));

        uint256 bobCollateral = lendingPool.getUserCollateral(bob, address(usdc));

        assertApproxEqAbs(
            reserveTotal, aliceCollateral + bobCollateral, MAX_ROUNDING_DUST, "USDC collateral accounting mismatch"
        );
    }

    // =============================================================
    // ACTUAL DEBT ACCOUNTING
    // =============================================================

    function invariant_USDCDebtAccounting() public view {
        uint256 reserveTotal = reserveManager.getTotalBorrowed(address(usdc));

        uint256 aliceDebt = lendingPool.getUserDebt(alice, address(usdc));

        uint256 bobDebt = lendingPool.getUserDebt(bob, address(usdc));

        assertApproxEqAbs(reserveTotal, aliceDebt + bobDebt, MAX_ROUNDING_DUST, "USDC debt accounting mismatch");
    }

    // =============================================================
    // SCALED POSITION EXISTENCE
    // =============================================================

    function invariant_WETHSupplyCannotExistWithoutActualSupply() public view {
        uint256 scaledSupply = reserveManager.getTotalScaledSupplied(address(weth));

        uint256 actualSupply = reserveManager.getTotalSupplied(address(weth));

        if (scaledSupply > 0) {
            assertGt(actualSupply, 0, "WETH scaled supply without actual supply");
        }
    }

    function invariant_USDCSupplyCannotExistWithoutActualSupply() public view {
        uint256 scaledSupply = reserveManager.getTotalScaledSupplied(address(usdc));

        uint256 actualSupply = reserveManager.getTotalSupplied(address(usdc));

        if (scaledSupply > 0) {
            assertGt(actualSupply, 0, "USDC scaled supply without actual supply");
        }
    }

    function invariant_WETHDebtCannotExistWithoutActualDebt() public view {
        uint256 scaledDebt = reserveManager.getTotalScaledBorrowed(address(weth));

        uint256 actualDebt = reserveManager.getTotalBorrowed(address(weth));

        if (scaledDebt > 0) {
            assertGt(actualDebt, 0, "WETH scaled debt without actual debt");
        }
    }

    function invariant_USDCDebtCannotExistWithoutActualDebt() public view {
        uint256 scaledDebt = reserveManager.getTotalScaledBorrowed(address(usdc));

        uint256 actualDebt = reserveManager.getTotalBorrowed(address(usdc));

        if (scaledDebt > 0) {
            assertGt(actualDebt, 0, "USDC scaled debt without actual debt");
        }
    }

    // =============================================================
    // USER POSITION CONSISTENCY
    // =============================================================

    function invariant_AliceUSDCPositionIsConsistent() public view {
        (uint256 scaledSupply, uint256 scaledDebt) = lendingPool.getUserScaledPosition(alice, address(usdc));

        uint256 actualSupply = lendingPool.getUserCollateral(alice, address(usdc));

        uint256 actualDebt = lendingPool.getUserDebt(alice, address(usdc));

        // No scaled supply => no actual supply.
        if (scaledSupply == 0) {
            assertEq(actualSupply, 0, "Alice USDC has supply without scaled position");
        }

        // No scaled debt => no actual debt.
        if (scaledDebt == 0) {
            assertEq(actualDebt, 0, "Alice USDC has debt without scaled position");
        }

        // Scaled positions must produce actual balances.
        if (scaledSupply > 0) {
            assertGt(actualSupply, 0, "Alice USDC scaled supply has zero actual balance");
        }

        if (scaledDebt > 0) {
            assertGt(actualDebt, 0, "Alice USDC scaled debt has zero actual balance");
        }
    }

    function invariant_BobUSDCPositionIsConsistent() public view {
        (uint256 scaledSupply, uint256 scaledDebt) = lendingPool.getUserScaledPosition(bob, address(usdc));

        uint256 actualSupply = lendingPool.getUserCollateral(bob, address(usdc));

        uint256 actualDebt = lendingPool.getUserDebt(bob, address(usdc));

        if (scaledSupply == 0) {
            assertEq(actualSupply, 0, "Bob USDC has supply without scaled position");
        }

        if (scaledDebt == 0) {
            assertEq(actualDebt, 0, "Bob USDC has debt without scaled position");
        }

        if (scaledSupply > 0) {
            assertGt(actualSupply, 0, "Bob USDC scaled supply has zero actual balance");
        }

        if (scaledDebt > 0) {
            assertGt(actualDebt, 0, "Bob USDC scaled debt has zero actual balance");
        }
    }

    // =============================================================
    // WETH USER POSITION CONSISTENCY
    // =============================================================

    function invariant_AliceWETHPositionIsConsistent() public view {
        (uint256 scaledSupply, uint256 scaledDebt) = lendingPool.getUserScaledPosition(alice, address(weth));

        uint256 actualSupply = lendingPool.getUserCollateral(alice, address(weth));

        uint256 actualDebt = lendingPool.getUserDebt(alice, address(weth));

        if (scaledSupply == 0) {
            assertEq(actualSupply, 0, "Alice WETH has supply without scaled position");
        }

        if (scaledDebt == 0) {
            assertEq(actualDebt, 0, "Alice WETH has debt without scaled position");
        }

        if (scaledSupply > 0) {
            assertGt(actualSupply, 0, "Alice WETH scaled supply has zero actual balance");
        }

        if (scaledDebt > 0) {
            assertGt(actualDebt, 0, "Alice WETH scaled debt has zero actual balance");
        }
    }

    function invariant_BobWETHPositionIsConsistent() public view {
        (uint256 scaledSupply, uint256 scaledDebt) = lendingPool.getUserScaledPosition(bob, address(weth));

        uint256 actualSupply = lendingPool.getUserCollateral(bob, address(weth));

        uint256 actualDebt = lendingPool.getUserDebt(bob, address(weth));

        if (scaledSupply == 0) {
            assertEq(actualSupply, 0, "Bob WETH has supply without scaled position");
        }

        if (scaledDebt == 0) {
            assertEq(actualDebt, 0, "Bob WETH has debt without scaled position");
        }

        if (scaledSupply > 0) {
            assertGt(actualSupply, 0, "Bob WETH scaled supply has zero actual balance");
        }

        if (scaledDebt > 0) {
            assertGt(actualDebt, 0, "Bob WETH scaled debt has zero actual balance");
        }
    }

    // =============================================================
    // SOLVENCY
    // =============================================================

    function invariant_WETHProtocolIsSolvent() public view {
        uint256 cash = weth.balanceOf(address(lendingPool));

        uint256 totalSupplied =
            lendingPool.getUserCollateral(alice, address(weth)) + lendingPool.getUserCollateral(bob, address(weth));

        uint256 totalDebt = lendingPool.getUserDebt(alice, address(weth)) + lendingPool.getUserDebt(bob, address(weth));

        assertGe(cash + totalDebt + MAX_ROUNDING_DUST, totalSupplied, "WETH protocol insolvent");
    }

    function invariant_USDCProtocolIsSolvent() public view {
        uint256 cash = usdc.balanceOf(address(lendingPool));

        uint256 totalSupplied =
            lendingPool.getUserCollateral(alice, address(usdc)) + lendingPool.getUserCollateral(bob, address(usdc));

        uint256 totalDebt = lendingPool.getUserDebt(alice, address(usdc)) + lendingPool.getUserDebt(bob, address(usdc));

        assertGe(cash + totalDebt + MAX_ROUNDING_DUST, totalSupplied, "USDC protocol insolvent");
    }

    // =============================================================
    // SUPPORTED ASSET INVARIANTS
    // =============================================================

    function invariant_SupportedAssetsAreActive() public view {
        address[] memory assets = lendingPool.getSupportedAssets();

        for (uint256 i = 0; i < assets.length; i++) {
            assertTrue(reserveManager.isActive(assets[i]), "Supported asset is inactive");
        }
    }

    function invariant_SupportedAssetsAreUnique() public view {
        address[] memory assets = lendingPool.getSupportedAssets();

        for (uint256 i = 0; i < assets.length; i++) {
            for (uint256 j = i + 1; j < assets.length; j++) {
                assertTrue(assets[i] != assets[j], "Duplicate supported asset");
            }
        }
    }

    // =============================================================
    // INTEREST INDEX INVARIANTS
    // =============================================================

    function invariant_WETHBorrowIndexNeverZero() public view {
        assertGt(reserveManager.getBorrowIndex(address(weth)), 0, "WETH borrow index is zero");
    }

    function invariant_WETHSupplyIndexNeverZero() public view {
        assertGt(reserveManager.getSupplyIndex(address(weth)), 0, "WETH supply index is zero");
    }

    function invariant_USDCBorrowIndexNeverZero() public view {
        assertGt(reserveManager.getBorrowIndex(address(usdc)), 0, "USDC borrow index is zero");
    }

    function invariant_USDCSupplyIndexNeverZero() public view {
        assertGt(reserveManager.getSupplyIndex(address(usdc)), 0, "USDC supply index is zero");
    }
}
