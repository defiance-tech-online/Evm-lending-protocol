// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ReserveTypes} from "./libraries/ReserveTypes.sol";
import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";

contract ReserveManager is Ownable {
    using ReserveTypes for ReserveTypes.Reserve;

    mapping(address => ReserveTypes.Reserve) private reserves;

    address public lendingPool;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant YEAR = 365 days;

    event ReserveConfigured(
        address indexed asset, uint256 collateralFactor, uint256 liquidationThreshold, uint256 liquidationBonus
    );

    event ReserveStatusUpdated(address indexed asset, bool active, bool borrowEnabled);

    constructor() Ownable(msg.sender) {}

    modifier onlyLendingPool() {
        require(msg.sender == lendingPool, "Reserve: unauthorized");
        _;
    }

    function setLendingPool(address lendingPool_) external onlyOwner {
        require(lendingPool_ != address(0), "Reserve: zero lending pool");

        lendingPool = lendingPool_;
    }

    // =============================================================
    // SUPPLY / BORROW TOTALS
    // =============================================================

    function increaseTotalSupplied(address asset, uint256 amount) external onlyLendingPool {
        require(amount > 0, "Reserve: zero amount");
        require(reserves[asset].lastUpdateTimestamp != 0, "Reserve: not configured");

        reserves[asset].totalSupplied += amount;
    }

    function decreaseTotalSupplied(address asset, uint256 amount) external onlyLendingPool {
        require(amount > 0, "Reserve: zero amount");
        require(reserves[asset].lastUpdateTimestamp != 0, "Reserve: not configured");
        require(reserves[asset].totalSupplied >= amount, "Reserve: insufficient supply");

        reserves[asset].totalSupplied -= amount;
    }

    function increaseTotalBorrowed(address asset, uint256 amount) external onlyLendingPool {
        require(amount > 0, "Reserve: zero amount");
        require(reserves[asset].lastUpdateTimestamp != 0, "Reserve: not configured");

        reserves[asset].totalBorrowed += amount;
    }

    function decreaseTotalBorrowed(address asset, uint256 amount) external onlyLendingPool {
        require(amount > 0, "Reserve: zero amount");
        require(reserves[asset].lastUpdateTimestamp != 0, "Reserve: not configured");
        require(reserves[asset].totalBorrowed >= amount, "Reserve: insufficient borrow");

        reserves[asset].totalBorrowed -= amount;
    }

    function getTotalSupplied(address asset) external view returns (uint256) {
        return reserves[asset].totalSupplied;
    }

    function getTotalBorrowed(address asset) external view returns (uint256) {
        return reserves[asset].totalBorrowed;
    }

    // =============================================================
    // INTEREST ACCRUAL
    // =============================================================

    function accrueInterest(address asset) public {
        ReserveTypes.Reserve storage reserve = reserves[asset];

        require(reserve.lastUpdateTimestamp != 0, "Reserve: not configured");

        require(reserve.interestRateModel != address(0), "Reserve: model not set");

        uint256 elapsed = block.timestamp - reserve.lastUpdateTimestamp;

        if (elapsed == 0) {
            return;
        }

        uint256 borrowRate =
            IInterestRateModel(reserve.interestRateModel).getBorrowRate(reserve.totalSupplied, reserve.totalBorrowed);

        uint256 supplyRate =
            IInterestRateModel(reserve.interestRateModel).getSupplyRate(reserve.totalSupplied, reserve.totalBorrowed);

        uint256 borrowGrowth = (borrowRate * WAD * elapsed) / (BPS * YEAR);

        uint256 supplyGrowth = (supplyRate * WAD * elapsed) / (BPS * YEAR);

        uint256 oldBorrowIndex = reserve.borrowIndex;
        uint256 oldSupplyIndex = reserve.supplyIndex;

        uint256 newBorrowIndex = oldBorrowIndex + (oldBorrowIndex * borrowGrowth) / WAD;

        uint256 newSupplyIndex = oldSupplyIndex + (oldSupplyIndex * supplyGrowth) / WAD;

        /*
         * Update reserve indexes first.
         *
         * User positions remain scaled by their own snapshot
         * indexes. The reserve totals represent the aggregate
         * current balances.
         */
        reserve.borrowIndex = newBorrowIndex;
        reserve.supplyIndex = newSupplyIndex;

        if (reserve.totalBorrowed > 0 && newBorrowIndex > oldBorrowIndex) {
            reserve.totalBorrowed = (reserve.totalBorrowed * newBorrowIndex) / oldBorrowIndex;
        }

        if (reserve.totalSupplied > 0 && newSupplyIndex > oldSupplyIndex) {
            reserve.totalSupplied = (reserve.totalSupplied * newSupplyIndex) / oldSupplyIndex;
        }

        reserve.lastUpdateTimestamp = block.timestamp;
    }

    // =============================================================
    // VIEW INDEX PREVIEW
    // =============================================================

    function getCurrentBorrowIndex(address asset) external view returns (uint256) {
        ReserveTypes.Reserve memory reserve = reserves[asset];

        require(reserve.lastUpdateTimestamp != 0, "Reserve: not configured");

        return _previewBorrowIndex(reserve);
    }

    function getCurrentSupplyIndex(address asset) external view returns (uint256) {
        ReserveTypes.Reserve memory reserve = reserves[asset];

        require(reserve.lastUpdateTimestamp != 0, "Reserve: not configured");

        return _previewSupplyIndex(reserve);
    }

    function _previewBorrowIndex(ReserveTypes.Reserve memory reserve) internal view returns (uint256) {
        if (reserve.interestRateModel == address(0)) {
            return reserve.borrowIndex;
        }

        uint256 elapsed = block.timestamp - reserve.lastUpdateTimestamp;

        if (elapsed == 0) {
            return reserve.borrowIndex;
        }

        uint256 borrowRate =
            IInterestRateModel(reserve.interestRateModel).getBorrowRate(reserve.totalSupplied, reserve.totalBorrowed);

        uint256 borrowGrowth = (borrowRate * WAD * elapsed) / (BPS * YEAR);

        return reserve.borrowIndex + (reserve.borrowIndex * borrowGrowth) / WAD;
    }

    function _previewSupplyIndex(ReserveTypes.Reserve memory reserve) internal view returns (uint256) {
        if (reserve.interestRateModel == address(0)) {
            return reserve.supplyIndex;
        }

        uint256 elapsed = block.timestamp - reserve.lastUpdateTimestamp;

        if (elapsed == 0) {
            return reserve.supplyIndex;
        }

        uint256 supplyRate =
            IInterestRateModel(reserve.interestRateModel).getSupplyRate(reserve.totalSupplied, reserve.totalBorrowed);

        uint256 supplyGrowth = (supplyRate * WAD * elapsed) / (BPS * YEAR);

        return reserve.supplyIndex + (reserve.supplyIndex * supplyGrowth) / WAD;
    }

    // =============================================================
    // RESERVE CONFIGURATION
    // =============================================================

    function configureReserve(
        address asset,
        uint8 decimals,
        uint256 collateralFactor,
        uint256 liquidationThreshold,
        uint256 liquidationBonus
    ) external onlyOwner {
        require(asset != address(0), "Reserve: zero asset");
        require(collateralFactor <= BPS, "Reserve: invalid collateral factor");
        require(liquidationThreshold <= BPS, "Reserve: invalid liquidation threshold");
        require(liquidationThreshold >= collateralFactor, "Reserve: threshold below collateral");
        require(liquidationBonus <= BPS, "Reserve: invalid liquidation bonus");

        ReserveTypes.Reserve storage reserve = reserves[asset];

        reserve.active = true;
        reserve.borrowEnabled = true;
        reserve.decimals = decimals;

        reserve.collateralFactor = collateralFactor;
        reserve.liquidationThreshold = liquidationThreshold;
        reserve.liquidationBonus = liquidationBonus;

        reserve.borrowIndex = WAD;
        reserve.supplyIndex = WAD;
        reserve.lastUpdateTimestamp = block.timestamp;

        emit ReserveConfigured(asset, collateralFactor, liquidationThreshold, liquidationBonus);
    }

    function setReserveStatus(address asset, bool active, bool borrowEnabled) external onlyOwner {
        ReserveTypes.Reserve storage reserve = reserves[asset];

        require(reserve.lastUpdateTimestamp != 0, "Reserve: not configured");

        reserve.active = active;
        reserve.borrowEnabled = borrowEnabled;

        emit ReserveStatusUpdated(asset, active, borrowEnabled);
    }

    // =============================================================
    // GETTERS
    // =============================================================

    function getDecimals(address asset) external view returns (uint8) {
        return reserves[asset].decimals;
    }

    function getReserve(address asset) external view returns (ReserveTypes.Reserve memory) {
        return reserves[asset];
    }

    function isActive(address asset) external view returns (bool) {
        return reserves[asset].active;
    }

    function isBorrowEnabled(address asset) external view returns (bool) {
        return reserves[asset].borrowEnabled;
    }

    function getCollateralFactor(address asset) external view returns (uint256) {
        return reserves[asset].collateralFactor;
    }

    function getLiquidationThreshold(address asset) external view returns (uint256) {
        return reserves[asset].liquidationThreshold;
    }

    function getLiquidationBonus(address asset) external view returns (uint256) {
        return reserves[asset].liquidationBonus;
    }

    // =============================================================
    // INTEREST RATE MODEL
    // =============================================================

    function setInterestRateModel(address asset, address model) external onlyOwner {
        require(asset != address(0), "Reserve: zero asset");
        require(model != address(0), "Reserve: zero model");
        require(reserves[asset].lastUpdateTimestamp != 0, "Reserve: not configured");

        reserves[asset].interestRateModel = model;
    }

    function getInterestRateModel(address asset) external view returns (address) {
        return reserves[asset].interestRateModel;
    }

    function getBorrowIndex(address asset) external view returns (uint256) {
        return reserves[asset].borrowIndex;
    }

    function getSupplyIndex(address asset) external view returns (uint256) {
        return reserves[asset].supplyIndex;
    }
}
