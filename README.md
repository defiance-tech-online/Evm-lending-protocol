# Production-Grade EVM Lending Protocol

A modular, overcollateralized lending protocol built in Solidity with **scaled-balance interest accounting, multi-asset collateral and borrowing, health-factor-based risk management, liquidations, Chainlink price feeds, fuzz testing, invariant testing, security testing, and Sepolia deployment**.

The project is designed to demonstrate the architecture and engineering practices behind EVM lending markets rather than being a simple deposit/withdraw smart contract.

> **Status:** Deployed and tested on Ethereum Sepolia
> **Tests:** 227 passing
> **Solidity:** `^0.8.24`
> **Framework:** Foundry
> **Oracle:** Chainlink Data Feeds

---

## Overview

The protocol allows users to:

* supply supported ERC-20 assets
* withdraw supplied assets
* use supplied assets as collateral
* borrow supported assets
* repay outstanding debt
* accrue supply and borrow interest
* maintain positions across multiple assets
* calculate borrowing capacity
* calculate account health factors
* liquidate unhealthy positions
* value assets using Chainlink price feeds

The protocol separates accounting, lending operations, risk calculations, interest-rate logic, and oracle infrastructure into independent contracts.

This creates a modular architecture similar to the separation of responsibilities used by larger DeFi lending systems.

---

## Architecture

```text
                         ┌──────────────────────────┐
                         │          User            │
                         └────────────┬─────────────┘
                                      │
                      supply / withdraw / borrow
                         repay / liquidate
                                      │
                                      ▼
                         ┌──────────────────────────┐
                         │       LendingPool        │
                         │                          │
                         │ User position accounting │
                         │ Protocol entry point     │
                         └───────┬──────────┬───────┘
                                 │          │
                    accounting   │          │ risk checks
                                 │          │
                                 ▼          ▼
                    ┌──────────────────┐  ┌──────────────────┐
                    │  ReserveManager  │  │   RiskManager    │
                    │                  │  │                  │
                    │ Reserve config   │  │ Borrow capacity  │
                    │ Scaled balances  │  │ Health factor    │
                    │ Interest indexes │  │ Withdraw safety  │
                    │ Interest accrual │  │ Liquidations     │
                    └────────┬─────────┘  └────────┬─────────┘
                             │                     │
                             │                     │ prices
                             ▼                     ▼
                    ┌──────────────────┐  ┌──────────────────────┐
                    │ InterestRateModel│  │ ChainlinkPriceOracle │
                    │                  │  │                      │
                    │ Borrow rate      │  │ Feed validation      │
                    │ Supply rate      │  │ Staleness protection │
                    └──────────────────┘  └──────────┬───────────┘
                                                     │
                                                     ▼
                                          ┌─────────────────────┐
                                          │ Chainlink Data Feeds│
                                          │                     │
                                          │ ETH / USD           │
                                          │ USDC / USD          │
                                          └─────────────────────┘
```

---

# Core Contracts

## `LendingPool.sol`

`LendingPool` is the primary user-facing protocol contract.

It manages:

* supply
* withdrawal
* borrowing
* repayment
* liquidation
* user positions
* supported asset tracking
* interaction with the reserve and risk layers

Example protocol flow:

```text
User
  │
  ├── supply()
  ├── withdraw()
  ├── borrow()
  ├── repay()
  └── liquidate()
        │
        ▼
   LendingPool
```

State-changing lending operations use reentrancy protection and ERC-20 transfers are handled through OpenZeppelin `SafeERC20`.

---

## `ReserveManager.sol`

`ReserveManager` owns reserve-level accounting and configuration.

Responsibilities include:

* reserve activation
* borrowing status
* token decimals
* collateral parameters
* liquidation parameters
* interest-rate model configuration
* supply index
* borrow index
* total scaled supply
* total scaled debt
* interest accrual

Each reserve maintains independent accounting state.

Conceptually:

