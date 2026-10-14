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

    function test_RevertWhenLoanTokenIsZero() public {
        vm.expectRevert(LendingPool.ZeroAddress.selector);
        pool = new LendingPool(address(0), address(oracle));
    }

    function test_RevertWhenOracleIsZero() public {
        vm.expectRevert(LendingPool.ZeroAddress.selector);
        pool = new LendingPool(address(usdc), address(0));
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

    function test_LoanTokenIsConfigured() public view {
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
        assertEq(pool.getMaxBorrowAmount(alice), 9_800);
    }

    function test_BorrowedValueIsConfigured() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        pool.borrow(5000);
        vm.stopPrank();
        assertEq(pool.getDebtBalance(alice), 5_000);
        assertEq(usdc.balanceOf(alice), 5000 * 1e18);
        assertEq(usdc.balanceOf(address(pool)), 95000 * 1e18);
    }

    function test_RevertWhenBorrowExceedsMaxBorrow() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.BorrowLimitExceeded.selector, 11_000, 9_800));
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
        assertEq(maxDebt, 5600);
        assertEq(pool.getDebtBalance(alice), 5000);
        assertEq(alice.balance, 6 ether);
    }

    function test_NotAcceptableWithdrawal() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        pool.borrow(5000);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.UnderCollateralizedDebt.selector, 5000, 2800));
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
        uint256 liquidationThresholdValue = pool.getLiquidationThresholdValue(alice);
        assertEq(liquidationThresholdValue, 4725);
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
        uint256 amount = 1000;
        uint256 collateralToSeize = amount * 1e18 / oracle.getPrice();
        uint256 bonusCollateral = collateralToSeize * 5 / 100;
        uint256 totalCollateralToSeize = collateralToSeize + bonusCollateral;
        vm.expectEmit(true, true, false, true);
        emit LendingPool.Liquidated(bob, alice, amount, totalCollateralToSeize);
        pool.liquidate(alice, 1000);
        vm.stopPrank();
        assertEq(pool.getHealthFactor(alice), 0.98425e18);
        assertEq(pool.getDebtBalance(alice), 4000);
        assertEq(pool.getCollateralBalance(alice), 7 ether - totalCollateralToSeize);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(address(pool)), 96000e18);
        assertEq(bob.balance, totalCollateralToSeize);
        assertEq(address(pool).balance, 7 ether - totalCollateralToSeize);
    }

    function test_HealthFactorNotImprovedRevert() public {
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        pool.borrow(5000);
        oracle.setPrice(700);
        vm.stopPrank();
        usdc.mint(bob, 1000e18);
        vm.startPrank(bob);
        usdc.approve(address(pool), 1000e18);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.HealthFactorNotImproved.selector, 0.735e18, 0.72175e18));
        pool.liquidate(alice, 1000);
        vm.stopPrank();
        assertEq(pool.getDebtBalance(alice), 5000);
        assertEq(pool.getCollateralBalance(alice), 7 ether);
        assertEq(usdc.balanceOf(bob), 1000e18);
    }

    function testFuzz_DepositCollateral(uint256 amount) public {
        amount = uint256(bound(amount, 1 wei, 100 ether));
        vm.deal(alice, amount);
        vm.prank(alice);
        pool.depositCollateral{value: amount}();
        assertEq(pool.getCollateralBalance(alice), amount);
        assertEq(address(pool).balance, amount);
    }

    function testFuzz_Borrow(uint256 amount, uint256 borrowAmount) public {
        amount = bound(amount, 1 ether, 100 ether);
        vm.deal(alice, amount);
        vm.startPrank(alice);
        pool.depositCollateral{value: amount}();
        uint256 maxBorrow = pool.getMaxBorrowAmount(alice);
        uint256 poolLiquidity = usdc.balanceOf(address(pool)) / 1e18;
        uint256 borrowLimit = maxBorrow;
        if (poolLiquidity < maxBorrow) borrowLimit = poolLiquidity;
        borrowAmount = bound(borrowAmount, 1, borrowLimit);
        pool.borrow(borrowAmount);
        vm.stopPrank();
        assertEq(pool.getCollateralBalance(alice), amount);
        assertEq(address(pool).balance, amount);
        uint256 debt = pool.getDebtBalance(alice);
        assertEq(debt, borrowAmount);
        assertEq(usdc.balanceOf(alice), borrowAmount * 1e18);
        assertLe(debt, maxBorrow);
    }

    function testFuzz_RevertWhenBorrowExceedsMax(uint256 amount, uint256 excess) public {
        amount = bound(amount, 1 ether, 100 ether);
        vm.deal(alice, amount);
        vm.startPrank(alice);
        pool.depositCollateral{value: amount}();
        uint256 maxBorrow = pool.getMaxBorrowAmount(alice);
        excess = bound(excess, 1, 10_000);
        uint256 invalidBorrow = maxBorrow + excess;
        vm.expectRevert(abi.encodeWithSelector(LendingPool.BorrowLimitExceeded.selector, invalidBorrow, maxBorrow));
        pool.borrow(invalidBorrow);
        vm.stopPrank();
        assertEq(pool.getDebtBalance(alice), 0);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(pool.getCollateralBalance(alice), amount);
    }

    function test_DeepUnderwaterPositionCannotBePartiallyLiquidated() public {
        vm.deal(alice, 7 ether);
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        oracle.setPrice(2000);
        pool.borrow(5000);
        oracle.setPrice(700);
        vm.stopPrank();
        usdc.mint(bob, 1000e18);
        vm.startPrank(bob);
        usdc.approve(address(pool), 1000e18);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.HealthFactorNotImproved.selector, 0.735e18, 0.72175e18));
        pool.liquidate(alice, 1000);
    }

    function test_PositionBecomesInsolventBelowCriticalPrice() public {
        vm.deal(alice, 7 ether);
        vm.startPrank(alice);
        pool.depositCollateral{value: 7 ether}();
        oracle.setPrice(2000);
        pool.borrow(5000);
        oracle.setPrice(700);
        vm.stopPrank();
        uint256 collateralValue = pool.getCollateralValue(alice);
        uint256 debt = pool.getDebtBalance(alice);
        assertEq(collateralValue, 4900);
        assertEq(debt, 5000);
        assertLt(collateralValue, debt);
    }
}
