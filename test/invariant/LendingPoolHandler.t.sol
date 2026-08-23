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

        // Maximum theoretical USDC borrowing power:
        // WETH collateral * $3000 * 80%
        //
        // collateral is 18 decimals
        // price is $3000 with 8 decimals
        // USDC is 6 decimals
        uint256 collateralValue = (collateral * 3000e8) / 1e18;

        uint256 maxBorrow = (collateralValue * 8_000) / 10_000;

        // Convert USD value (8 decimals) to USDC (6 decimals)
        maxBorrow = maxBorrow / 1e2;

        if (maxBorrow == 0) {
            return;
        }

        uint256 poolLiquidity = usdc.balanceOf(address(lendingPool));

        if (poolLiquidity == 0) {
            return;
        }

        if (maxBorrow > poolLiquidity) {
            maxBorrow = poolLiquidity;
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

        amount = bound(amount, 1, maxRepay);

        vm.startPrank(actor);

        usdc.approve(address(lendingPool), amount);

        try lendingPool.repay(address(usdc), amount) {
            repayCalls++;
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

    function advanceTime(uint256 secondsForward) external {
        secondsForward = bound(secondsForward, 1 hours, 7 days);

        vm.warp(block.timestamp + secondsForward);
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