```text
Reserve
│
├── active
├── borrowEnabled
├── decimals
│
├── totalScaledSupplied
├── totalScaledBorrowed
│
├── collateralFactor
├── liquidationThreshold
├── liquidationBonus
│
├── interestRateModel
│
├── supplyIndex
├── borrowIndex
│
└── lastUpdateTimestamp
```

Only the configured `LendingPool` can modify reserve accounting.

---

# Scaled-Balance Accounting

One of the core design features of the protocol is **scaled accounting**.

Instead of continuously updating every user's token balance as interest accrues, the protocol stores scaled principal balances.

For supplied assets:

```text
actual supplied balance
        =
scaled supplied balance × current supply index
```

For debt:

```text
actual debt
        =
scaled debt balance × current borrow index
```

In simplified WAD form:

```text
actualBalance = scaledBalance × currentIndex / 1e18
```

This means interest can accrue globally by updating reserve indexes rather than iterating over every user.

### Why scaled accounting?

Without scaled balances, interest accrual could require updating many individual positions.

With indexes:

```text
Users
 ├── Alice ── scaled balance
 ├── Bob   ── scaled balance
 └── Carol ── scaled balance

                │
                ▼

        Global Supply/Borrow Index
```

Updating one index effectively changes the current value of all positions.

This architecture also avoids unbounded loops over users during interest accrual.

---

# Interest Accrual

Each reserve tracks:

```text
borrowIndex
supplyIndex
lastUpdateTimestamp
```

Interest growth depends on:

```text
elapsed time
+
current utilization
+
interest-rate model
```

Conceptually:

```text
Utilization
    =
Total Borrowed / Total Supplied
```

The interest-rate model produces supply and borrow rates based on reserve utilization.

Borrow interest increases the borrow index when debt exists.

Supply interest accrues when supplied liquidity is actively being borrowed.

---

# Interest Rate Model

`InterestRateModel.sol` provides utilization-based interest rates.

Conceptually:

```text
Low utilization
      │
      ▼
Lower borrowing rate

High utilization
      │
      ▼
Higher borrowing rate
```

This creates an economic incentive for:

* additional liquidity when utilization rises
* repayment when borrowing becomes expensive

The model is separated from reserve accounting so the rate strategy can be replaced without rewriting the lending pool.

---

# Risk Management

`RiskManager.sol` evaluates account solvency.

The risk layer is responsible for:

* collateral valuation
* debt valuation
* borrowing capacity
* withdrawal safety
* health-factor calculation
* liquidation eligibility
* liquidation collateral calculation

---

## Collateral Factor

The collateral factor determines how much borrowing power an asset provides.

Current configuration:

```text
Collateral Factor = 80%
```

Example:

```text
$10,000 collateral

Borrowing capacity:

$10,000 × 80%
= $8,000
```

---

## Liquidation Threshold

Current configuration:

```text
Liquidation Threshold = 85%
```

The liquidation threshold is used when determining account health.

This is deliberately separate from the collateral factor.

```text
Collateral Factor
        │
        └── determines new borrowing capacity

Liquidation Threshold
        │
        └── determines solvency/liquidation boundary
```

---

# Health Factor

The protocol calculates an account's health based on liquidation-adjusted collateral and outstanding debt.

Conceptually:

```text
Health Factor
=
Liquidation-Adjusted Collateral Value
─────────────────────────────────────
Debt Value
```

Interpretation:

```text
HF > 1
Position healthy

HF = 1
Liquidation boundary

HF < 1
Position liquidatable
```

Accounts with no debt return the maximum `uint256` health factor.

---

# Liquidations

When an account becomes unhealthy:

```text
Health Factor < 1
```

another account may repay debt on behalf of the borrower and receive collateral plus a liquidation bonus.

Current configuration:

```text
Liquidation Bonus = 5%
```

Conceptually:

```text
Borrower becomes unhealthy
          │
          ▼
Liquidator repays debt
          │
          ▼
Protocol reduces borrower debt
          │
          ▼
Liquidator receives collateral
          +
       5% bonus
```

Liquidation accounting operates on the same scaled-balance model used by normal borrowing and supplying.

---

# Oracle Architecture

