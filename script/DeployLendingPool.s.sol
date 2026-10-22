// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {LendingPool} from "src/LendingPool.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";
import {MockPriceOracle} from "src/mocks/MockPriceOracle.sol";

contract DeployLendingPool is Script {
    function run() external {
        vm.startBroadcast();

        MockUSDC token = new MockUSDC();
        MockPriceOracle oracle = new MockPriceOracle(1000);
        LendingPool pool = new LendingPool(address(token), address(oracle));

        token.mint(address(pool), 100_000 * 1e18);

        vm.stopBroadcast();
    }
}
