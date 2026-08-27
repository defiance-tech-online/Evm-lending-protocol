// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {MockERC20} from "../src/tokens/MockERC20.sol";
import {MockPriceOracle} from "../src/oracles/MockPriceOracle.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";

contract DeployMocks is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // =========================================================
        // TOKENS
        // =========================================================

        MockERC20 weth = new MockERC20("Mock WETH", "mWETH", 18);

        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        // =========================================================
        // ORACLE
        // =========================================================

        MockPriceOracle priceOracle = new MockPriceOracle();

        // =========================================================
        // INTEREST RATE MODEL
        // =========================================================

        InterestRateModel interestRateModel = new InterestRateModel();

        vm.stopBroadcast();

        // =========================================================
        // DEPLOYMENT OUTPUT
        // =========================================================

        console2.log("========================================");
        console2.log("MOCK DEPLOYMENTS");
        console2.log("========================================");

        console2.log("WETH:");
        console2.log(address(weth));

        console2.log("USDC:");
        console2.log(address(usdc));

        console2.log("Price Oracle:");
        console2.log(address(priceOracle));

        console2.log("Interest Rate Model:");
        console2.log(address(interestRateModel));

        console2.log("========================================");
    }
}