The protocol uses the `IPriceOracle` abstraction:

```solidity
interface IPriceOracle {
    function getPrice(address asset) external view returns (uint256);

    function getPriceDecimals(address asset) external view returns (uint8);
}
```

Two implementations are included.

### `MockPriceOracle`

Used for:

* unit tests
* local development
* deterministic testing

It allows controlled asset prices.

### `ChainlinkPriceOracle`

Used for the Sepolia deployment.

The adapter maps protocol assets to Chainlink price feeds.

```text
Mock WETH
    │
    ▼
ETH / USD Chainlink Feed

Mock USDC
    │
    ▼
USDC / USD Chainlink Feed
```

The oracle performs defensive validation before accepting a price.

Checks include:

```text
Feed configured
      │
      ▼
Price > 0
      │
      ▼
Round completed
      │
      ▼
answeredInRound >= roundId
      │
      ▼
Timestamp not in future
      │
      ▼
Price within configured staleness window
      │
      ▼
Price accepted
```

Feed decimals above the protocol-supported normalization range are rejected during configuration.

---

# Oracle Staleness Protection

Different feeds may update at different frequencies.

The Sepolia deployment therefore configures separate maximum staleness windows:

```text
ETH/USD  → 3 hours
USDC/USD → 25 hours
```

A price older than its configured threshold is rejected.

This prevents the risk engine from silently valuing collateral or debt using an excessively old oracle observation.

---

# Multi-Asset Positions

The protocol supports positions involving multiple assets.

For example:

```text
User
│
├── supplies WETH
├── supplies USDC
│
└── borrows USDC
```

The risk engine aggregates supported assets when calculating account values.

```text
Collateral Value
=
Σ collateral value × liquidation threshold

Debt Value
=
Σ debt value
```

Borrowing capacity similarly aggregates collateral using each asset's collateral factor.

---

# Security Design

The protocol includes several defensive controls.

## Reentrancy Protection

State-changing lending operations are protected using OpenZeppelin `ReentrancyGuard`.

This includes:

```text
supply
withdraw
borrow
repay
liquidate
```

---

## Safe ERC-20 Transfers

Token transfers use OpenZeppelin `SafeERC20`.

This avoids relying on every ERC-20 token strictly following the expected boolean-return behavior.

---

## Checks-Effects-Interactions

For token outflows such as borrowing and withdrawal, accounting is updated before the external token transfer.

Combined with reentrancy protection, this reduces external-call attack surface.

---

## Health Checks

Borrowing requires sufficient collateral.

Withdrawal cannot make a debt-bearing position unhealthy.

Liquidation is restricted to accounts below the required health factor.

---

## Reserve Access Control

Only the configured `LendingPool` can mutate scaled reserve accounting.

Administrative reserve configuration is owner-controlled.

Core contract wiring is explicitly configured during deployment.

---

## Oracle Validation

The production-style oracle adapter rejects:

* unconfigured feeds
* zero/negative prices
* incomplete rounds
* stale rounds
* stale timestamps
* future timestamps
* unsupported feed decimal configurations

---

## Decimal Safety

Reserve token decimals are constrained to the supported normalization range.

Risk calculations additionally validate token and oracle decimals before performing normalization.

This prevents unsafe exponentiation caused by malformed decimal configurations.

---

# Testing

The protocol uses Foundry for its test infrastructure.

Current result:

```text
12 test suites
227 tests passed
0 tests failed
0 tests skipped
```

The suite includes several testing layers.

---

## Unit Tests

Unit tests cover individual components including:

```text
LendingPool
ReserveManager
RiskManager
InterestRateModel
MockPriceOracle
ChainlinkPriceOracle
MockERC20
```

---

## Failure-Path Tests

Expected revert conditions are explicitly tested.

Examples include:

* zero-value operations
* insufficient collateral
* insufficient liquidity
* unauthorized operations
* invalid reserve configuration
* unhealthy withdrawals
* invalid oracle values
* stale oracle data

---

## Integration Tests

Integration tests validate interactions across multiple contracts rather than testing components in isolation.

