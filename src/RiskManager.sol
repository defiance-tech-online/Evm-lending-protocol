// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRiskManager} from "./interfaces/IRiskManager.sol";
import {IPositionProvider} from "./interfaces/IPositionProvider.sol";
import {ReserveManager} from "./ReserveManager.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

contract RiskManager is IRiskManager {
    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;

    ReserveManager public immutable reserveManager;
    IPriceOracle public immutable priceOracle;
    IPositionProvider public immutable positionProvider;

    constructor(address reserveManager_, address priceOracle_, address positionProvider_) {
        require(reserveManager_ != address(0), "RiskManager: zero reserve manager");

        require(priceOracle_ != address(0), "RiskManager: zero oracle");

        require(positionProvider_ != address(0), "RiskManager: zero position provider");

        reserveManager = ReserveManager(reserveManager_);
        priceOracle = IPriceOracle(priceOracle_);
        positionProvider = IPositionProvider(positionProvider_);
    }

    // =============================================================
    // RESERVE PARAMETERS
    // =============================================================

    function getCollateralFactor(address asset) external view returns (uint256) {
        return reserveManager.getCollateralFactor(asset);
    }

    function getLiquidationThreshold(address asset) external view returns (uint256) {
        return reserveManager.getLiquidationThreshold(asset);
    }

    function getLiquidationBonus(address asset) external view returns (uint256) {
        return reserveManager.getLiquidationBonus(asset);
    }

    // =============================================================
    // HEALTH FACTOR
    // =============================================================

    function calculateHealthFactor(address user) external view returns (uint256) {
        (uint256 collateralValue, uint256 debtValue) = _getAccountValues(user);

        if (debtValue == 0) {
            return type(uint256).max;
        }

        return (collateralValue * WAD) / debtValue;
    }

    // =============================================================
    // BORROW VALIDATION
    // =============================================================

    function canBorrow(address user, address asset, uint256 amount) external view returns (bool) {
        if (amount == 0) {
            return false;
        }

        uint256 collateralValue;
        uint256 debtValue;

        address[] memory assets = positionProvider.getSupportedAssets();

        for (uint256 i = 0; i < assets.length; i++) {
            address currentAsset = assets[i];

            uint256 supplied = positionProvider.getUserCollateral(user, currentAsset);

            uint256 borrowed = positionProvider.getUserDebt(user, currentAsset);

            if (supplied > 0) {
                uint256 value = _getAssetValue(currentAsset, supplied);

                uint256 collateralFactor = reserveManager.getCollateralFactor(currentAsset);

                collateralValue += (value * collateralFactor) / BPS;
            }

            if (borrowed > 0) {
                debtValue += _getAssetValue(currentAsset, borrowed);
            }
        }

        uint256 newDebt = debtValue + _getAssetValue(asset, amount);

        return collateralValue >= newDebt;
    }

    // =============================================================
    // WITHDRAW VALIDATION
    // =============================================================

    function canWithdraw(address user, address asset, uint256 amount) external view returns (bool) {
        if (amount == 0) {
            return false;
        }

        uint256 collateralValue;
        uint256 debtValue;

        address[] memory assets = positionProvider.getSupportedAssets();

        for (uint256 i = 0; i < assets.length; i++) {
            address currentAsset = assets[i];

            uint256 supplied = positionProvider.getUserCollateral(user, currentAsset);
            uint256 borrowed = positionProvider.getUserDebt(user, currentAsset);

            // Remove the requested withdrawal from this asset's collateral.
            if (currentAsset == asset) {
                if (supplied < amount) {
                    return false;
                }

                supplied -= amount;
            }

            if (supplied > 0) {
                uint256 value = _getAssetValue(currentAsset, supplied);

                uint256 liquidationThreshold = reserveManager.getLiquidationThreshold(currentAsset);

                collateralValue += (value * liquidationThreshold) / BPS;
            }

            if (borrowed > 0) {
                debtValue += _getAssetValue(currentAsset, borrowed);
            }
        }

        // No debt means the withdrawal is safe.
        if (debtValue == 0) {
            return true;
        }

        // After withdrawal, health factor must remain >= 1.
        return collateralValue >= debtValue;
    }

    // =============================================================
    // LIQUIDATION
    // =============================================================

    function canLiquidate(address user) external view returns (bool) {
        uint256 healthFactor = this.calculateHealthFactor(user);

        return healthFactor < WAD;
    }

    function calculateLiquidationCollateral(address debtAsset, address collateralAsset, uint256 debtAmount)
        external
        view
        returns (uint256)
    {
        require(debtAmount > 0, "RiskManager: zero debt amount");

        uint256 debtValue = _getAssetValue(debtAsset, debtAmount);

        uint256 liquidationBonus = reserveManager.getLiquidationBonus(collateralAsset);

        uint256 collateralValue = (debtValue * (BPS + liquidationBonus)) / BPS;

        return _getAmountFromValue(collateralAsset, collateralValue);
    }

    // =============================================================
    // ACCOUNT VALUES
    // =============================================================

    function _getAccountValues(address user) internal view returns (uint256 collateralValue, uint256 debtValue) {
        address[] memory assets = positionProvider.getSupportedAssets();

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];

            uint256 collateral = positionProvider.getUserCollateral(user, asset);

            uint256 debt = positionProvider.getUserDebt(user, asset);

            if (collateral > 0) {
                uint256 value = _getAssetValue(asset, collateral);

                uint256 liquidationThreshold = reserveManager.getLiquidationThreshold(asset);

                collateralValue += (value * liquidationThreshold) / BPS;
            }

            if (debt > 0) {
                debtValue += _getAssetValue(asset, debt);
            }
        }
    }

    // =============================================================
    // ASSET VALUE
    // =============================================================

    function _getAssetValue(address asset, uint256 amount) internal view returns (uint256) {
        uint256 price = priceOracle.getPrice(asset);

        uint8 priceDecimals = priceOracle.getPriceDecimals(asset);

        uint8 tokenDecimals = reserveManager.getDecimals(asset);

        uint256 normalizedAmount;

        require(amount > 0, "RiskManager: zero amount");
        require(tokenDecimals <= 18, "RiskManager: invalid token decimals");
        require(priceDecimals <= 18, "RiskManager: invalid price decimals");

        if (tokenDecimals < 18) {
            normalizedAmount = amount * 10 ** (18 - tokenDecimals);
        } else if (tokenDecimals > 18) {
            normalizedAmount = amount / 10 ** (tokenDecimals - 18);
        } else {
            normalizedAmount = amount;
        }

        if (priceDecimals < 18) {
            price *= 10 ** (18 - priceDecimals);
        } else if (priceDecimals > 18) {
            price /= 10 ** (priceDecimals - 18);
        }

        return (normalizedAmount * price) / WAD;
    }

    function _getAmountFromValue(address asset, uint256 value) internal view returns (uint256) {
        uint256 price = priceOracle.getPrice(asset);

        uint8 priceDecimals = priceOracle.getPriceDecimals(asset);

        uint8 tokenDecimals = reserveManager.getDecimals(asset);

        require(value > 0, "RiskManager: zero value");
        require(tokenDecimals <= 18, "RiskManager: invalid token decimals");
        require(priceDecimals <= 18, "RiskManager: invalid price decimals");

        if (priceDecimals < 18) {
            price *= 10 ** (18 - priceDecimals);
        } else if (priceDecimals > 18) {
            price /= 10 ** (priceDecimals - 18);
        }

        uint256 normalizedAmount = (value * WAD) / price;

        if (tokenDecimals < 18) {
            return normalizedAmount / 10 ** (18 - tokenDecimals);
        }

        if (tokenDecimals > 18) {
            return normalizedAmount * 10 ** (tokenDecimals - 18);
        }

        return normalizedAmount;
    }
}
