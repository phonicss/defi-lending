# DeFi Lending Protocol

A minimal overcollateralized lending protocol built in Solidity and tested with Foundry.

Users deposit native ETH as collateral and borrow an ERC-20 loan token against it. The protocol tracks collateral value, debt, loan-to-value limits, health factors, and allows third-party liquidators to liquidate unhealthy positions.

The project focuses on lending mechanics, liquidation design, protocol accounting, and stateful invariant testing rather than production deployment.

> **Educational project only. Not audited and not intended for production use.**

## Features

- Native ETH collateral deposits
- ERC-20 borrowing
- Collateral-based borrowing limits
- 70% maximum loan-to-value (LTV)
- 75% liquidation threshold
- Health factor calculation
- Partial debt repayment
- Collateral withdrawals with solvency checks
- Third-party liquidations
- 5% liquidation bonus
- Health-factor improvement requirement
- OpenZeppelin `SafeERC20`
- Reentrancy protection
- Custom errors and events
- Unit tests
- Fuzz tests
- Stateful invariant tests

## Architecture

The protocol consists of a small set of components:

```text
                  ┌──────────────────┐
                  │   Price Oracle   │
                  │    ETH / USD     │
                  └────────┬─────────┘
                           │
                           ▼
┌──────────┐      ┌──────────────────┐      ┌───────────────┐
│   User   │─────▶│   LendingPool    │─────▶│  Loan Token   │
│          │ ETH  │                  │ ERC20│  (MockUSDC)   │
└──────────┘      │ collateral       │      └───────────────┘
                  │ debt             │
                  │ LTV              │
                  │ health factor    │
                  │ liquidation      │
                  └──────────────────┘
                           ▲
                           │
                    ┌──────┴──────┐
                    │ Liquidator  │
                    └─────────────┘
```

### LendingPool

`LendingPool.sol` contains the core protocol logic:

- ETH collateral accounting
- debt accounting
- borrowing
- repayment
- withdrawals
- health-factor calculation
- liquidation

### Price Oracle

`IPriceOracle` abstracts ETH/USD price retrieval.

The test environment uses `MockPriceOracle`, allowing the ETH price to be changed during tests to simulate market movements and liquidation scenarios.

### Loan Token

The test environment uses `MockUSDC`.

For simplicity, the current protocol assumes that the loan token uses 18 decimals.

## Protocol Parameters

| Parameter | Value |
|---|---:|
| Maximum LTV | 70% |
| Liquidation Threshold | 75% |
| Minimum Health Factor | 1.0 |
| Liquidation Bonus | 5% |
| Health Factor Precision | `1e18` |
| Loan Token Decimals | 18 |

## Borrowing

The USD value of deposited collateral is calculated as:

```text
collateralValue = collateralETH × ETHPrice
```

The maximum amount a user may borrow is:

```text
maxBorrow = collateralValue × 70%
```

Example:

```text
Collateral: 7 ETH
ETH price:  $2,000

Collateral value = $14,000
Maximum borrow   = $14,000 × 70%
                 = $9,800
```

A borrow transaction reverts if the resulting debt exceeds this limit.

## Health Factor

Liquidation eligibility is based on a health factor:

```text
liquidationThresholdValue = collateralValue × 75%

healthFactor =
    liquidationThresholdValue / debt
```

The Solidity implementation scales the health factor by `1e18`.

```text
HF >= 1e18  → position is not liquidatable
HF <  1e18  → position is liquidatable
```

If a user has no debt, the protocol returns `type(uint256).max`.

### Example

```text
Collateral: 7 ETH
ETH price:  $900
Debt:       $5,000

Collateral value = $6,300

Liquidation threshold value:
$6,300 × 75% = $4,725

Health factor:
$4,725 / $5,000 = 0.945
```

The position can therefore be liquidated.

## Liquidation

A liquidator can repay part of the debt of an unhealthy borrower in exchange for the corresponding ETH collateral plus a 5% bonus.

For a debt repayment of `x`:

```text
base collateral value = x
liquidation bonus     = 5%
collateral seized     = x × 1.05
```

The protocol requires:

```text
startingHealthFactor < 1e18
```

and, after the liquidation:

```text
endingHealthFactor > startingHealthFactor
```

Otherwise the transaction reverts with `HealthFactorNotImproved`.

This prevents liquidations that make an already unhealthy position even worse.

## Insolvency and Bad Debt

During development, testing exposed an important liquidation edge case.

Consider:

```text
Collateral: 7 ETH
Debt:       $5,000
ETH price:  $700
```

The collateral is worth:

```text
7 × $700 = $4,900
```

Therefore:

```text
collateralValue < debt

$4,900 < $5,000
```

The position is insolvent and contains:

```text
$5,000 - $4,900 = $100
```

of bad debt.

A naive partial liquidation with a 5% bonus can make this worse.

For example, covering `$1,000` of debt requires approximately `$1,050` of collateral value:

```text
Debt:
$5,000 → $4,000

Collateral:
$4,900 → $3,850

Bad debt:
$100 → $150
```