Examples include:

```text
Oracle
  ↓
RiskManager
  ↓
LendingPool
  ↓
ReserveManager
```

---

## Fuzz Testing

Foundry fuzz tests exercise protocol functions across generated input ranges.

These help identify edge cases that fixed test values may miss.

---

## Invariant Testing

Stateful invariant testing exercises sequences of protocol actions through handler contracts.

Examples of protocol properties checked include accounting consistency and solvency-related behavior across generated operation sequences.

The invariant suite executes large numbers of randomized state transitions rather than validating only predefined user flows.

---

## Security Tests

Dedicated security tests exercise adversarial and edge-case protocol behavior, including invalid operations and accounting boundaries.

---

# Chainlink Oracle Tests

`ChainlinkPriceOracle` has dedicated unit tests covering:

```text
valid price
price decimals
feed configuration
owner authorization
zero asset
zero feed
zero staleness
unconfigured feed
zero price
negative price
incomplete round
stale round
stale price
future timestamp
unsupported feed decimals
```

Result:

```text
15 passed
0 failed
```

---

# Running the Tests

Install Foundry if necessary, then clone the repository.

```bash
git clone https://github.com/vishalmathuri/Production-grade-EVM-lending-protocot.git
cd evm-lending-protocol
```

Install dependencies:

```bash
forge install
```

Build:

```bash
forge build
```

Run the complete test suite:

```bash
forge test
```

Run with additional verbosity:

```bash
forge test -vv
```

Run a specific suite:

```bash
forge test --match-contract RiskManagerTest
```

Run the Chainlink oracle tests:

```bash
forge test --match-contract ChainlinkPriceOracleTest
```

Run invariant tests:

```bash
forge test --match-contract LendingPoolInvariantTest
```

Generate a gas report:

```bash
forge test --gas-report
```

---

# Project Structure

```text
evm-lending-protocol/
│
├── src/
│   ├── LendingPool.sol
│   ├── ReserveManager.sol
│   ├── RiskManager.sol
│   ├── InterestRateModel.sol
│   │
│   ├── interfaces/
│   │   ├── ILendingPool.sol
│   │   ├── IPositionProvider.sol
│   │   ├── IPriceOracle.sol
│   │   ├── IRiskManager.sol
│   │   └── IInterestRateModel.sol
│   │
│   ├── libraries/
│   │   ├── ReserveTypes.sol
│   │   ├── UserTypes.sol
│   │   └── MathUtils.sol
│   │
│   ├── oracles/
│   │   ├── MockPriceOracle.sol
│   │   └── ChainlinkPriceOracle.sol
│   │
│   └── tokens/
│       └── MockERC20.sol
│
├── test/
│   ├── unit/
│   ├── fuzz/
│   ├── invariant/
│   ├── integration/
│   ├── security/
│   └── mocks/
│
├── script/
│   ├── DeployMocks.s.sol
│   ├── Deploy.s.sol
│   ├── ConfigureProtocol.s.sol
│   └── DeploySepolia.s.sol
│
├── foundry.toml
└── README.md
```

---

# Sepolia Deployment

The protocol has been deployed to Ethereum Sepolia and an end-to-end protocol flow has been executed successfully.

## Contracts

| Contract             | Sepolia Address                              |
| -------------------- | -------------------------------------------- |
| Mock WETH            | `0x0B7916156061e0FA02234C6c55582699331Ce8e5` |
| Mock USDC            | `0x1fdfaB617cac7262F655F98635dA2dAb41442bcb` |
| ChainlinkPriceOracle | `0xD6d96d1Cf7EFd922D9Eaa6A65E4cd84A79103533` |
| InterestRateModel    | `0x31813B7d53Ca32AECD347c87dC21aE7CA9622EfE` |
| ReserveManager       | `0xe2D9Ba8FF9379BeD8207B397C5Eb96F69827093A` |
| LendingPool          | `0x950d53210b786f8f5060B87b2ce8EA692E026cCC` |
| RiskManager          | `0xa7AdBCC80d0A3862c22cDf14a62dD04fd828de28` |

