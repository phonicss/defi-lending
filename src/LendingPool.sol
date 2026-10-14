//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title ETH-Collateralized Lending Pool
/// @notice Allows users to deposit ETH collateral, borrow loan tokens,
/// repay debt, withdraw collateral, and liquidate unhealthy positions.
/// @dev Educational DeFi lending implementation using an external price oracle.
///      Loan-token transfers assume 18 decimals.

contract LendingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientCollateral(uint256 requested, uint256 available);
    error BorrowLimitExceeded(uint256 requestedDebt, uint256 maxDebt);
    error TransferFailed();
    error RepayExceededDebt(uint256 requestedRepay, uint256 currentDebt);
    error LiquidationExceededDebt(uint256 requestedLiquidation, uint256 currentDebt);
    error UnderCollateralizedDebt(uint256 currentDebt, uint256 maxDebtAfterWithdraw);
    error HealthFactorOk();
    error InsufficientCollateralForLiquidation(uint256 balance, uint256 liquidation);
    error HealthFactorNotImproved(uint256 startHF, uint256 endHF);

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed liquidator, address indexed user, uint256 debtCovered, uint256 collateralSeized);

    IERC20 public immutable loanToken;
    IPriceOracle public immutable priceOracle;
    uint256 public constant MAX_LTV = 70;
    uint256 public constant LIQUIDATION_THRESHOLD = 75;
    uint256 public constant LTV_PRECISION = 100;
    uint256 public constant HEALTH_FACTOR_PRECISION = 1e18;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_BONUS = 5;
    uint256 public constant LIQUIDATION_PRECISION = 100;

    mapping(address => uint256) private collateralBalance;
    mapping(address => uint256) private debtBalance;

    constructor(address _loanToken, address _oracle) {
        if (_loanToken == address(0)) revert ZeroAddress();
        if (_oracle == address(0)) revert ZeroAddress();
        loanToken = IERC20(_loanToken);
        priceOracle = IPriceOracle(_oracle);
    }

    /// @notice Deposits native ETH as collateral.
    /// @dev The deposited amount is taken from msg.value and accounted for in wei.
    function depositCollateral() external payable {
        if (msg.value == 0) revert ZeroAmount();
        collateralBalance[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Returns the amount of ETH collateral deposited by a user in wei.
    /// @param user The address of the user.
    /// @return The amount of ETH collateral deposited by the user in wei.
    function getCollateralBalance(address user) external view returns (uint256) {
        return collateralBalance[user];
    }

    /// @notice Withdraws ETH collateral while ensuring the remaining position does not exceed the maximum LTV.
    /// @dev map holds balance in wei.
    /// @param amount The amount of ETH to withdraw in wei.
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (collateralBalance[msg.sender] < amount) {
            revert InsufficientCollateral(amount, collateralBalance[msg.sender]);
        }
        uint256 remainingCollateral = collateralBalance[msg.sender] - amount;
        uint256 remainingCollateralValue = remainingCollateral * priceOracle.getPrice() / 1e18;
        uint256 maxDebtAfterWithdrawal = remainingCollateralValue * MAX_LTV / LTV_PRECISION;
        if (debtBalance[msg.sender] > maxDebtAfterWithdrawal) {
            revert UnderCollateralizedDebt(debtBalance[msg.sender], maxDebtAfterWithdrawal);
        }
        collateralBalance[msg.sender] -= amount;
        emit Withdrawn(msg.sender, amount);
        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    /// @notice Returns the USD value of a user's ETH collateral using the oracle price.
    /// @dev Converts ETH collateral from wei to its USD value using the oracle price.
    /// @param user The address of the user.
    /// @return The USD value of the user's ETH collateral in whole units (not wei).
    function getCollateralValue(address user) external view returns (uint256) {
        return _getCollateralValue(user);
    }

    function _getCollateralValue(address user) internal view returns (uint256) {
        return (collateralBalance[user] * priceOracle.getPrice()) / 1e18;
    }

    /// @notice Returns the maximum amount of loan tokens a user can borrow based on their collateral and the maximum LTV.
    /// @param user The address of the user.
    /// @return The maximum amount of loan tokens the user can borrow in whole units (not wei).
    function getMaxBorrowAmount(address user) external view returns (uint256) {
        return _getMaxBorrowAmount(user);
    }

    function _getMaxBorrowAmount(address user) internal view returns (uint256) {
        return (_getCollateralValue(user) * MAX_LTV) / LTV_PRECISION;
    }

    /// @notice Returns the collateral-adjusted debt threshold used to determine liquidation eligibility.
    /// @param user The address of the user.
    /// @return The liquidation threshold value in whole units (not wei).
    function getLiquidationThresholdValue(address user) external view returns (uint256) {
        return _getLiquidationThresholdValue(user);
    }

    function _getLiquidationThresholdValue(address user) internal view returns (uint256) {
        return (_getCollateralValue(user) * LIQUIDATION_THRESHOLD) / LTV_PRECISION;
    }

    /// @notice Returns the current debt balance of a user in whole units (not wei).
    /// @param user The address of the user.
    /// @return The current debt balance of the user in whole units (not wei).
    function getDebtBalance(address user) external view returns (uint256) {
        return _getDebtBalance(user);
    }

    function _getDebtBalance(address user) internal view returns (uint256) {
        return debtBalance[user];
    }

    /// @notice allows users to borrow loan tokens against their ETH collateral, without exceeding the maximum LTV
    /// @dev Debt accounting uses whole loan-token units. Token transfers assume 18 decimals.
    /// @param amount The amount of loan tokens to borrow in whole units (not wei).
    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 maxBorrow = _getMaxBorrowAmount(msg.sender);
        uint256 newDebt = debtBalance[msg.sender] + amount;
        if (newDebt > maxBorrow) {
            revert BorrowLimitExceeded(newDebt, maxBorrow);
        }
        debtBalance[msg.sender] = newDebt;
        emit Borrowed(msg.sender, amount);
        uint256 tokenAmount = amount * 1e18;
        loanToken.safeTransfer(msg.sender, tokenAmount);
    }

    /// @notice allows users to repay their debt in loan tokens.
    /// @dev Debt accounting uses whole loan-token units. Token transfers assume 18 decimals.
    /// @param amount The amount of loan tokens to repay in whole units (not wei).
    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 userDebt = debtBalance[msg.sender];
        if (amount > userDebt) revert RepayExceededDebt(amount, userDebt);
        uint256 tokenAmount = amount * 1e18;
        loanToken.safeTransferFrom(msg.sender, address(this), tokenAmount);
        debtBalance[msg.sender] -= amount;
        emit Repaid(msg.sender, amount);
    }

    /// @notice Returns the health factor of a user, which indicates their financial health.
    /// @param user The address of the user.
    /// @return The health factor scaled by 1e18, where 1e18 represents 1.0.
    /// @dev If debt = 0 functions returns type(uint256).max, indicating no debt and a healthy position.
    function getHealthFactor(address user) external view returns (uint256) {
        return _getHealthFactor(user);
    }

    function _getHealthFactor(address user) internal view returns (uint256) {
        uint256 debt = _getDebtBalance(user);
        if (debt == 0) return type(uint256).max;
        uint256 threshold = _getLiquidationThresholdValue(user);
        uint256 healthFactor = threshold * HEALTH_FACTOR_PRECISION / debt;
        return healthFactor;
    }

    /// @notice allows users to liquidate undercollateralized positions, seizing collateral and repaying debt.
    /// @dev Debt accounting uses whole loan-token units and token transfers assume 18 decimals.
    ///      Liquidation is allowed only when HF < 1e18, applies a 5% collateral bonus,
    ///      and must improve the borrower's health factor.
    /// @param user The address of the user to liquidate.
    /// @param amount The amount of loan tokens to repay on behalf of the user in whole units (not wei).
    function liquidate(address user, uint256 amount) external nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 startingHealthFactor = _getHealthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) revert HealthFactorOk();
        uint256 userDebt = _getDebtBalance(user);
        if (amount > userDebt) revert LiquidationExceededDebt(amount, userDebt);
        uint256 collateralToSeize = amount * 1e18 / priceOracle.getPrice();
        uint256 bonusCollateral = collateralToSeize * LIQUIDATION_BONUS / LIQUIDATION_PRECISION;
        uint256 totalCollateralToSeize = collateralToSeize + bonusCollateral;
        if (totalCollateralToSeize > collateralBalance[user]) {
            revert InsufficientCollateralForLiquidation(collateralBalance[user], totalCollateralToSeize);
        }
        uint256 tokenAmount = amount * 1e18;
        debtBalance[user] -= amount;
        collateralBalance[user] -= totalCollateralToSeize;
        uint256 endingHealthFactor = _getHealthFactor(user);
        if (startingHealthFactor >= endingHealthFactor) {
            revert HealthFactorNotImproved(startingHealthFactor, endingHealthFactor);
        }
        emit Liquidated(msg.sender, user, amount, totalCollateralToSeize);
        loanToken.safeTransferFrom(msg.sender, address(this), tokenAmount);
        (bool success,) = payable(msg.sender).call{value: totalCollateralToSeize}("");
        if (!success) revert TransferFailed();
    }
}
