// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library ReserveTypes {
    struct Reserve {
        bool active;
        bool borrowEnabled;

        uint8 decimals;

        // =============================================================
        // SCALED ACCOUNTING
        // =============================================================
        //
        // Actual supplied balance:
        //
        // totalScaledSupplied * supplyIndex / 1e18
        //
        // Actual borrowed balance:
        //
        // totalScaledBorrowed * borrowIndex / 1e18
        //
        uint256 totalScaledSupplied;
        uint256 totalScaledBorrowed;

        uint256 collateralFactor;
        uint256 liquidationThreshold;
        uint256 liquidationBonus;

        address interestRateModel;

        // =============================================================
        // INTEREST INDICES
        // =============================================================

        uint256 borrowIndex;
        uint256 supplyIndex;

        uint256 lastUpdateTimestamp;
    }
}