All deployed protocol contracts have been source-verified on the Sepolia block explorer.

---

# Sepolia Chainlink Feeds

The deployment maps the mock assets to external Chainlink feeds:

```text
Mock WETH
→ ETH/USD
→ 0x694AA1769357215DE4FAC081bf1f309aDC325306

Mock USDC
→ USDC/USD
→ 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E
```

This allows the protocol to use controllable ERC-20 test assets while exercising a real oracle integration on Sepolia.

---

# Sepolia End-to-End Validation

After deployment, the following on-chain flow was executed successfully:

```text
Mint mock WETH
        │
        ▼
Mint mock USDC
        │
        ▼
Approve LendingPool
        │
        ▼
Supply WETH collateral
        │
        ▼
Supply USDC liquidity
        │
        ▼
Borrow USDC
        │
        ▼
Read live debt
        │
        ▼
Repay USDC
        │
        ▼
Withdraw WETH
        │
        ▼
SUCCESS
```

Core wiring was also checked on-chain:

```text
ReserveManager
    │
    └── LendingPool ✓

LendingPool
    │
    └── RiskManager ✓

RiskManager
    ├── ReserveManager ✓
    └── ChainlinkPriceOracle ✓

ChainlinkPriceOracle
    ├── ETH/USD feed ✓
    └── USDC/USD feed ✓
```

---

# Local Development

Start Anvil:

```bash
anvil
```

Create a `.env` file based on `.env.example`.

Example:

```env
PRIVATE_KEY=YOUR_LOCAL_PRIVATE_KEY
RPC_URL=http://127.0.0.1:8545
```

Never commit real private keys.

Deploy mocks as required:

```bash
forge script script/DeployMocks.s.sol:DeployMocks \
  --rpc-url "$RPC_URL" \
  --broadcast
```

---

# Sepolia Deployment

Environment variables used by the Sepolia deployment include:

```env
PRIVATE_KEY=
SEPOLIA_RPC_URL=

SEPOLIA_ETH_USD_FEED=
SEPOLIA_USDC_USD_FEED=
```

Load them in Git Bash:

```bash
set -a
source .env
set +a
```

Simulate deployment first:

```bash
forge script script/DeploySepolia.s.sol:DeploySepolia \
  --rpc-url "$SEPOLIA_RPC_URL"
```

Then broadcast:

```bash
forge script script/DeploySepolia.s.sol:DeploySepolia \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast
```

Always simulate and inspect configuration before broadcasting to a public network.

---

# Protocol Parameters

The current Sepolia configuration uses:

| Parameter              |    Value |
| ---------------------- | -------: |
| WETH Decimals          |       18 |
| USDC Decimals          |        6 |
| Collateral Factor      |      80% |
| Liquidation Threshold  |      85% |
| Liquidation Bonus      |       5% |
| ETH/USD Max Staleness  |  3 hours |
| USDC/USD Max Staleness | 25 hours |

These parameters are demonstration/testnet configuration and should not be interpreted as production risk recommendations.

---

# Example Position

Suppose a user supplies:

```text
10 WETH
```

If ETH is valued at:

```text
$3,000
```

the nominal collateral value is:

```text
10 × $3,000
=
$30,000
```

At an 80% collateral factor:

```text
Maximum borrowing capacity
=
$30,000 × 0.80
=
$24,000
```

At an 85% liquidation threshold, the health calculation uses:

```text
$30,000 × 0.85
=
$25,500
```

This illustrates why borrowing capacity and liquidation threshold are intentionally separate risk parameters.

---

# Design Decisions

## Separate Risk Layer

Risk calculations are isolated in `RiskManager` rather than embedded throughout `LendingPool`.

Benefits include:

* easier auditing
* clearer responsibilities
* simpler testing
* replaceable risk logic

---

## Separate Reserve Accounting

Reserve accounting is isolated in `ReserveManager`.

This prevents the user-facing lending contract from also becoming responsible for every interest and reserve calculation.

---

## Oracle Abstraction

