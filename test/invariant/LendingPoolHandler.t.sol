// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "../../src/tokens/MockERC20.sol";
import {ReserveManager} from "../../src/ReserveManager.sol";
import {LendingPool} from "../../src/LendingPool.sol";

contract LendingPoolHandler is Test {
    MockERC20 public weth;
    MockERC20 public usdc;

    ReserveManager public reserveManager;
    LendingPool public lendingPool;

    address[] public actors;

    uint256 public supplyCalls;
    uint256 public withdrawCalls;
    uint256 public borrowCalls;
    uint256 public repayCalls;
    uint256 public accrueCalls;
    uint256 public liquidateCalls;
    uint256 public warpCalls;

    constructor(
        MockERC20 _weth,
        MockERC20 _usdc,
        ReserveManager _reserveManager,
        LendingPool _lendingPool,
        address _alice,
        address _bob
    ) {
        weth = _weth;
        usdc = _usdc;

        reserveManager = _reserveManager;
        lendingPool = _lendingPool;

        actors.push(_alice);
        actors.push(_bob);
    }

    // =============================================================
    // ACTOR SELECTION
    // =============================================================

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // =============================================================
    // SUPPLY
    // =============================================================

    function supplyWETH(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);

        uint256 balance = weth.balanceOf(actor);

        if (balance == 0) {
            return;
        }

        amount = bound(amount, 1, balance);

        vm.startPrank(actor);

        weth.approve(address(lendingPool), amount);

        try lendingPool.supply(address(weth), amount) {
            supplyCalls++;
        } catch {}

        vm.stopPrank();
    }

    function supplyUSDC(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);

        uint256 balance = usdc.balanceOf(actor);

        if (balance == 0) {
            return;
        }

        amount = bound(amount, 1, balance);

        vm.startPrank(actor);

        usdc.approve(address(lendingPool), amount);

        try lendingPool.supply(address(usdc), amount) {
            supplyCalls++;
        } catch {}

        vm.stopPrank();
    }

    // =============================================================
    // WITHDRAW
    // =============================================================

    function withdrawWETH(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);

        uint256 supplied = lendingPool.getUserCollateral(actor, address(weth));

        if (supplied == 0) {
            return;
        }

        amount = bound(amount, 1, supplied);

        vm.prank(actor);

        try lendingPool.withdraw(address(weth), amount) {
            withdrawCalls++;
        } catch {}
    }

    function withdrawUSDC(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);

        uint256 supplied = lendingPool.getUserCollateral(actor, address(usdc));

        if (supplied == 0) {
            return;
        }

        amount = bound(amount, 1, supplied);

        vm.prank(actor);

        try lendingPool.withdraw(address(usdc), amount) {
            withdrawCalls++;
        } catch {}
    }

    // =============================================================
    // BORROW
    // =============================================================

    function borrowUSDC(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);

        uint256 collateral = lendingPool.getUserCollateral(actor, address(weth));

        if (collateral == 0) {
            return;
        }

        /*
         * WETH price:
         *
         * $3,000 with 8 decimals.
         *
         * Convert WETH collateral (18 decimals)
         * into USD value (8 decimals).
         */
        uint256 collateralValue = (collateral * 3000e8) / 1e18;

        /*
         * 80% collateral factor.
         */
        uint256 maxBorrow = (collateralValue * 8_000) / 10_000;

        /*
         * Convert USD 8 decimals -> USDC 6 decimals.
         */
        maxBorrow = maxBorrow / 1e2;

        if (maxBorrow == 0) {
            return;
        }

        /*
         * Borrowing is also limited by available USDC
         * liquidity inside the LendingPool.
         */
        uint256 poolLiquidity = usdc.balanceOf(address(lendingPool));

        if (poolLiquidity == 0) {
            return;
        }

        if (maxBorrow > poolLiquidity) {
            maxBorrow = poolLiquidity;
        }

        if (maxBorrow == 0) {
            return;
        }

        amount = bound(amount, 1, maxBorrow);

        vm.prank(actor);

        try lendingPool.borrow(address(usdc), amount) {
            borrowCalls++;
        } catch {}
    }

    // =============================================================
    // REPAY
    // =============================================================

    function repayUSDC(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);

        uint256 debt = lendingPool.getUserDebt(actor, address(usdc));

        if (debt == 0) {
            return;
        }

        uint256 balance = usdc.balanceOf(actor);

        if (balance == 0) {
            return;
        }

        uint256 maxRepay = debt < balance ? debt : balance;

        if (maxRepay == 0) {
            return;
        }

        amount = bound(amount, 1, maxRepay);

        vm.startPrank(actor);

        usdc.approve(address(lendingPool), amount);

        try lendingPool.repay(address(usdc), amount) {
            repayCalls++;
        } catch {}

        vm.stopPrank();
    }

    // =============================================================
    // LIQUIDATION
    // =============================================================

    function liquidateAlice(uint256 debtAmount) external {
        address user = actors[0];
        address liquidator = actors[1];

        uint256 debt = lendingPool.getUserDebt(user, address(usdc));

        if (debt == 0) {
            return;
        }

        uint256 collateral = lendingPool.getUserCollateral(user, address(weth));

        if (collateral == 0) {
            return;
        }

        uint256 liquidatorBalance = usdc.balanceOf(liquidator);

        if (liquidatorBalance == 0) {
            return;
        }

        uint256 maxAmount = debt;

        if (maxAmount > liquidatorBalance) {
            maxAmount = liquidatorBalance;
        }

        if (maxAmount == 0) {
            return;
        }

        debtAmount = bound(debtAmount, 1, maxAmount);

        vm.startPrank(liquidator);

        usdc.approve(address(lendingPool), debtAmount);

        try lendingPool.liquidate(user, address(usdc), address(weth), debtAmount) {
            liquidateCalls++;
        } catch {}

        vm.stopPrank();
    }

    // =============================================================
    // INTEREST ACCRUAL
    // =============================================================

    function accrueInterest(uint256 seed) external {
        address asset = seed % 2 == 0 ? address(weth) : address(usdc);

        try reserveManager.accrueInterest(asset) {
            accrueCalls++;
        } catch {}
    }

    // =============================================================
    // TIME ADVANCEMENT
    // =============================================================

    function advanceTime(uint256 timeDelta) external {
        timeDelta = bound(timeDelta, 1, 365 days);

        vm.warp(block.timestamp + timeDelta);

        warpCalls++;
    }

    // =============================================================
    // VIEW HELPERS
    // =============================================================

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 index) external view returns (address) {
        return actors[index];
    }
}
