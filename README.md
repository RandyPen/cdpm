# CDPM - Cetus DLMM Position Manager

## Overview

CDPM (Cetus DLMM Position Manager) is a Sui Move smart contract that enables proxy liquidity management on Cetus DLMM (Discrete Liquidity Market Maker). The contract allows users to manage their liquidity positions directly or delegate management to the protocol or custom AI agents, with the protocol collecting fees on managed operations.

## Key Features

### 1. User Self-Management
- **Deposit & Create Positions**: Deposit liquidity and create new positions
- **Add/Remove Liquidity**: Manage existing positions
- **Collect Fees/Rewards**: Collect accumulated fees and rewards
- **Balance Management**: Deposit to and withdraw from position balance
- **Agent Management**: Authorize/deauthorize agent addresses

### 2. Protocol-Managed Operations
- **Automated Liquidity Management**: Protocol can add/remove liquidity on behalf of users
- **Fee Collection with Protocol Cut**: Protocol collects fees, taking a percentage (default: 20%)
- **Balance Transfers**: Move fees from fee bag to balance for withdrawal
- **Access Control**: Admin-managed allow list for protocol addresses

### 3. AI Agent Delegation
- **Custom Agent Authorization**: Users can authorize custom AI agents
- **Agent Operations**: Agents can perform liquidity management operations
- **Permission Control**: Agents have limited permissions (cannot withdraw funds)

### 4. Emergency Functions
- **Emergency Position Closure**: Close positions without normal fee collection
- **Emergency Fee Collection**: Collect fees without protocol cut
- **Use Case**: Handle Cetus DLMM contract upgrades when the proxy contract cannot be upgraded

## Architecture

### Core Data Structures

#### PositionManager
Central structure representing a user's liquidity position:
```move
public struct PositionManager has key {
    id: UID,
    owner: address,           // Position owner
    agents: VecSet<address>,  // Authorized agents
    position: Option<Position>, // Cetus DLMM position
    balance: Bag,             // Token balances
    fee: Bag,                 // Accumulated fees
}
```

#### FeeHouse
Protocol fee management:
```move
public struct FeeHouse has key {
    id: UID,
    fee_rate: u64,  // Protocol fee rate (0-10000, where 10000 = 100%)
    fee: Bag,       // Accumulated protocol fees
}
```

#### AccessList
Protocol address allow list:
```move
public struct AccessList has key {
    id: UID,
    allow: VecSet<address>,  // Allowed protocol addresses
}
```

#### AdminCap
Administrator capability token:
```move
public struct AdminCap has key {
    id: UID,  // Single admin capability
}
```

### Permission System

Four-tier permission model:
1. **Owner**: Creator of the PositionManager
2. **Agent**: Addresses authorized by owner (limited operations)
3. **Protocol**: Addresses in AccessList (managed by admin)
4. **Admin**: Holder of AdminCap (global management)

## Quick Start

### Prerequisites
- Sui CLI installed
- Move development environment
- Access to Sui network (testnet/mainnet)

### Deployment

1. **Build the contract**:
   ```bash
   sui move build
   ```

2. **Publish the package**:
   ```bash
   sui client publish --gas-budget 100000000
   ```

3. **Initialize the contract**:
   - The `init` function automatically creates:
     - `AdminCap` transferred to deployer
     - `FeeHouse` with default 20% fee rate
     - `AccessList` (empty)
     - `GlobalRecord` for position tracking

### Basic Usage

#### 1. User Creates Position
```move
// Deposit liquidity and create position
user_deposit<CoinTypeA, CoinTypeB>(
    record: &mut Record,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    coin_a: &mut Coin<CoinTypeA>,
    coin_b: &mut Coin<CoinTypeB>,
    bins: vector<u32>,
    amounts_a: vector<u64>,
    amounts_b: vector<u64>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
);
```

#### 2. Add Authorized Agent
```move
// Authorize an AI agent
user_insert_agent(
    pm: &mut PositionManager,
    agent: address,
    clk: &Clock,
    ctx: &TxContext,
);
```

