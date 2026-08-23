// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ReserveManager} from "./ReserveManager.sol";
import {RiskManager} from "./RiskManager.sol";
import {UserTypes} from "./libraries/UserTypes.sol";
import {IPositionProvider} from "./interfaces/IPositionProvider.sol";
import {ReserveTypes} from "./libraries/ReserveTypes.sol";

contract LendingPool is IPositionProvider, Ownable {
    using UserTypes for UserTypes.Position;
    using SafeERC20 for IERC20;

    ReserveManager public immutable reserveManager;
    RiskManager public riskManager;

    mapping(address => mapping(address => UserTypes.Position)) internal positions;

    address[] internal supportedAssets;
    mapping(address => bool) internal isSupported;

    event Supplied(address indexed user, address indexed asset, uint256 amount);

    event Withdrawn(address indexed user, address indexed asset, uint256 amount);

    event Borrowed(address indexed user, address indexed asset, uint256 amount);

    event Repaid(address indexed user, address indexed asset, uint256 amount);

    event Liquidated(
        address indexed liquidator,
        address indexed user,
        address indexed debtAsset,
        address collateralAsset,
        uint256 debtAmount,
        uint256 collateralAmount
    );

    event RiskManagerUpdated(address indexed riskManager);

    constructor(address reserveManager_) Ownable(msg.sender) {
        require(reserveManager_ != address(0), "LendingPool: zero reserve manager");

        reserveManager = ReserveManager(reserveManager_);
    }

    // =============================================================
    // ADMIN
    // =============================================================

    function setRiskManager(address riskManager_) external onlyOwner {
        require(riskManager_ != address(0), "LendingPool: zero risk manager");

        require(address(riskManager) == address(0), "LendingPool: risk manager already set");

        riskManager = RiskManager(riskManager_);

        emit RiskManagerUpdated(riskManager_);
    }

    // =============================================================
    // SUPPLY
    // =============================================================

    function supply(address asset, uint256 amount) external {
        require(amount > 0, "LendingPool: zero supply");
        _requireActive(asset);

        _accrue(asset);
        _registerAsset(asset);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        UserTypes.Position storage position = positions[msg.sender][asset];

        uint256 currentIndex = reserveManager.getSupplyIndex(asset);

        if (position.supplied > 0) {
            position.supplied = _balanceFromIndex(position.supplied, position.supplyIndex, currentIndex);
        }

        position.supplied += amount;
        position.supplyIndex = currentIndex;

        reserveManager.increaseTotalSupplied(asset, amount);

        emit Supplied(msg.sender, asset, amount);
    }

    // =============================================================
    // WITHDRAW
    // =============================================================

    function withdraw(address asset, uint256 amount) external {
        require(amount > 0, "LendingPool: zero withdraw");
        _requireActive(asset);

        _accrue(asset);

        UserTypes.Position storage position = positions[msg.sender][asset];

        uint256 currentIndex = reserveManager.getSupplyIndex(asset);

        uint256 currentBalance = _balanceFromIndex(position.supplied, position.supplyIndex, currentIndex);

        require(currentBalance >= amount, "LendingPool: insufficient collateral");

        require(IERC20(asset).balanceOf(address(this)) >= amount, "LendingPool: insufficient liquidity");

        position.supplied = currentBalance - amount;
        position.supplyIndex = currentIndex;

        reserveManager.decreaseTotalSupplied(asset, amount);

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, asset, amount);
    }

    // =============================================================
    // BORROW
    // =============================================================

    function borrow(address asset, uint256 amount) external {
        require(amount > 0, "LendingPool: zero borrow");
        _requireActive(asset);

        require(reserveManager.isBorrowEnabled(asset), "LendingPool: borrow disabled");

        require(address(riskManager) != address(0), "LendingPool: risk manager not set");

        /*
         * Accrue every asset already used by the account before
         * asking RiskManager to validate the new debt.
         *
         * This keeps the health calculation based on current
         * indexes.
         */
        _accrue(asset);

        require(riskManager.canBorrow(msg.sender, asset, amount), "LendingPool: borrow not allowed");

        require(IERC20(asset).balanceOf(address(this)) >= amount, "LendingPool: insufficient liquidity");

        _registerAsset(asset);

        UserTypes.Position storage position = positions[msg.sender][asset];

        uint256 currentIndex = reserveManager.getBorrowIndex(asset);

        if (position.borrowed > 0) {
            position.borrowed = _balanceFromIndex(position.borrowed, position.borrowIndex, currentIndex);
        }

        position.borrowed += amount;
        position.borrowIndex = currentIndex;

        reserveManager.increaseTotalBorrowed(asset, amount);

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, asset, amount);
    }

    // =============================================================
    // REPAY
    // =============================================================

    function repay(address asset, uint256 amount) external {
        require(amount > 0, "LendingPool: zero repay");
        _requireActive(asset);

        _accrue(asset);

        UserTypes.Position storage position = positions[msg.sender][asset];

        uint256 currentIndex = reserveManager.getBorrowIndex(asset);

        uint256 currentDebt = _balanceFromIndex(position.borrowed, position.borrowIndex, currentIndex);

        require(currentDebt > 0, "LendingPool: no debt");

        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), repayAmount);

        position.borrowed = currentDebt - repayAmount;

        position.borrowIndex = currentIndex;

        reserveManager.decreaseTotalBorrowed(asset, repayAmount);

        emit Repaid(msg.sender, asset, repayAmount);
    }

    // =============================================================
    // LIQUIDATION
    // =============================================================

    function liquidate(address user, address debtAsset, address collateralAsset, uint256 debtAmount) external {
        require(user != address(0), "LendingPool: zero user");

        require(debtAmount > 0, "LendingPool: zero debt amount");

        require(address(riskManager) != address(0), "LendingPool: risk manager not set");

        _requireActive(debtAsset);
        _requireActive(collateralAsset);

        _accrue(debtAsset);

        if (collateralAsset != debtAsset) {
            _accrue(collateralAsset);
        }

        require(riskManager.canLiquidate(user), "LendingPool: position healthy");

        UserTypes.Position storage debtPosition = positions[user][debtAsset];

        uint256 debtIndex = reserveManager.getBorrowIndex(debtAsset);

        uint256 currentDebt = _balanceFromIndex(debtPosition.borrowed, debtPosition.borrowIndex, debtIndex);

        require(currentDebt > 0, "LendingPool: no debt");

        require(debtAmount <= currentDebt, "LendingPool: liquidation exceeds debt");

        UserTypes.Position storage collateralPosition = positions[user][collateralAsset];

        uint256 collateralIndex = reserveManager.getSupplyIndex(collateralAsset);

        uint256 currentCollateral =
            _balanceFromIndex(collateralPosition.supplied, collateralPosition.supplyIndex, collateralIndex);

        uint256 collateralAmount = riskManager.calculateLiquidationCollateral(debtAsset, collateralAsset, debtAmount);

        require(collateralAmount <= currentCollateral, "LendingPool: liquidation exceeds collateral");

        require(IERC20(debtAsset).balanceOf(address(this)) >= 0, "LendingPool: invalid");

        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), debtAmount);

        debtPosition.borrowed = currentDebt - debtAmount;

        debtPosition.borrowIndex = debtIndex;

        collateralPosition.supplied = currentCollateral - collateralAmount;

        collateralPosition.supplyIndex = collateralIndex;

        reserveManager.decreaseTotalBorrowed(debtAsset, debtAmount);

        reserveManager.decreaseTotalSupplied(collateralAsset, collateralAmount);

        IERC20(collateralAsset).safeTransfer(msg.sender, collateralAmount);

        emit Liquidated(msg.sender, user, debtAsset, collateralAsset, debtAmount, collateralAmount);
    }

    // =============================================================
    // POSITION VIEWS
    // =============================================================

    function getUserCollateral(address user, address asset) public view override returns (uint256) {
        UserTypes.Position memory position = positions[user][asset];

        if (position.supplied == 0) {
            return 0;
        }

        uint256 currentIndex = reserveManager.getCurrentSupplyIndex(asset);

        return _balanceFromIndex(position.supplied, position.supplyIndex, currentIndex);
    }

    function getUserDebt(address user, address asset) public view override returns (uint256) {
        UserTypes.Position memory position = positions[user][asset];

        if (position.borrowed == 0) {
            return 0;
        }

        uint256 currentIndex = reserveManager.getCurrentBorrowIndex(asset);

        return _balanceFromIndex(position.borrowed, position.borrowIndex, currentIndex);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        require(address(riskManager) != address(0), "LendingPool: risk manager not set");

        return riskManager.calculateHealthFactor(user);
    }

    function getSupportedAssets() external view override returns (address[] memory) {
        return supportedAssets;
    }

    function getUserPosition(address user, address asset)
        external
        view
        returns (uint256 supplied, uint256 borrowed, uint256 supplyIndex, uint256 borrowIndex)
    {
        UserTypes.Position memory position = positions[user][asset];

        supplied = getUserCollateral(user, asset);

        borrowed = getUserDebt(user, asset);

        supplyIndex = position.supplyIndex;
        borrowIndex = position.borrowIndex;
    }

    // =============================================================
    // INTERNAL
    // =============================================================

    function _registerAsset(address asset) internal {
        if (!isSupported[asset]) {
            isSupported[asset] = true;
            supportedAssets.push(asset);
        }
    }

    function _requireActive(address asset) internal view {
        require(reserveManager.isActive(asset), "LendingPool: asset inactive");
    }

    function _accrue(address asset) internal {
        reserveManager.accrueInterest(asset);
    }

    function _balanceFromIndex(uint256 principal, uint256 userIndex, uint256 currentIndex)
        internal
        pure
        returns (uint256)
    {
        if (principal == 0) {
            return 0;
        }

        if (userIndex == 0) {
            return principal;
        }

        return (principal * currentIndex) / userIndex;
    }
}
