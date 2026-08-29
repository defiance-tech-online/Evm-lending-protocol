// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ReserveManager} from "./ReserveManager.sol";
import {RiskManager} from "./RiskManager.sol";
import {UserTypes} from "./libraries/UserTypes.sol";
import {IPositionProvider} from "./interfaces/IPositionProvider.sol";

contract LendingPool is IPositionProvider, Ownable, ReentrancyGuard {
    using UserTypes for UserTypes.Position;
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;

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

    function supply(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "LendingPool: zero supply");

        _requireActive(asset);
        _accrue(asset);
        _registerAsset(asset);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        UserTypes.Position storage position = positions[msg.sender][asset];

        uint256 currentIndex = reserveManager.getSupplyIndex(asset);
        uint256 scaledAmount = reserveManager.increaseTotalSupplied(asset, amount);

        position.supplied += scaledAmount;
        position.supplyIndex = currentIndex;

        emit Supplied(msg.sender, asset, amount);
    }

    // =============================================================
    // WITHDRAW
    // =============================================================

    function withdraw(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "LendingPool: zero withdraw");
        require(address(riskManager) != address(0), "LendingPool: risk manager not set");

        _requireActive(asset);
        _accrue(asset);

        UserTypes.Position storage position = positions[msg.sender][asset];

        uint256 currentIndex = reserveManager.getSupplyIndex(asset);
        uint256 currentBalance = _currentSupply(position, currentIndex);

        require(currentBalance >= amount, "LendingPool: insufficient collateral");
        require(IERC20(asset).balanceOf(address(this)) >= amount, "LendingPool: insufficient liquidity");

        require(
            riskManager.canWithdraw(msg.sender, asset, amount), "LendingPool: withdrawal would make position unhealthy"
        );

        uint256 scaledAmount = reserveManager.decreaseTotalSupplied(asset, amount);

        require(position.supplied >= scaledAmount, "LendingPool: scaled collateral underflow");

        position.supplied -= scaledAmount;
        position.supplyIndex = currentIndex;

        if (position.borrowed > 0) {
            require(riskManager.calculateHealthFactor(msg.sender) >= WAD, "LendingPool: unhealthy position");
        }

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, asset, amount);
    }

    // =============================================================
    // BORROW
    // =============================================================

    function borrow(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "LendingPool: zero borrow");

        _requireActive(asset);
        require(reserveManager.isBorrowEnabled(asset), "LendingPool: borrow disabled");
        require(address(riskManager) != address(0), "LendingPool: risk manager not set");

        _accrue(asset);

        require(riskManager.canBorrow(msg.sender, asset, amount), "LendingPool: borrow not allowed");
        require(IERC20(asset).balanceOf(address(this)) >= amount, "LendingPool: insufficient liquidity");

        _registerAsset(asset);

        UserTypes.Position storage position = positions[msg.sender][asset];

        uint256 currentIndex = reserveManager.getBorrowIndex(asset);
        uint256 scaledAmount = reserveManager.increaseTotalBorrowed(asset, amount);

        position.borrowed += scaledAmount;
        position.borrowIndex = currentIndex;

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, asset, amount);
    }

    // =============================================================
    // REPAY
    // =============================================================

    function repay(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "LendingPool: zero repay");

        _requireActive(asset);
        _accrue(asset);

        UserTypes.Position storage position = positions[msg.sender][asset];

        uint256 currentIndex = reserveManager.getBorrowIndex(asset);
        uint256 currentDebt = _currentBorrow(position, currentIndex);

        require(currentDebt > 0, "LendingPool: no debt");

        uint256 repayAmount = amount > currentDebt ? currentDebt : amount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), repayAmount);

        uint256 scaledAmount;

        if (repayAmount == currentDebt) {
            scaledAmount = position.borrowed;
            reserveManager.decreaseTotalScaledBorrowed(asset, scaledAmount);
        } else {
            scaledAmount = reserveManager.decreaseTotalBorrowed(asset, repayAmount);
        }

        require(position.borrowed >= scaledAmount, "LendingPool: scaled debt underflow");

        position.borrowed -= scaledAmount;
        position.borrowIndex = currentIndex;

        emit Repaid(msg.sender, asset, repayAmount);
    }

    // =============================================================
    // LIQUIDATION
    // =============================================================

    function liquidate(address user, address debtAsset, address collateralAsset, uint256 debtAmount)
        external
        nonReentrant
    {
        require(user != address(0), "LendingPool: zero user");
        require(user != msg.sender, "LendingPool: cannot liquidate self");
        require(debtAmount > 0, "LendingPool: zero debt amount");
        require(address(riskManager) != address(0), "LendingPool: risk manager not set");

        _requireActive(debtAsset);
        _requireActive(collateralAsset);

        _accrue(debtAsset);

        if (collateralAsset != debtAsset) {
            _accrue(collateralAsset);
        }

        require(riskManager.canLiquidate(user), "LendingPool: position healthy");

        (uint256 currentDebt, uint256 debtIndex) = _getLiquidationDebt(user, debtAsset);
        require(currentDebt > 0, "LendingPool: no debt");
        require(debtAmount <= currentDebt, "LendingPool: liquidation exceeds debt");

        (uint256 currentCollateral, uint256 collateralIndex) = _getLiquidationCollateral(user, collateralAsset);

        uint256 collateralAmount = riskManager.calculateLiquidationCollateral(debtAsset, collateralAsset, debtAmount);

        require(collateralAmount <= currentCollateral, "LendingPool: liquidation exceeds collateral");

        _executeLiquidation(
            user,
            debtAsset,
            collateralAsset,
            debtAmount,
            collateralAmount,
            currentDebt,
            currentCollateral,
            debtIndex,
            collateralIndex
        );
    }

    function _executeLiquidation(
        address user,
        address debtAsset,
        address collateralAsset,
        uint256 debtAmount,
        uint256 collateralAmount,
        uint256 currentDebt,
        uint256 currentCollateral,
        uint256 debtIndex,
        uint256 collateralIndex
    ) internal {
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), debtAmount);

        UserTypes.Position storage debtPosition = positions[user][debtAsset];
        UserTypes.Position storage collateralPosition = positions[user][collateralAsset];

        uint256 scaledDebtAmount;
        uint256 scaledCollateralAmount;

        // Full liquidation must clear the complete scaled position.
        if (debtAmount == currentDebt) {
            scaledDebtAmount = debtPosition.borrowed;
            reserveManager.decreaseTotalScaledBorrowed(debtAsset, scaledDebtAmount);
        } else {
            // Partial liquidation uses FLOOR for debt reduction.
            scaledDebtAmount = reserveManager.decreaseTotalBorrowed(debtAsset, debtAmount);
        }

        // Collateral is transferred out, so use CEIL for the scaled
        // reduction. If all displayed collateral is liquidated, clear
        // the exact scaled position to avoid residual dust.
        if (collateralAmount == currentCollateral) {
            scaledCollateralAmount = collateralPosition.supplied;
            reserveManager.decreaseTotalScaledSupplied(collateralAsset, scaledCollateralAmount);
        } else {
            scaledCollateralAmount = reserveManager.decreaseTotalSupplied(collateralAsset, collateralAmount);
        }

        require(debtPosition.borrowed >= scaledDebtAmount, "LendingPool: scaled debt underflow");
        require(collateralPosition.supplied >= scaledCollateralAmount, "LendingPool: scaled collateral underflow");

        debtPosition.borrowed -= scaledDebtAmount;
        debtPosition.borrowIndex = debtIndex;

        collateralPosition.supplied -= scaledCollateralAmount;
        collateralPosition.supplyIndex = collateralIndex;

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

        return (position.supplied * currentIndex) / WAD;
    }

    function getUserDebt(address user, address asset) public view override returns (uint256) {
        UserTypes.Position memory position = positions[user][asset];

        if (position.borrowed == 0) {
            return 0;
        }

        uint256 currentIndex = reserveManager.getCurrentBorrowIndex(asset);

        return (position.borrowed * currentIndex) / WAD;
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
        supplied = getUserCollateral(user, asset);
        borrowed = getUserDebt(user, asset);

        supplyIndex = reserveManager.getCurrentSupplyIndex(asset);
        borrowIndex = reserveManager.getCurrentBorrowIndex(asset);
    }

    // =============================================================
    // SCALED POSITION VIEWS
    // =============================================================

    function getUserScaledPosition(address user, address asset)
        external
        view
        returns (uint256 supplied, uint256 borrowed)
    {
        UserTypes.Position memory position = positions[user][asset];

        supplied = position.supplied;
        borrowed = position.borrowed;
    }

    // =============================================================
    // INTERNAL - LIQUIDATION VIEWS
    // =============================================================

    function _getLiquidationDebt(address user, address asset)
        internal
        view
        returns (uint256 currentDebt, uint256 currentIndex)
    {
        UserTypes.Position memory position = positions[user][asset];

        currentIndex = reserveManager.getBorrowIndex(asset);
        currentDebt = _currentBorrow(position, currentIndex);
    }

    function _getLiquidationCollateral(address user, address asset)
        internal
        view
        returns (uint256 currentCollateral, uint256 currentIndex)
    {
        UserTypes.Position memory position = positions[user][asset];

        currentIndex = reserveManager.getSupplyIndex(asset);
        currentCollateral = _currentSupply(position, currentIndex);
    }

    // =============================================================
    // INTERNAL - BALANCE
    // =============================================================

    function _currentSupply(UserTypes.Position memory position, uint256 currentIndex) internal pure returns (uint256) {
        if (position.supplied == 0) {
            return 0;
        }

        return (position.supplied * currentIndex) / WAD;
    }

    function _currentBorrow(UserTypes.Position memory position, uint256 currentIndex) internal pure returns (uint256) {
        if (position.borrowed == 0) {
            return 0;
        }

        return (position.borrowed * currentIndex) / WAD;
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
}
