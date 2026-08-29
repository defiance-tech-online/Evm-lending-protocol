// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {MockERC20} from "../src/tokens/MockERC20.sol";
import {ChainlinkPriceOracle} from "../src/oracles/ChainlinkPriceOracle.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {ReserveManager} from "../src/ReserveManager.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {RiskManager} from "../src/RiskManager.sol";

contract DeploySepolia is Script {
    // =============================================================
    // CONSTANTS
    // =============================================================

    uint256 internal constant COLLATERAL_FACTOR = 8_000; // 80%
    uint256 internal constant LIQUIDATION_THRESHOLD = 8_500; // 85%
    uint256 internal constant LIQUIDATION_BONUS = 500; // 5%

    // Maximum acceptable age of a Chainlink price.
    // uint256 internal constant MAX_STALENESS = 3 hours;
    uint256 internal constant ETH_MAX_STALENESS = 3 hours;
    uint256 internal constant USDC_MAX_STALENESS = 25 hours;

    // =============================================================
    // DEPLOYED CONTRACTS
    // =============================================================

    MockERC20 public weth;
    MockERC20 public usdc;

    ChainlinkPriceOracle public priceOracle;
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

        // =========================================================
        // CHAINLINK FEEDS
        // =========================================================

        address ethUsdFeed = vm.envAddress("SEPOLIA_ETH_USD_FEED");
        address usdcUsdFeed = vm.envAddress("SEPOLIA_USDC_USD_FEED");

        require(ethUsdFeed != address(0), "Deploy: zero ETH/USD feed");
        require(usdcUsdFeed != address(0), "Deploy: zero USDC/USD feed");

        console2.log("========================================");
        console2.log("SEPOLIA DEPLOYMENT");
        console2.log("========================================");

        console2.log("Deployer:");
        console2.log(deployer);

        console2.log("Chain ID:");
        console2.log(block.chainid);

        console2.log("ETH/USD Feed:");
        console2.log(ethUsdFeed);

        console2.log("USDC/USD Feed:");
        console2.log(usdcUsdFeed);

        console2.log("========================================");

        vm.startBroadcast(deployerPrivateKey);

        // =========================================================
        // 1. DEPLOY MOCK ASSETS
        // =========================================================

        weth = new MockERC20("Mock WETH", "mWETH", 18);

        usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        // =========================================================
        // 2. DEPLOY CHAINLINK PRICE ORACLE
        // =========================================================

        priceOracle = new ChainlinkPriceOracle();

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
        // 6. CONNECT RESERVE MANAGER -> LENDING POOL
        // =========================================================

        reserveManager.setLendingPool(address(lendingPool));

        // =========================================================
        // 7. DEPLOY RISK MANAGER
        // =========================================================

        riskManager = new RiskManager(address(reserveManager), address(priceOracle), address(lendingPool));

        // =========================================================
        // 8. CONNECT LENDING POOL -> RISK MANAGER
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
        // 11. SET INTEREST RATE MODELS
        // =========================================================

        reserveManager.setInterestRateModel(address(weth), address(interestRateModel));

        reserveManager.setInterestRateModel(address(usdc), address(interestRateModel));

        // =========================================================
        // 12. CONFIGURE CHAINLINK PRICE FEEDS
        // =========================================================

        // Mock WETH uses the real ETH/USD Chainlink feed.
        priceOracle.setFeed(address(weth), ethUsdFeed, ETH_MAX_STALENESS);

        // Mock USDC uses the real USDC/USD Chainlink feed.
        priceOracle.setFeed(address(usdc), usdcUsdFeed, USDC_MAX_STALENESS);

        vm.stopBroadcast();

        // =========================================================
        // DEPLOYMENT SUMMARY
        // =========================================================

        console2.log("");
        console2.log("========================================");
        console2.log("DEPLOYMENT SUCCESSFUL");
        console2.log("========================================");

        console2.log("Mock WETH:");
        console2.log(address(weth));

        console2.log("Mock USDC:");
        console2.log(address(usdc));

        console2.log("Chainlink Price Oracle:");
        console2.log(address(priceOracle));

        console2.log("Interest Rate Model:");
        console2.log(address(interestRateModel));

        console2.log("Reserve Manager:");
        console2.log(address(reserveManager));

        console2.log("Lending Pool:");
        console2.log(address(lendingPool));

        console2.log("Risk Manager:");
        console2.log(address(riskManager));

        console2.log("");
        console2.log("========================================");
        console2.log("CHAINLINK FEEDS");
        console2.log("========================================");

        console2.log("ETH/USD Feed:");
        console2.log(ethUsdFeed);

        console2.log("USDC/USD Feed:");
        console2.log(usdcUsdFeed);

        console2.log("Max Staleness:");
        console2.log(ETH_MAX_STALENESS);
        console2.log(USDC_MAX_STALENESS);

        console2.log("");
        console2.log("========================================");
        console2.log("PROTOCOL CONFIGURATION");
        console2.log("========================================");

        console2.log("Collateral Factor: 80%");
        console2.log("Liquidation Threshold: 85%");
        console2.log("Liquidation Bonus: 5%");

        console2.log("========================================");
    }
}
