// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";

contract InterestRateModel is IInterestRateModel {
    uint256 public constant BASE_BORROW_RATE = 200;
    uint256 public constant MAX_BORROW_RATE = 1200;
    uint256 public constant MAX_SUPPLY_RATE = 1200;

    uint256 public constant BPS = 10_000;

    function getBorrowRate(uint256 totalSupplied, uint256 totalBorrowed) external pure override returns (uint256) {
        if (totalSupplied == 0) {
            return BASE_BORROW_RATE;
        }

        uint256 utilization = (totalBorrowed * BPS) / totalSupplied;

        uint256 borrowRate = BASE_BORROW_RATE + (utilization * (MAX_BORROW_RATE - BASE_BORROW_RATE)) / BPS;

        if (borrowRate > MAX_BORROW_RATE) {
            borrowRate = MAX_BORROW_RATE;
        }

        return borrowRate;
    }

    function getSupplyRate(uint256 totalSupplied, uint256 totalBorrowed) external pure override returns (uint256) {
        if (totalSupplied == 0 || totalBorrowed == 0) {
            return 0;
        }

        uint256 utilization = (totalBorrowed * BPS) / totalSupplied;

        uint256 borrowRate = BASE_BORROW_RATE + (utilization * (MAX_BORROW_RATE - BASE_BORROW_RATE)) / BPS;

        if (borrowRate > MAX_BORROW_RATE) {
            borrowRate = MAX_BORROW_RATE;
        }

        // Suppliers receive a share of borrower interest
        // proportional to utilization.
        uint256 supplyRate = (borrowRate * utilization) / BPS;

        if (supplyRate > MAX_SUPPLY_RATE) {
            supplyRate = MAX_SUPPLY_RATE;
        }

        return supplyRate;
    }
}
