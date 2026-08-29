// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRiskManager {
    function getCollateralFactor(address asset) external view returns (uint256);

    function getLiquidationThreshold(address asset) external view returns (uint256);

    function getLiquidationBonus(address asset) external view returns (uint256);

    function calculateHealthFactor(address user) external view returns (uint256);

    function canBorrow(address user, address asset, uint256 amount) external view returns (bool);
    function canWithdraw(address user, address asset, uint256 amount) external view returns (bool);

    function canLiquidate(address user) external view returns (bool);

    function calculateLiquidationCollateral(address debtAsset, address collateralAsset, uint256 debtAmount)
        external
        view
        returns (uint256);
}