`RiskManager` depends on `IPriceOracle`, not directly on Chainlink.

```text
RiskManager
     │
     ▼
IPriceOracle
   /     \
  /       \
Mock      Chainlink
Oracle    Oracle
```

This makes testing deterministic while keeping the deployed architecture compatible with external feeds.

---

## Scaled Principal

User balances are stored in scaled units rather than continuously compounded absolute balances.

This provides efficient global interest accrual through reserve indexes.

---

## Rounding-Aware Accounting

Actual-to-scaled conversions use direction-aware rounding.

Partial balance reductions and exact full-position cleanup are handled separately so that scaled accounting does not leave unnecessary residual debt or collateral dust.

---

# Known Scope and Limitations

This repository is an engineering/portfolio implementation and is **not presented as audited mainnet-ready financial infrastructure**.

Current scope intentionally does not include every feature found in mature lending markets.

Examples outside the current scope include:

* governance
* timelocks
* upgradeability
* protocol reserve factor
* treasury accounting
* flash loans
* isolation mode
* eMode-style risk categories
* per-asset borrow caps
* supply caps
* liquidation close factors
* permissionless asset listing
* emergency guardian architecture
* production governance processes

The current implementation also aggregates positions across the protocol's supported asset list, which is suitable for the project's limited asset scope but would require a more scalable design for a large permissionless asset universe.

---

# Important Security Notice

This project has extensive automated testing, but:

> **It has not undergone a professional third-party smart-contract audit.**

Do not deploy this repository to mainnet with real user funds without additional:

* independent security review
* formal threat modeling
* oracle risk analysis
* economic parameter analysis
* fork testing
* monitoring
* incident-response planning
* governance/access-control hardening

Passing tests does not guarantee the absence of vulnerabilities.

---

# Technology Stack

```text
Solidity
Foundry
Forge
Cast
Anvil
OpenZeppelin Contracts
Chainlink Data Feeds
Ethereum Sepolia
Git / GitHub
```

---

# Development Workflow

The project was developed with an iterative protocol-engineering workflow:

```text
Architecture
     ↓
Core implementation
     ↓
Unit tests
     ↓
Failure tests
     ↓
Integration tests
     ↓
Fuzz tests
     ↓
Invariant tests
     ↓
Security tests
     ↓
Oracle hardening
     ↓
Sepolia simulation
     ↓
Sepolia deployment
     ↓
Contract verification
     ↓
On-chain smoke test
```

---

# Key Engineering Areas Demonstrated

This project demonstrates practical experience with:

* Solidity protocol architecture
* DeFi lending mechanics
* collateralized borrowing
* scaled-balance accounting
* fixed-point arithmetic
* interest indexes
* utilization-based rates
* multi-asset risk calculations
* health factors
* liquidations
* oracle normalization
* Chainlink Data Feeds
* stale-price protection
* ERC-20 integration
* access control
* reentrancy protection
* fuzz testing
* stateful invariant testing
* integration testing
* adversarial/security testing
* Foundry deployment scripting
* testnet deployment
* block-explorer contract verification
* CLI-based on-chain interaction

---

# Future Improvements

Potential extensions include:

* protocol reserve factor
* treasury revenue
* supply and borrow caps
* liquidation close factor
* emergency pause/guardian system
* governance/timelock-controlled configuration
* additional collateral markets
* more sophisticated interest-rate curves
* per-user active asset tracking
* fork tests against production oracle infrastructure
* monitoring and alerting
* frontend lending dashboard
* indexer/subgraph
* liquidation bot
* formal verification of critical accounting invariants

---

# Disclaimer

This repository is intended for educational, engineering, testing, and portfolio purposes.

It is not financial advice and should not be considered audited or production-ready for handling real funds.

Use at your own risk.

---

## Author

**Vishal Mathur**

Blockchain / Smart Contract Developer

* Solidity
* EVM
* Foundry
* DeFi
* Chainlink
* Rust / Solana

GitHub: `https://github.com/vishalmathuri`

LinkedIn: `https://www.linkedin.com/in/vishal-mathuri`
