// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library UserTypes {
    struct Position {
        // =============================================================
        // SCALED BALANCES
        // =============================================================
        //
        // These are canonical scaled balances using the reserve's
        // global index:
        //
        // actual supplied = supplied * currentSupplyIndex / 1e18
        // actual borrowed = borrowed * currentBorrowIndex / 1e18
        //
        // The reserve aggregate stores the same scaled units. This is
        // important: user and reserve accounting must use identical
        // scaled deltas so interest accrual cannot create accounting
        // drift.
        // =============================================================

        uint256 supplied;
        uint256 borrowed;

        // =============================================================
        // LAST OBSERVED INDEX SNAPSHOTS
        // =============================================================
        //
        // These values are retained for position introspection/events
        // and are updated whenever the position is touched. They are
        // NOT used to calculate balances; the reserve's current global
        // index is the canonical source for valuation.
        // =============================================================

        uint256 supplyIndex;
        uint256 borrowIndex;
    }
}