#### 3. Collect Fees
```move
// Collect accumulated fees
let (coin_a, coin_b) = user_collect_fee<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
);
```

## Fee Mechanism

### Protocol Fee Calculation
The protocol charges a fee on managed operations (default: 20%):
```
fee_amount = amount * fee_rate / FEE_DENOMINATOR
```
Where `FEE_DENOMINATOR = 10000` (100%).

### Fee Distribution
1. **User Operations**: No protocol fee
2. **Protocol Operations**: Protocol takes fee (default 20%)
3. **Agent Operations**: No protocol fee (fees go to user's fee bag)

## Security Features

### 1. Permission Separation
- Clear boundaries between owner, agent, protocol, and admin roles
- Agent-limited operations (cannot withdraw funds)
- Protocol access controlled by admin-managed allow list

### 2. Emergency Recovery
- Emergency functions for dependency contract upgrades
- Protocol-controlled emergency access
- Fund safety during Cetus DLMM upgrades

### 3. Input Validation
- Fee rate bounds checking (0-100%)
- Permission validation on all operations
- Safe mathematical operations (u128 for fee calculations)

### 4. Event System
Comprehensive event emission for all operations:
- Position creation/closing
- Liquidity addition/removal
- Fee/reward collection
- Agent management
- Admin operations
- Emergency actions

## Event System

All key operations emit events for off-chain monitoring. Recent improvements include:

### Enhanced Event Data (Completed ✅)
- **`FeeCollected`**: Added `coin_type_a` and `coin_type_b` fields
- **`ProtocolFeeCollected`**: Added `coin_type_a` and `coin_type_b` fields
- **`RewardCollected`**: Renamed `reward_type` to `coin_type` for consistency
- **`ProtocolRewardCollected`**: Renamed `reward_type` to `coin_type` for consistency

See [API Documentation](API.md) for complete event details.

## Development

### Project Structure
```
cdpm/
├── sources/
│   └── cdpm.move          # Main contract (1144 lines)
├── tests/
│   └── cdpm_tests.move    # Test suite (to be implemented)
├── Move.toml              # Package configuration
└── Move.lock             # Dependency lock
```

### Dependencies
- **CetusDlmm**: Cetus DLMM interface (mainnet-v0.5.0)
- **IntegerMate**: Integer utilities (mainnet-v1.3.0)
- **MoveSTL**: Move standard template library (mainnet-v1.3.0)

### Building and Testing
```bash
# Build contract
sui move build

# Run tests (when implemented)
sui move test
```

## Documentation

Comprehensive documentation is available:

1. **[DESIGN.md](DESIGN.md)** - Technical design and architecture
2. **[API.md](API.md)** - Complete API reference
3. **[SECURITY.md](SECURITY.md)** - Security analysis and recommendations
4. **[IMPROVEMENTS.md](IMPROVEMENTS.md)** - Code improvement suggestions

## Security Audit

A comprehensive security audit has been conducted covering:

1. **Basic Security Checks**: Permission validation, input checking
2. **In-Depth Audit**: Fee calculation correctness, state consistency
3. **Attack Vector Analysis**: Permission escalation, economic attacks

**Overall Security Rating: GOOD** 🟢

See [SECURITY.md](SECURITY.md) for detailed audit findings and recommendations.

## License

This project is licensed under the terms of the original repository.

## Contributing

1. Review security considerations in [SECURITY.md](SECURITY.md)
2. Follow code improvement guidelines in [IMPROVEMENTS.md](IMPROVEMENTS.md)
3. Ensure comprehensive testing for all changes
4. Maintain backward compatibility where possible

## Support

For issues, questions, or security concerns:
1. Review documentation
2. Check existing issues
3. Contact maintainers through appropriate channels

---

*Last Updated: 2026-02-28*
*Contract Version: As deployed*
*Documentation Version: 1.0*