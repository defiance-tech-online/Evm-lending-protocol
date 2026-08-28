// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {MockERC20} from "../src/tokens/MockERC20.sol";
import {MockPriceOracle} from "../src/oracles/MockPriceOracle.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {RiskManager} from "../src/RiskManager.sol";

contract DeploySepolia is Script {
    // =============================================================
    // CONSTANTS
    // =============================================================

    uint256 internal constant COLLATERAL_FACTOR = 8_000;
    uint256 internal constant LIQUIDATION_THRESHOLD = 8_500;
    uint256 internal constant LIQUIDATION_BONUS = 500;

    uint256 internal constant WETH_PRICE = 3_000e8;
    uint256 internal constant USDC_PRICE = 1e8;

    // =============================================================
    // DEPLOYED CONTRACTS
    // =============================================================

    MockERC20 public weth;
    MockERC20 public usdc;

    MockPriceOracle public priceOracle;
    InterestRateModel public interestRateModel;

    ReserveManager public reserveManager;
    LendingPool public lendingPool;
    RiskManager public riskManager;

    // =============================================================
    // MAIN
    // =============================================================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address deployer = vm.addr(deployerPrivateKey);

        console2.log("========================================");
        console2.log("SEPOLIA DEPLOYMENT");
        console2.log("========================================");
        console2.log("Deployer:");
        console2.log(deployer);
        console2.log("Chain ID:");
        console2.log(block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // =========================================================
        // 1. DEPLOY MOCK ASSETS
        // =========================================================

        weth = new MockERC20("Mock WETH", "mWETH", 18);

        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        // =========================================================
        // 2. DEPLOY ORACLE
        // =========================================================

        priceOracle = new MockPriceOracle();

        // =========================================================
        // 3. DEPLOY INTEREST RATE MODEL
        // =========================================================

        interestRateModel = new InterestRateModel();

        // =========================================================
        // 4. DEPLOY RESERVE MANAGER
        // =========================================================

        reserveManager = new ReserveManager();

        // =========================================================
        // 5. DEPLOY LENDING POOL
        // =========================================================

        lendingPool = new LendingPool(address(reserveManager));

        // =========================================================
        // 6. CONNECT RESERVE MANAGER <-> LENDING POOL
        // =========================================================

        reserveManager.setLendingPool(address(lendingPool));

        // =========================================================
        // 7. DEPLOY RISK MANAGER
        // =========================================================

        riskManager = new RiskManager(address(reserveManager), address(priceOracle), address(lendingPool));

        // =========================================================
        // 8. CONNECT LENDING POOL <-> RISK MANAGER
        // =========================================================

        lendingPool.setRiskManager(address(riskManager));

        // =========================================================
        // 9. CONFIGURE WETH RESERVE
        // =========================================================

        reserveManager.configureReserve(address(weth), 18, COLLATERAL_FACTOR, LIQUIDATION_THRESHOLD, LIQUIDATION_BONUS);

        // =========================================================
        // 10. CONFIGURE USDC RESERVE
        // =========================================================

        reserveManager.configureReserve(address(usdc), 6, COLLATERAL_FACTOR, LIQUIDATION_THRESHOLD, LIQUIDATION_BONUS);

        // =========================================================
        // 11. SET INTEREST RATE MODEL
        // =========================================================

        reserveManager.setInterestRateModel(address(weth), address(interestRateModel));

        reserveManager.setInterestRateModel(address(usdc), address(interestRateModel));

        // =========================================================
        // 12. SET ORACLE PRICES
        // =========================================================

        priceOracle.setPrice(address(weth), WETH_PRICE, 8);

        priceOracle.setPrice(address(usdc), USDC_PRICE, 8);

        vm.stopBroadcast();

        // =========================================================
        // DEPLOYMENT SUMMARY
        // =========================================================

        console2.log("");
        console2.log("========================================");
        console2.log("DEPLOYMENT SUCCESSFUL");
        console2.log("========================================");

        console2.log("WETH:");
        console2.log(address(weth));

        console2.log("USDC:");
        console2.log(address(usdc));

        console2.log("Price Oracle:");
        console2.log(address(priceOracle));

        console2.log("Interest Rate Model:");
        console2.log(address(interestRateModel));

        console2.log("Reserve Manager:");
        console2.log(address(reserveManager));

        console2.log("Lending Pool:");
        console2.log(address(lendingPool));

        console2.log("Risk Manager:");
        console2.log(address(riskManager));

        console2.log("========================================");
        console2.log("CONFIGURATION");
        console2.log("========================================");

        console2.log("Collateral Factor: 80%");
        console2.log("Liquidation Threshold: 85%");
        console2.log("Liquidation Bonus: 5%");

        console2.log("========================================");
    }
}
