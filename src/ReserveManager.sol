// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

    event InterestRateModelUpdated(address indexed asset, address indexed model);

    event LendingPoolUpdated(address indexed lendingPool);

    constructor() Ownable(msg.sender) {}

    // =============================================================
    // ACCESS CONTROL
    // =============================================================

    modifier onlyLendingPool() {
        require(msg.sender == lendingPool, "Reserve: unauthorized");
        _;
    }

    function setLendingPool(address lendingPool_) external onlyOwner {
        require(lendingPool_ != address(0), "Reserve: zero lending pool");
        require(lendingPool == address(0), "Reserve: lending pool already set");

        lendingPool = lendingPool_;

        emit LendingPoolUpdated(lendingPool_);
    }

    // =============================================================
    // SCALED SUPPLY TOTALS
    // =============================================================

    function increaseTotalSupplied(address asset, uint256 amount)
        external
        onlyLendingPool
        returns (uint256 scaledAmount)
    {
        require(amount > 0, "Reserve: zero amount");

        ReserveTypes.Reserve storage reserve = reserves[asset];

        require(reserve.lastUpdateTimestamp != 0, "Reserve: not configured");

        scaledAmount = _scaledAmountDown(amount, reserve.supplyIndex);

        require(scaledAmount > 0, "Reserve: amount too small");

        reserve.totalScaledSupplied += scaledAmount;
    }

    function decreaseTotalSupplied(address asset, uint256 amount)
        external
        onlyLendingPool
        returns (uint256 scaledAmount)
    {
        require(amount > 0, "Reserve: zero amount");

        ReserveTypes.Reserve storage reserve = reserves[asset];

        require(reserve.lastUpdateTimestamp != 0, "Reserve: not configured");

        // Round withdrawals up so the protocol never removes less
        // accounting value than the actual tokens transferred out.
        scaledAmount = _scaledAmountUp(amount, reserve.supplyIndex);

        require(reserve.totalScaledSupplied >= scaledAmount, "Reserve: insufficient supply");

        reserve.totalScaledSupplied -= scaledAmount;
    }

    function decreaseTotalScaledSupplied(address asset, uint256 scaledAmount) external onlyLendingPool {
        require(scaledAmount > 0, "Reserve: zero amount");

        ReserveTypes.Reserve storage reserve = reserves[asset];

        require(reserve.lastUpdateTimestamp != 0, "Reserve: not configured");
        require(reserve.totalScaledSupplied >= scaledAmount, "Reserve: insufficient supply");

        reserve.totalScaledSupplied -= scaledAmount;
    }

    // =============================================================
    // SCALED BORROW TOTALS
    // =============================================================

    function increaseTotalBorrowed(address asset, uint256 amount)
        external
        onlyLendingPool
        returns (uint256 scaledAmount)
    {
        require(amount > 0, "Reserve: zero amount");

        ReserveTypes.Reserve storage reserve = reserves[asset];

        require(reserve.lastUpdateTimestamp != 0, "Reserve: not configured");

        scaledAmount = _scaledAmountDown(amount, reserve.borrowIndex);

        require(scaledAmount > 0, "Reserve: amount too small");

        reserve.totalScaledBorrowed += scaledAmount;
    }

    function decreaseTotalBorrowed(address asset, uint256 amount)
        external
        onlyLendingPool
        returns (uint256 scaledAmount)
    {
        require(amount > 0, "Reserve: zero amount");

        ReserveTypes.Reserve storage reserve = reserves[asset];

        require(reserve.lastUpdateTimestamp != 0, "Reserve: not configured");

        // Round repayments up so the protocol never leaves more
        // debt outstanding than the tokens actually repaid justify.
        scaledAmount = _scaledAmountUp(amount, reserve.borrowIndex);

        require(reserve.totalScaledBorrowed >= scaledAmount, "Reserve: insufficient borrow");

        reserve.totalScaledBorrowed -= scaledAmount;
    }

    function decreaseTotalScaledBorrowed(address asset, uint256 scaledAmount) external onlyLendingPool {
        require(scaledAmount > 0, "Reserve: zero amount");

        ReserveTypes.Reserve storage reserve = reserves[asset];

        require(reserve.lastUpdateTimestamp != 0, "Reserve: not configured");
        require(reserve.totalScaledBorrowed >= scaledAmount, "Reserve: insufficient borrow");

        reserve.totalScaledBorrowed -= scaledAmount;
    }

    // =============================================================
    // ACTUAL TOTALS
    // =============================================================

    function getTotalSupplied(address asset) external view returns (uint256) {
        ReserveTypes.Reserve memory reserve = reserves[asset];

        if (reserve.totalScaledSupplied == 0) {
            return 0;
        }

        uint256 currentIndex = _previewSupplyIndex(reserve);

        return (reserve.totalScaledSupplied * currentIndex) / WAD;
    }

    function getTotalBorrowed(address asset) external view returns (uint256) {
        ReserveTypes.Reserve memory reserve = reserves[asset];

        if (reserve.totalScaledBorrowed == 0) {
            return 0;
        }

        uint256 currentIndex = _previewBorrowIndex(reserve);

        return (reserve.totalScaledBorrowed * currentIndex) / WAD;
    }

    // =============================================================
    // SCALED TOTAL GETTERS
    // =============================================================

    function getTotalScaledSupplied(address asset) external view returns (uint256) {
        return reserves[asset].totalScaledSupplied;
    }

    function getTotalScaledBorrowed(address asset) external view returns (uint256) {
        return reserves[asset].totalScaledBorrowed;
    }

    // =============================================================
    // SCALED AMOUNT CONVERSION
    // =============================================================

    function _scaledAmountDown(uint256 amount, uint256 index) internal pure returns (uint256) {
        require(index > 0, "Reserve: zero index");

        return Math.mulDiv(amount, WAD, index);
    }

    function _scaledAmountUp(uint256 amount, uint256 index) internal pure returns (uint256) {
        require(index > 0, "Reserve: zero index");

        return Math.mulDiv(amount, WAD, index, Math.Rounding.Ceil);
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

        uint256 currentSupply = _currentSupplyBalance(reserve);
        uint256 currentBorrow = _currentBorrowBalance(reserve);

        uint256 borrowRate = IInterestRateModel(reserve.interestRateModel).getBorrowRate(currentSupply, currentBorrow);

        uint256 supplyRate = IInterestRateModel(reserve.interestRateModel).getSupplyRate(currentSupply, currentBorrow);

        uint256 borrowGrowth = (borrowRate * WAD * elapsed) / (BPS * YEAR);
        uint256 supplyGrowth = (supplyRate * WAD * elapsed) / (BPS * YEAR);

        reserve.borrowIndex = reserve.borrowIndex + (reserve.borrowIndex * borrowGrowth) / WAD;

        reserve.supplyIndex = reserve.supplyIndex + (reserve.supplyIndex * supplyGrowth) / WAD;

        reserve.lastUpdateTimestamp = block.timestamp;
    }

    // =============================================================
    // INDEX PREVIEW
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

        uint256 currentSupply = _currentSupplyBalance(reserve);
        uint256 currentBorrow = _currentBorrowBalance(reserve);

        uint256 borrowRate = IInterestRateModel(reserve.interestRateModel).getBorrowRate(currentSupply, currentBorrow);

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

        uint256 currentSupply = _currentSupplyBalance(reserve);
        uint256 currentBorrow = _currentBorrowBalance(reserve);

        uint256 supplyRate = IInterestRateModel(reserve.interestRateModel).getSupplyRate(currentSupply, currentBorrow);

        uint256 supplyGrowth = (supplyRate * WAD * elapsed) / (BPS * YEAR);

        return reserve.supplyIndex + (reserve.supplyIndex * supplyGrowth) / WAD;
    }

    // =============================================================
    // BALANCE HELPERS
    // =============================================================

    function _currentSupplyBalance(ReserveTypes.Reserve memory reserve) internal pure returns (uint256) {
        return (reserve.totalScaledSupplied * reserve.supplyIndex) / WAD;
    }

    function _currentBorrowBalance(ReserveTypes.Reserve memory reserve) internal pure returns (uint256) {
        return (reserve.totalScaledBorrowed * reserve.borrowIndex) / WAD;
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

        ReserveTypes.Reserve storage reserve = reserves[asset];

        // Prevent accidental reconfiguration of a live reserve.
        // Reconfiguration would reset scaled balances and indexes.
        require(reserve.lastUpdateTimestamp == 0, "Reserve: already configured");

        require(collateralFactor <= BPS, "Reserve: invalid collateral factor");

        require(liquidationThreshold <= BPS, "Reserve: invalid liquidation threshold");

        require(liquidationThreshold >= collateralFactor, "Reserve: threshold below collateral");

        require(liquidationBonus <= BPS, "Reserve: invalid liquidation bonus");

        reserve.active = true;
        reserve.borrowEnabled = true;
        reserve.decimals = decimals;

        reserve.collateralFactor = collateralFactor;

        reserve.liquidationThreshold = liquidationThreshold;

        reserve.liquidationBonus = liquidationBonus;

        reserve.totalScaledSupplied = 0;
        reserve.totalScaledBorrowed = 0;

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

        ReserveTypes.Reserve storage reserve = reserves[asset];

        require(reserve.lastUpdateTimestamp != 0, "Reserve: not configured");
        require(reserve.interestRateModel != model, "Reserve: same interest rate model");

        // Accrue interest using the OLD model before switching.
        if (reserve.interestRateModel != address(0)) {
            accrueInterest(asset);
        }

        reserve.interestRateModel = model;
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