The protocol therefore rejects a liquidation when the borrower's health factor does not improve.

### Liquidation limitation

The health-factor improvement condition also creates a region where a position may still have enough collateral to cover its nominal debt but cannot be partially liquidated economically with the fixed 5% bonus.

Ignoring integer rounding, liquidation improves the collateral-to-debt ratio when:

```text
CollateralValue > Debt × 1.05
```

For a `$5,000` debt and `7 ETH` collateral:

```text
7 × ETHPrice > $5,250

ETHPrice > $750
```

This produces approximately four risk regions:

```text
ETH > $952.38
    Healthy position

$750 < ETH < $952.38
    Unhealthy but partial liquidation improves health

$714.29 < ETH <= $750
    Collateral still covers nominal debt,
    but a fixed 5% liquidation bonus can prevent
    health-improving partial liquidation

ETH < $714.29
    Insolvent position / bad debt
```

A production lending protocol would require a more complete bad-debt and liquidation mechanism.

## Testing

The project uses Foundry.

The test suite includes:

- deterministic unit tests
- revert-path tests
- fuzz tests
- price-drop scenarios
- liquidation tests
- insolvency tests
- stateful invariant tests

Run all tests with:

```bash
forge test
```

Run with detailed traces:

```bash
forge test -vvvv
```

Format the project with:

```bash
forge fmt
```

### Fuzz Testing

Fuzz tests cover operations such as:

- collateral deposits
- valid borrowing
- borrowing above the maximum LTV

Foundry generates different inputs across hundreds of runs and checks that protocol properties continue to hold.

### Stateful Invariant Testing

A dedicated Handler executes sequences of actions against the protocol:

```text
deposit
withdraw
borrow
repay
update oracle price
liquidate
```

The invariant suite executes large randomized state-transition sequences rather than testing individual functions in isolation.

Two core accounting invariants are checked.

### Invariant 1 — Ghost accounting

```text
totalDeposited
- totalWithdrawn
- totalLiquidatedCollateral
==
actual ETH balance of LendingPool
```

### Invariant 2 — User accounting

```text
sum(collateralBalance[user])
==
actual ETH balance of LendingPool
```

These properties verify that protocol collateral accounting remains consistent across randomized sequences of deposits, withdrawals, borrowing, repayment, price changes, and liquidations.

At the current project checkpoint:

```text
29 tests passed
0 tests failed

Invariant runs: 256
Stateful calls: 128,000
```

## Security Measures

The implementation includes:

- `ReentrancyGuard`
- `SafeERC20`
- checks-effects-interactions where applicable
- custom errors
- borrow-limit validation
- withdrawal solvency validation
- liquidation eligibility validation
- liquidation collateral validation
- health-factor improvement validation
- zero-address constructor validation

## Known Limitations

This project intentionally remains a focused educational MVP.

It does **not** implement all requirements of a production lending protocol.

Known limitations include:

- Mock price oracle in tests
- no oracle freshness validation
- no protection against oracle manipulation
- no explicit zero-price oracle validation
- single native ETH collateral asset
- single loan asset
- fixed 18-decimal assumption for the loan token
- no interest-rate model
- no interest accrual
- no liquidity-provider share accounting
- no close factor
- no reserve or insurance fund
- no bad-debt resolution mechanism
- no governance
- no emergency pause mechanism
- no production deployment configuration
- no external security audit

Deeply undercollateralized positions may become impossible to liquidate through the current health-factor-improvement rule. A production protocol would require an explicit insolvency-resolution mechanism.

## Tech Stack

- Solidity
- Foundry
- OpenZeppelin Contracts

## Project Structure

```text
src/
├── LendingPool.sol
└── interfaces/
    └── IPriceOracle.sol

test/
├── LendingPool.t.sol
├── mocks/
│   ├── MockUSDC.sol
│   └── MockPriceOracle.sol
└── invariant/
    ├── Handler.t.sol
    └── LendingPoolInvariant.t.sol
```

The exact test-directory filenames may vary depending on the local project layout.

## Installation

Clone the repository:

```bash
git clone <repository-url>
cd defi_lending
```

Install dependencies:

```bash
forge install
```

Build:

```bash
forge build
```

Run tests:

```bash
forge test
```

## What I Learned

This project was built to understand lending protocols beyond basic Solidity syntax.

Key areas explored:

- collateral and debt accounting
- LTV-based borrowing
- liquidation thresholds
- health-factor design
- liquidation incentives
- insolvency and bad debt
- ERC-20 interaction with `SafeERC20`
- reentrancy protection
- Foundry unit testing
- fuzz testing
- stateful invariant testing
- protocol invariants versus individual function correctness
- economic edge cases in liquidation design

One of the most important findings was that a liquidation function can be technically correct while still creating undesirable economic behavior. A fixed liquidation bonus can worsen bad debt when a position becomes sufficiently undercollateralized, which makes insolvency handling a protocol-design problem rather than only a Solidity implementation problem.

## Disclaimer

This repository is an educational and portfolio project.

It has not been audited and must not be used with real funds.