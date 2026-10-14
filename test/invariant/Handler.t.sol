// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";

contract Handler is Test {
    LendingPool public pool;
    MockUSDC public usdc;
    MockPriceOracle public oracle;
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;
    uint256 public totalLiquidatedCollateral;
    address[] public actors;
    mapping(address => bool) public isActor;

    constructor(LendingPool _pool, MockUSDC _usdc, MockPriceOracle _oracle) {
        pool = _pool;
        usdc = _usdc;
        oracle = _oracle;
    }

    function _addActor(address user) internal {
        if (!isActor[user]) {
            isActor[user] = true;
            actors.push(user);
        }
    }

    function getActorsLength() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 index) external view returns (address) {
        return actors[index];
    }

    function _getActor(uint256 actorSeed) internal view returns (address) {
        if (actors.length == 0) {
            return address(0);
        }
        uint256 index = actorSeed % actors.length;
        return actors[index];
    }

    function updatePrice(uint256 newPrice) public {
        newPrice = bound(newPrice, 500, 4000);
        oracle.setPrice(newPrice);
    }

    function depositCollateral(uint256 amount, address user) public {
        amount = bound(amount, 1 ether, 100 ether);
        vm.assume(user != address(pool));
        vm.assume(user != address(this));
        vm.assume(user != address(0));
        vm.deal(user, amount);
        vm.prank(user);
        pool.depositCollateral{value: amount}();
        totalDeposited += amount;
        _addActor(user);
    }

    function withdrawCollateral(uint256 amount, uint256 actorSeed) public {
        address user = _getActor(actorSeed);
        if (user == address(0)) return;
        uint256 collateral = pool.getCollateralBalance(user);
        if (collateral == 0) return;
        amount = bound(amount, 1, collateral);
        vm.prank(user);
        pool.withdrawCollateral(amount);
        totalWithdrawn += amount;
    }

    function borrow(uint256 amount, uint256 actorSeed) public {
        address user = _getActor(actorSeed);
        if (user == address(0)) return;
        uint256 maxBorrow = pool.getMaxBorrowAmount(user);
        uint256 currentDebt = pool.getDebtBalance(user);
        if (currentDebt >= maxBorrow) return;
        uint256 availableToBorrow = maxBorrow - currentDebt;
        amount = bound(amount, 1, availableToBorrow);
        vm.prank(user);
        pool.borrow(amount);
    }

    function repay(uint256 amount, uint256 actorSeed) public {
        address user = _getActor(actorSeed);
        if (user == address(0)) return;
        uint256 debt = pool.getDebtBalance(user);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        vm.startPrank(user);
        usdc.approve(address(pool), amount * 1e18);
        pool.repay(amount);
        vm.stopPrank();
    }

    function liquidate(uint256 amount, uint256 borrowSeed, uint256 liquidatorSeed) public {
        address borrower = _getActor(borrowSeed);
        address liquidator = _getActor(liquidatorSeed);
        if (borrower == address(0) || liquidator == address(0)) return;
        if (borrower == liquidator) return;
        uint256 healthFactor = pool.getHealthFactor(borrower);
        if (healthFactor >= 1e18) return;
        uint256 debt = pool.getDebtBalance(borrower);
        if (debt == 0) return;
        uint256 price = oracle.getPrice();
        uint256 collateral = pool.getCollateralBalance(borrower);
        uint256 collateralValue = collateral * price / 1e18;
        uint256 maxDebtByCollateral = collateralValue * 100 / 105;
        uint256 maxLiquidation = debt > maxDebtByCollateral ? maxDebtByCollateral : debt;
        if (maxLiquidation == 0) return;
        amount = bound(amount, 1, maxLiquidation);
        usdc.mint(liquidator, amount * 1e18);
        vm.startPrank(liquidator);
        uint256 tokenAmount = amount * 1e18;
        usdc.approve(address(pool), tokenAmount);
        pool.liquidate(borrower, amount);
        vm.stopPrank();
        uint256 collateralAfter = pool.getCollateralBalance(borrower);
        uint256 seizedCollateral = collateral - collateralAfter;
        totalLiquidatedCollateral += seizedCollateral;
    }
}
