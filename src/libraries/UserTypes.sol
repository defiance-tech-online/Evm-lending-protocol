// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library UserTypes {
    struct Position {
        uint256 supplied;
        uint256 borrowed;

        // Index at the time the position was last updated.
        uint256 supplyIndex;
        uint256 borrowIndex;
    }
}
