# BitVault Protocol

A decentralized lending protocol enabling Bitcoin holders to unlock liquidity from their sBTC collateral while maintaining Bitcoin exposure.

## Overview

BitVault revolutionizes Bitcoin DeFi by creating a secure lending marketplace where users can deposit sBTC as collateral to borrow STX tokens, or provide STX liquidity to earn competitive yields. Built on Stacks Layer-2, this protocol combines Bitcoin's security with DeFi innovation, featuring automated interest accrual, liquidation protection, and yield optimization for a seamless Bitcoin-native financial experience.

## Key Features

- **sBTC Collateral Support**: Deposit sBTC (Stacks Bitcoin) as collateral to borrow STX
- **STX Lending Pool**: Provide STX liquidity to earn competitive yields
- **Automated Interest Accrual**: Real-time interest calculation and compounding
- **Liquidation Protection**: 80% liquidation threshold with 10% liquidator rewards
- **Health Factor Monitoring**: Track position safety in real-time
- **Protocol Pause Mechanism**: Emergency controls for system security

## Architecture

### System Overview

BitVault operates as a two-sided marketplace connecting:

1. **Borrowers**: Bitcoin holders wanting liquidity while maintaining BTC exposure
2. **Lenders**: STX holders seeking yield on their assets

### Contract Architecture

The BitVault protocol consists of a single main contract (`bitvault.clar`) that manages:

#### Core Components

1. **Price Oracle System**
   - Static price feed for sBTC/STX conversion
   - Admin-controlled price updates
   - Fallback pricing mechanism

2. **Lending Pool Management**
   - STX deposit/withdrawal functionality
   - Yield calculation and distribution
   - Cumulative yield indexing

3. **Collateral Management**
   - sBTC collateral tracking
   - Position health monitoring
   - Liquidation threshold enforcement

4. **Interest Rate System**
   - 10% annual percentage rate (APR)
   - Time-based interest accrual
   - Automated compounding

### Data Flow

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   STX Lenders   │    │  BitVault Pool  │    │ sBTC Borrowers  │
│                 │    │                 │    │                 │
│ Deposit STX ────┼───▶│ STX Liquidity   │◄───┼──── Borrow STX  │
│                 │    │                 │    │                 │
│ Earn Yield ◄────┼────│ Interest Pool   │    │ Pay Interest ───┼──┐
│                 │    │                 │    │                 │  │
│ Withdraw ───────┼───▶│ Yield Accrual   │    │ Deposit sBTC ───┼──┘
└─────────────────┘    └─────────────────┘    └─────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │ Liquidation     │
                    │ Engine          │
                    └─────────────────┘
```

## Protocol Parameters

| Parameter | Value | Description |
|-----------|--------|------------|
| Loan-to-Value Ratio | 70% | Maximum borrowing capacity against collateral |
| Annual Interest Rate | 10% | Fixed APR for borrowing |
| Liquidation Threshold | 80% | Collateral ratio triggering liquidation |
| Liquidator Reward | 10% | Incentive for liquidators |

## Smart Contract Functions

### Lending Functions

- `deposit-stx(amount)`: Deposit STX to earn yield
- `withdraw-stx(amount)`: Withdraw STX deposits plus earned yield
- `calculate-pending-yield(account)`: Calculate accrued yield for an account

### Borrowing Functions

- `borrow-stx(collateral-amount, borrow-amount)`: Borrow STX against sBTC collateral
- `repay-loan(repay-amount)`: Repay borrowed STX and retrieve collateral
- `calculate-user-debt(account)`: Calculate total debt including interest

### Liquidation Functions

- `liquidate-position(target-user)`: Liquidate undercollateralized positions

### Query Functions

- `get-user-collateral(account)`: Get user's sBTC collateral balance
- `get-user-deposits(account)`: Get user's STX deposit balance
- `get-user-borrows(account)`: Get user's STX borrow balance
- `get-user-health-factor(account)`: Calculate position health factor
- `get-protocol-stats()`: Retrieve global protocol statistics

### Administrative Functions

- `update-sbtc-price(new-price)`: Update sBTC price (owner only)
- `pause-protocol()`: Emergency pause (owner only)
- `unpause-protocol()`: Resume operations (owner only)

## Development Setup

### Prerequisites

- [Clarinet](https://github.com/hirosystems/clarinet) v2.0+
- Node.js v18+
- Git

### Installation

```bash
# Clone the repository
git clone https://github.com/eddy-kaz/bitvault.git
cd bitvault

# Install dependencies
npm install

# Check contract syntax
clarinet check

# Run tests
npm test
```

### Testing

The project includes comprehensive test suites using Vitest:

```bash
# Run all tests
npm test

# Run tests with coverage
npm run test:report

# Watch mode for development
npm run test:watch
```

## Security Considerations

### Risk Management

1. **Price Oracle Risk**: Currently uses a static price feed; production deployment should integrate with decentralized oracles
2. **Liquidation Risk**: 80% threshold provides reasonable buffer against price volatility
3. **Smart Contract Risk**: Comprehensive testing and potential audits recommended before mainnet deployment

### Access Controls

- Contract owner controls for price updates and emergency pause
- User-specific position management
- Liquidation available to any user for undercollateralized positions

## Error Codes

| Code | Error | Description |
|------|-------|------------|
| 100 | ERR_INVALID_WITHDRAW_AMOUNT | Withdrawal amount exceeds available balance |
| 101 | ERR_EXCEEDED_MAX_BORROW | Borrow amount exceeds collateral capacity |
| 102 | ERR_CANNOT_BE_LIQUIDATED | Position is sufficiently collateralized |
| 103 | ERR_ACTIVE_DEPOSIT_EXISTS | User already has active deposits |
| 104 | ERR_INSUFFICIENT_BALANCE | Insufficient account balance |
| 105 | ERR_ZERO_AMOUNT | Amount must be greater than zero |
| 106 | ERR_PRICE_FEED_ERROR | Price oracle error |
| 107 | ERR_CONTRACT_CALL_FAILED | Contract call failure |
| 108 | ERR_UNAUTHORIZED | Unauthorized access |

## Roadmap

### Phase 1 (Current)

- ✅ Core lending and borrowing functionality
- ✅ Interest accrual system
- ✅ Basic liquidation mechanism
- ✅ Static price oracle

### Phase 2 (Future)

- [ ] Decentralized price oracle integration
- [ ] Variable interest rates based on utilization
- [ ] Governance token and DAO
- [ ] Multi-collateral support

### Phase 3 (Future)

- [ ] Cross-chain functionality
- [ ] Advanced liquidation strategies
- [ ] Yield farming incentives
- [ ] Insurance fund integration

## Contributing

We welcome contributions! Please read our contributing guidelines and submit pull requests for any improvements.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
