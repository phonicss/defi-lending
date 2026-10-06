//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

contract LendingPool {

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

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);

    IERC20 public immutable loanToken;
    IPriceOracle public immutable priceOracle;
    uint256 public constant MAX_LTV = 75;
    uint256 public constant LTV_PRECISION = 100;
    uint256 public constant HEALTH_FACTOR_PRECISION = 1e18;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address => uint256) private collateralBalance;
    mapping(address => uint256) private debtBalance;

    constructor(address _loanToken, address _oracle) {
        if (_loanToken == address(0)) revert ZeroAddress();
        loanToken = IERC20(_loanToken);
        priceOracle = IPriceOracle(_oracle);
    }

    function depositCollateral () external payable {
        if (msg.value == 0) revert ZeroAmount ();
        collateralBalance[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    function getCollateralBalance (address user) external view returns (uint256) {
        return collateralBalance[user];
    }

    function withdrawCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (collateralBalance[msg.sender] < amount) revert InsufficientCollateral(amount, collateralBalance[msg.sender]);
        //check if user has enough collateral to cover their debt after withdrawal
        uint256 remainingCollateral = collateralBalance[msg.sender] - amount;
        uint256 remainingCollateralValue = remainingCollateral * priceOracle.getPrice() / 1e18;
        uint256 maxDebtAfterWithdrawal = remainingCollateralValue * MAX_LTV / LTV_PRECISION;
        if (debtBalance[msg.sender] > maxDebtAfterWithdrawal) revert UnderCollateralizedDebt(debtBalance[msg.sender], maxDebtAfterWithdrawal);
        collateralBalance[msg.sender] -= amount;
        emit Withdrawn(msg.sender, amount);
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success)  revert TransferFailed();
    }

    /// @dev Converts ETH collateral from wei to its USD value using the oracle price.
    function getCollateralValue(address user) external view returns (uint256) {
        return _getCollateralValue(user); 
    }

    function _getCollateralValue(address user) internal view returns (uint256) {
        return (collateralBalance[user] * priceOracle.getPrice())/1e18; 
    }


    function getMaxBorrowAmount(address user) external view returns (uint256) {
        return _getMaxBorrowAmount(user);
    }

    function _getMaxBorrowAmount(address user) internal view returns (uint256) {
        return (_getCollateralValue(user) * MAX_LTV)/LTV_PRECISION;
    }

    function getDebtBalance(address user) external view returns (uint256) {
        return _getDebtBalance(user);
    }

    function _getDebtBalance(address user) internal view returns (uint256) {
        return debtBalance[user];
    }

    function borrow(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 maxBorrow = _getMaxBorrowAmount(msg.sender);
        uint256 newDebt = debtBalance[msg.sender] + amount;
        if (newDebt > maxBorrow) {
            revert BorrowLimitExceeded(newDebt, maxBorrow);
        }
        debtBalance[msg.sender] = newDebt;
        emit Borrowed(msg.sender, amount);
        uint256 tokenAmount = amount * 1e18;
        bool result = loanToken.transfer(msg.sender, tokenAmount);
        if (!result) revert TransferFailed();
    }

    function repay(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 userDebt = debtBalance[msg.sender];
        if (amount > userDebt) revert RepayExceededDebt(amount, userDebt);
        uint256 tokenAmount = amount * 1e18;
        bool transferResult = loanToken.transferFrom(msg.sender, address(this), tokenAmount);
        if (!transferResult) revert TransferFailed();
        debtBalance[msg.sender] -= amount;
        emit Repaid(msg.sender, amount);
    }

    function getHealthFactor(address user) external view returns (uint256) {
       return _getHealthFactor(user);
    }

    function _getHealthFactor(address user) internal view returns (uint256) {
        uint256 debt = _getDebtBalance(user);
        if (debt == 0) return type(uint256).max;
        uint256 maxDebt = _getMaxBorrowAmount(user);
        uint256 healthFactor = maxDebt * HEALTH_FACTOR_PRECISION / debt;
        return healthFactor;
    }

    function liquidate(address user, uint256 amount) external {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_getHealthFactor(user) >= MIN_HEALTH_FACTOR) revert HealthFactorOk();
        uint256 userDebt = _getDebtBalance(user);
        if (amount > userDebt) revert LiquidationExceededDebt(amount, userDebt);
        uint256 collateralToSeize = amount * 1e18 / priceOracle.getPrice();
        if (collateralToSeize > collateralBalance[user]) revert InsufficientCollateralForLiquidation(collateralBalance[user], collateralToSeize);
        uint256 tokenAmount = amount * 1e18;
        debtBalance[user] -= amount;
        collateralBalance[user] -= collateralToSeize;
        bool transferResult = loanToken.transferFrom(msg.sender, address(this), tokenAmount);
        if (!transferResult) revert TransferFailed();
        (bool success, ) = payable(msg.sender).call{value: collateralToSeize}("");
        if (!success) revert TransferFailed();
    }


}  