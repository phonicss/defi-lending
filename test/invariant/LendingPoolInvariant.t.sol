// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {LendingPool} from "../../src/LendingPool.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {Handler} from "./Handler.t.sol";

contract LendingPoolInvariant is StdInvariant, Test {
    LendingPool pool;
    MockUSDC usdc;
    MockPriceOracle oracle;
    Handler handler;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockPriceOracle(2000);
        pool = new LendingPool(address(usdc), address(oracle));
        usdc.mint(address(pool), 100_000_000 ether);
        handler = new Handler(pool, usdc, oracle);
        targetContract(address(handler));
    }

    function invariant_ProtocolBalanceMatcherDeposits() public view {
        assertEq(
            handler.totalDeposited() - handler.totalWithdrawn() - handler.totalLiquidatedCollateral(),
            address(pool).balance
        );
    }

    function invariant_TotalCollateralMatchesPoolBalance() public view {
        uint256 totalCollateral;
        uint256 actorslength = handler.getActorsLength();

        for (uint256 i = 0; i < actorslength; i++) {
            address user = handler.getActor(i);
            uint256 userBalance = pool.getCollateralBalance(user);
            totalCollateral += userBalance;
        }

        assertEq(totalCollateral, address(pool).balance);
    }
}
