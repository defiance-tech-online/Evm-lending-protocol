// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {ReserveManager} from "../src/ReserveManager.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {RiskManager} from "../src/RiskManager.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address priceOracle = vm.envAddress("PRICE_ORACLE_ADDRESS");

        address interestRateModel = vm.envAddress("INTEREST_RATE_MODEL_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // =========================================================
        // RESERVE MANAGER
        // =========================================================

        ReserveManager reserveManager = new ReserveManager();

        // =========================================================
        // LENDING POOL
        // =========================================================

        LendingPool lendingPool = new LendingPool(address(reserveManager));

        // =========================================================
        // RISK MANAGER
        // =========================================================

        RiskManager riskManager = new RiskManager(address(reserveManager), priceOracle, address(lendingPool));

        // =========================================================
        // CORE WIRING
        // =========================================================

        reserveManager.setLendingPool(address(lendingPool));

        lendingPool.setRiskManager(address(riskManager));

        vm.stopBroadcast();

        // =========================================================
        // OUTPUT
        // =========================================================

        console2.log("========================================");
        console2.log("CORE PROTOCOL DEPLOYMENTS");
        console2.log("========================================");

        console2.log("Reserve Manager:");
        console2.log(address(reserveManager));

        console2.log("Lending Pool:");
        console2.log(address(lendingPool));

        console2.log("Risk Manager:");
        console2.log(address(riskManager));

        console2.log("========================================");

        console2.log("Existing Price Oracle:");
        console2.log(priceOracle);

        console2.log("Existing Interest Rate Model:");
        console2.log(interestRateModel);

        console2.log("========================================");
    }
}
