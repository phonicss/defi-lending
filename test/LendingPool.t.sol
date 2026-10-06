// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockPriceOracle} from "../src/mocks/MockPriceOracle.sol";

contract LendingPoolTest is Test {
    LendingPool pool;
    address alice;
    address bob;
    MockUSDC usdc;
    MockPriceOracle oracle;
    
    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockPriceOracle(2000);
        pool = new LendingPool(address(usdc), address(oracle));
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(alice, 10 ether);
        usdc.mint(address(pool), 100_000 ether);
    }   

    function test_DepositCollateral() public {
        vm.prank(alice);
        pool.depositCollateral{value: 2 ether}();
        uint256 collateralBalance = pool.getCollateralBalance(alice);
        assertEq(collateralBalance, 2 ether);
    }

    function test_RevertWhenDepositZero() public {
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        vm.prank(alice);
        pool.depositCollateral{value: 0 ether}();
    }

    function test_WithdrawCollateral() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 5 ether}();
        uint256 collateralBalance = pool.getCollateralBalance(alice);
        assertEq(collateralBalance, 5 ether);
        assertEq(alice.balance, 5 ether);
        assertEq(address(pool).balance, 5 ether);
        pool.withdrawCollateral(2 ether);
        collateralBalance = pool.getCollateralBalance(alice);
        assertEq(collateralBalance, 3 ether);
        assertEq(alice.balance, 7 ether);
        assertEq(address(pool).balance, 3 ether);
        vm.stopPrank();
    }

    function test_RevertWhenWithdrawExceedsCollateral() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 5 ether}();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientCollateral.selector, 6 ether, 5 ether));
        pool.withdrawCollateral(6 ether);
        uint256 collateralBalance = pool.getCollateralBalance(alice);
        assertEq(collateralBalance, 5 ether);
        assertEq(alice.balance, 5 ether);
        assertEq(address(pool).balance, 5 ether);
        vm.stopPrank();
    }

    function test_LoanTokenIsConfigured() public view{
        assertEq(address(pool.loanToken()), address(usdc));
    }

    function test_PoolHasInitialLiquidity() public view {
        assertEq(usdc.balanceOf(address(pool)), 100_000 ether);
    }

    function test_PriceOracleIsConfigured() public view {
        assertEq(address(pool.priceOracle()), address(oracle));
    }

    function test_OracleInitialPrice() public view {
        assertEq(oracle.getPrice(), 2000); 
    }

    function test_CollateralValueIsConfigured() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        uint256 collateralValue = pool.getCollateralValue(alice);
        vm.stopPrank();
        assertEq(collateralValue, 14_000);
    }

     function test_CollateralValueIsConfigured2() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 0.5 ether}();
        uint256 collateralValue = pool.getCollateralValue(alice);
        vm.stopPrank();
        assertEq(collateralValue, 1_000);
    }

    function test_GetMaxBorrowAmount() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        vm.stopPrank();
        assertEq(pool.getMaxBorrowAmount(alice), 10_500);
    }

     function test_BorrowedValueIsConfigured() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        pool.borrow(5000);
        vm.stopPrank();
        assertEq(pool.getDebtBalance(alice), 5_000);
        assertEq(usdc.balanceOf(alice), 5000*1e18);
        assertEq(usdc.balanceOf(address(pool)), 95000*1e18);
    }

     function test_RevertWhenBorrowExceedsMaxBorrow() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.BorrowLimitExceeded.selector, 11_000, 10_500));
        pool.borrow(11000);
        vm.stopPrank();
    }

    function test_RepayDebtIsConfigures() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        pool.borrow(5000);
        usdc.approve(address(pool), 2000e18);
        pool.repay(2000);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 3000e18);
        assertEq(pool.getDebtBalance(alice), 3000);
        assertEq(usdc.balanceOf(address(pool)), 97000e18);
    }

    function test_AcceptableWithdrawal() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        pool.borrow(5000);
        pool.withdrawCollateral(3 ether);
        vm.stopPrank();
        uint256 collateralBalance = pool.getCollateralBalance(alice);
        assertEq(collateralBalance, 4 ether);
        assertEq(pool.getCollateralValue(alice), 8000);
        uint256 maxDebt = pool.getMaxBorrowAmount(alice);
        assertEq(maxDebt, 6000);
        assertEq(pool.getDebtBalance(alice), 5000);
        assertEq(alice.balance, 6 ether);
    }
    
    function test_NotAcceptableWithdrawal() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        pool.borrow(5000);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnderCollateralizedDebt.selector, 5000, 3000));
        pool.withdrawCollateral(5 ether);
        vm.stopPrank();
        assertEq(pool.getCollateralBalance(alice), 7 ether);
        assertEq(pool.getDebtBalance(alice), 5000);
        assertEq(alice.balance, 3 ether);
        assertEq(address(pool).balance, 7 ether);
    }

    function test_HealthFactorIsConfigures() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        pool.borrow(5000);
        vm.stopPrank();
        assertEq(pool.getHealthFactor(alice), 2.1e18);
    }

    function test_HealthFactorDropsWhenPriceDrops() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        pool.borrow(5000);
        vm.stopPrank();
        uint256 hfBefore = pool.getHealthFactor(alice);
        assertEq(hfBefore, 2.1e18);
        oracle.setPrice(900);
        uint256 collateralBalance = pool.getCollateralBalance(alice);
        assertEq(collateralBalance, 7e18);
        uint256 debt = pool.getDebtBalance(alice);
        assertEq(debt, 5000);
        uint256 collateralValue = pool.getCollateralValue(alice);
        assertEq(collateralValue, 6300);
        uint256 maxDebt = pool.getMaxBorrowAmount(alice);
        assertEq(maxDebt, 4725);
        uint256 hfAfter = pool.getHealthFactor(alice);
        assertEq(hfAfter, 0.945e18);

    }

    function test_CantLiqudateWhenHFisOkay() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        pool.borrow(5000);
        vm.stopPrank();
        vm.startPrank(bob);
        vm.expectRevert(LendingPool.HealthFactorOk.selector);
        pool.liquidate(alice, 1000);
        vm.stopPrank();
    }

    function test_CorrectLiqudation() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        pool.borrow(5000);
        oracle.setPrice(900);
        assertEq(pool.getHealthFactor(alice), 0.945e18);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.mint(bob, 1000e18);
        usdc.approve(address(pool), 1000e18);
        pool.liquidate(alice, 1000);
        vm.stopPrank();
        assertEq(pool.getHealthFactor(alice), 0.99375e18);
        assertEq(pool.getDebtBalance(alice), 4000);
        uint256 amount = 1000;
        uint256 collateralToSeize = amount * 1e18 / oracle.getPrice();
        assertEq(pool.getCollateralBalance(alice), 7 ether - collateralToSeize);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(address(pool)), 96000e18);
        uint256 expectedCollateralToSeize = 1000 * 1e18 / oracle.getPrice();
        assertEq(bob.balance, expectedCollateralToSeize);
        assertEq(address(pool).balance, 7 ether - collateralToSeize);
    }
}