// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {ReserveManager} from "../src/ReserveManager.sol";
import {MockPriceOracle} from "../src/oracles/MockPriceOracle.sol";

contract ConfigureProtocol is Script {
    //uint256 constant BPS = 10_000;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // =========================================================
        // EXISTING DEPLOYMENTS
        // =========================================================

        address weth = vm.envAddress("WETH_ADDRESS");

        address usdc = vm.envAddress("USDC_ADDRESS");

        address reserveManagerAddress = vm.envAddress("RESERVE_MANAGER_ADDRESS");

        address priceOracleAddress = vm.envAddress("PRICE_ORACLE_ADDRESS");

        address interestRateModelAddress = vm.envAddress("INTEREST_RATE_MODEL_ADDRESS");

        ReserveManager reserveManager = ReserveManager(reserveManagerAddress);

        MockPriceOracle priceOracle = MockPriceOracle(priceOracleAddress);

        vm.startBroadcast(deployerPrivateKey);

        // =========================================================
        // WETH RESERVE
        // =========================================================

        reserveManager.configureReserve(weth, 18, 8_000, 8_500, 500);

        // =========================================================
        // USDC RESERVE
        // =========================================================

        reserveManager.configureReserve(usdc, 6, 8_000, 8_500, 500);

        // =========================================================
        // INTEREST RATE MODELS
        // =========================================================

        reserveManager.setInterestRateModel(weth, interestRateModelAddress);

        reserveManager.setInterestRateModel(usdc, interestRateModelAddress);

        // =========================================================
        // ORACLE PRICES
        // =========================================================

        // WETH = $3,000
        priceOracle.setPrice(weth, 3000e8, 8);

        // USDC = $1
        priceOracle.setPrice(usdc, 1e8, 8);

        vm.stopBroadcast();

        // =========================================================
        // OUTPUT
        // =========================================================

        console2.log("========================================");
        console2.log("PROTOCOL CONFIGURED");
        console2.log("========================================");

        console2.log("WETH Reserve:");
        console2.log(weth);

        console2.log("USDC Reserve:");
        console2.log(usdc);

        console2.log("Price Oracle:");
        console2.log(priceOracleAddress);

        console2.log("Interest Rate Model:");
        console2.log(interestRateModelAddress);

        console2.log("========================================");
        console2.log("Collateral Factor: 80%");
        console2.log("Liquidation Threshold: 85%");
        console2.log("Liquidation Bonus: 5%");
        console2.log("========================================");
    }
}
