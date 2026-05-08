# CDPM Technical Design Document

## Architecture Overview

CDPM (Cetus DLMM Position Manager) is a proxy contract that sits between users and the Cetus DLMM protocol, providing additional functionality for liquidity management delegation, fee collection.

### System Architecture
```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│    User     │────│    CDPM     │────│ Cetus DLMM  │
│  (Owner)    │    │   Proxy     │    │   Protocol  │
└─────────────┘    └─────────────┘    └─────────────┘
       │                    │                    │
       │                    │                    │
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   AI Agent  │────│   Protocol  │    │  Dependencies│
│  (Delegated)│    │ (Managed)   │    │ (IntegerMate,│
└─────────────┘    └─────────────┘    └─────────────┘
                         │               MoveSTL, etc.)
                         │
                   ┌─────────────┐
                   │   Admin     │
                   │ (Global Mgmt)│
                   └─────────────┘
```

### Core Design Principles
1. **Proxy Pattern**: CDPM acts as a proxy, managing user positions in Cetus DLMM
2. **Permission Separation**: Clear boundaries between different actor types
3. **Fee Extraction**: Protocol earns fees on managed operations
4. **Event-Driven**: Comprehensive event emission for off-chain monitoring

## Data Structures

### 1. PositionManager
The central structure representing a user's liquidity management context.

```move
public struct PositionManager has key {
    id: UID,                    // Unique identifier
    owner: address,             // Position owner (creator)
    agents: VecSet<address>,    // Authorized agent addresses
    position: Option<Position>, // Underlying Cetus DLMM position
    balance: Bag,               // Token balances (String -> Balance<T>)
    fee: Bag,                   // Accumulated fees (String -> Balance<T>)
}
```

**Key Characteristics:**
- **Owner**: Immutable after creation, controls all owner functions
- **Agents**: Dynamic set, can be added/removed by owner
- **Position**: Optional, exists when user has active liquidity
- **Balance**: Generic token balances for deposit/withdrawal
- **Fee**: Accumulated fees from agent/protocol operations

### 2. FeeHouse
Global protocol fee management structure.

```move
public struct FeeHouse has key {
    id: UID,
    fee_rate: u64,  // Protocol fee rate (0-10000, 10000 = 100%)
    fee: Bag,       // Accumulated protocol fees (String -> Balance<T>)
}
```

**Fee Rate Calculation:**
```
effective_fee_rate = fee_rate / FEE_DENOMINATOR
fee_amount = amount * effective_fee_rate
```
Where `FEE_DENOMINATOR = 10000` (constant).

### 3. AccessList
Protocol address allow list for managed operations.

```move
public struct AccessList has key {
    id: UID,
    allow: VecSet<address>,  // Addresses allowed to perform protocol operations
}
```

**Management:**
- Admin-controlled via `admin_insert_access_list` and `admin_remove_access_list`
- Used to gate protocol functions

### 4. AdminCap
Administrator capability token (singleton).

```move
public struct AdminCap has key {
    id: UID,  // Single instance, transferable
}
```

**Privileges:**
- Set protocol fee rate
- Collect accumulated protocol fees
- Manage AccessList
- Transfer admin capability

### 5. Record Management
Two-level record keeping for position tracking.

#### GlobalRecord
```move
public struct GlobalRecord has key {
    id: UID,
    record: Table<address, ID>,  // User address -> Record ID
}
```

#### Record (per-user)
```move
public struct Record has key {
    id: UID,
    record: Table<ID, bool>,  // PositionManager ID -> exists flag
}
```

**Purpose:** Track all PositionManagers for each user, enabling efficient lookup and management.

## Permission Model

### Four-Tier Permission System

#### Tier 1: Owner
**Identifier:** `pm.owner == ctx.sender()`
**Capabilities:**
- Full control over PositionManager
- Add/remove liquidity
- Collect fees/rewards
- Manage agents
- Close position
- Deposit/withdraw from balance
- Withdraw from fee bag

**Functions:** All `user_*` functions

#### Tier 2: Agent
**Identifier:** `vec_set::contains<address>(&pm.agents, &ctx.sender())`
**Capabilities:**
- Add/remove liquidity (using balance)
- Collect fees/rewards (to fee bag)
- Cannot withdraw funds
- Cannot modify PositionManager configuration

**Functions:** All `agent_*` functions

#### Tier 3: Protocol
**Identifier:** `vec_set::contains<address>(&access.allow, &ctx.sender())`
**Additional Check:** `vec_set::is_empty<address>(&pm.agents)` (no active agents)
**Capabilities:**
- Add/remove liquidity (using balance, with protocol fee)
- Collect fees/rewards (with protocol fee deduction)
- Transfer fees from fee bag to balance

**Functions:** All `protocol_*` functions

#### Tier 4: Admin
**Identifier:** Holds `AdminCap`
**Capabilities:**
- Set protocol fee rate (0-100%)
- Collect accumulated protocol fees
- Manage AccessList (add/remove protocol addresses)
- Transfer admin capability

**Functions:** All `admin_*` functions

### Permission Matrix
| Operation | Owner | Agent | Protocol | Admin |
|-----------|-------|-------|----------|-------|
| Create Position | ✓ | ✗ | ✗ | ✗ |
| Add/Remove Liquidity | ✓ | ✓ | ✓* | ✗ |
| Collect Fees/Rewards | ✓ | ✓† | ✓* | ✗ |
| Withdraw Funds | ✓ | ✗ | ✗ | ✗ |
| Manage Agents | ✓ | ✗ | ✗ | ✗ |
| Set Fee Rate | ✗ | ✗ | ✗ | ✓ |
| Collect Protocol Fees | ✗ | ✗ | ✗ | ✓ |

*With protocol fee deduction
†To fee bag only
‡Without fee collection

## Fee Mechanism

### Fee Calculation
```move
fun take_fee<T>(
    balance_in: &mut Balance<T>,
    fee_house: &mut FeeHouse,
) {
    let amount_in = balance::value<T>(balance_in);
    let fee_amount = (((amount_in as u128) * (fee_house.fee_rate as u128) / FEE_DENOMINATOR) as u64);
    let fee = balance::split<T>(balance_in, fee_amount);
    // Add fee to protocol fee bag
}
```

**Safety Features:**
- Uses `u128` for intermediate calculations to prevent overflow
- Division by constant `FEE_DENOMINATOR` (no zero division risk)
- Final cast to `u64` after division

### Fee Distribution Scenarios

#### Scenario 1: User Self-Management
```
User collects 100 USDC fees
→ User receives: 100 USDC
→ Protocol receives: 0 USDC
```

#### Scenario 2: Protocol Management
```
Protocol collects 100 USDC fees (20% fee rate)
→ User receives: 80 USDC (to fee bag)
→ Protocol receives: 20 USDC (to protocol fee bag)
```

#### Scenario 3: Agent Management
```
Agent collects 100 USDC fees
→ User receives: 100 USDC (to fee bag)
→ Protocol receives: 0 USDC
```

### Default Configuration
- **Default Fee Rate:** 2000/10000 = 20%
- **Maximum Fee Rate:** 10000/10000 = 100%
- **Minimum Fee Rate:** 0/10000 = 0%

## Event System

### Event Categories

#### 1. Position Management Events
- `PositionManagerCreated`: New PositionManager created
- `PositionManagerClosed`: PositionManager closed

#### 2. Liquidity Events
- `LiquidityAdded`: Liquidity added to position
- `LiquidityRemoved`: Liquidity removed from position

#### 3. Fee/Reward Events
- `FeeCollected`: Fees collected by user
- `RewardCollected`: Rewards collected by user
- `ProtocolFeeCollected`: Fees collected by protocol (with fee)
- `ProtocolRewardCollected`: Rewards collected by protocol (with fee)
- `UserFeeWithdrawn`: User withdraws fees from fee bag
- `AdminFeeCollected`: Admin collects protocol fees

#### 4. Agent Events
- `AgentAdded`: Agent authorized by owner
- `AgentRemoved`: Agent authorization revoked

#### 5. Balance Events
- `BalanceDeposited`: User deposits to balance
- `BalanceWithdrawn`: User withdraws from balance
- `FeeTransferredToBalance`: Fees transferred from fee bag to balance

#### 6. Admin Events
- `FeeRateUpdated`: Protocol fee rate changed
- `AccessGranted`: Address added to AccessList
- `AccessRevoked`: Address removed from AccessList
- `AdminTransferred`: AdminCap transferred

## State Transitions

### PositionManager Lifecycle
```
1. Creation
   user_deposit() → PositionManagerCreated
   State: position = some, balance = empty, fee = empty, agents = empty

2. Normal Operations
   - Add/remove liquidity
   - Collect fees/rewards
   - Manage agents
   - Deposit/withdraw funds

3. Closure
   user_close_pm() → PositionManagerClosed
   State: resources destroyed, position closed
```

### Fee Collection Flow
```
User/Agent/Protocol collects fees:
1. Call collect function
2. Cetus DLMM returns fee balances
3. If protocol: take_fee() extracts protocol cut
4. Remaining fees added to user's fee bag
5. Event emitted with amounts and coin types
```

## Dependencies

### External Dependencies
1. **CetusDlmm**: Mainnet-v0.5.0
   - `pool::` module for liquidity operations
   - `position::Position` structure
   - `versioned::Versioned` for upgrade compatibility

2. **IntegerMate**: Mainnet-v1.3.0
   - Integer utilities

3. **MoveSTL**: Mainnet-v1.3.0
   - Standard template library

### Sui Framework Dependencies
- `sui::vec_set`: Address set management
- `sui::bag`: Generic container for balances/fees
- `sui::balance`: Token balance management
- `sui::coin`: Coin operations
- `sui::table`: Key-value storage
- `sui::clock`: Timestamp access
- `sui::event`: Event emission

## Error Handling

### Error Codes
```move
const ENotOwner: u64 = 1001;      // Caller is not owner
const ENotAllow: u64 = 1002;      // Caller not authorized (agent/protocol)
const EInvalidFeeRate: u64 = 2001; // Fee rate exceeds FEE_DENOMINATOR
```

### Error Code Recommendations (Future Improvement)
Suggested categorization:
- **1000-1999**: Permission errors
- **2000-2999**: Parameter validation errors
- **3000-3999**: State-related errors
- **4000-4999**: External dependency errors

## Security Considerations

### Contract Invariants
1. **Fee Rate Bound**: `0 <= fee_rate <= FEE_DENOMINATOR`
2. **Balance Non-Negative**: All token balances are non-negative
3. **Permission Hierarchy**: Strict separation between permission tiers
4. **Agent Restriction**: Agents cannot withdraw user funds
5. **Protocol Check**: Protocol operations require no active agents

### Upgrade Considerations
1. **Non-Upgradeable**: CDPM contract cannot be upgraded
2. **Dependency Upgrades**: Handled via `user_get_position` functions
3. **Interface Stability**: Cetus DLMM interface changes may break functionality
4. **Migration Path**: New contract deployment with position migration

## Performance Considerations

### Gas Optimization
1. **Batch Operations**: Single transactions for multiple operations
2. **Event Efficiency**: Events contain only necessary data
3. **Storage Minimization**: Clean up unused resources

### Scalability
1. **User Isolation**: Each PositionManager is independent
2. **Parallel Processing**: Multiple users can operate concurrently
3. **Resource Limits**: Sui network limits apply

## Testing Strategy

### Test Categories
1. **Unit Tests**: Individual function testing
2. **Integration Tests**: Cetus DLMM interaction testing
3. **Permission Tests**: Boundary testing for all permission levels
4. **Edge Case Tests**: Fee boundaries, empty states, error conditions

### Test Environment
- Sui testnet/mainnet simulation
- Mock Cetus DLMM dependencies
- Comprehensive event validation

## Future Enhancements

### Planned Improvements
1. **Enhanced Error System**: Categorized error codes
2. **Input Validation**: Additional parameter validation
3. **Testing Suite**: Comprehensive test coverage
4. **Monitoring Tools**: Off-chain monitoring and analytics
5. **Multi-Sig Support**: Enhanced admin security

### Potential Extensions
1. **Position Migration**: Tools for migrating to new contract versions
2. **Advanced Agent Controls**: Granular agent permissions
3. **Fee Tiering**: Different fee rates for different operations
4. **Cross-Pool Management**: Multi-pool position management

---

*Last Updated: 2026-02-28*
*Design Document Version: 1.0*
*Contract Version: As analyzed in `sources/cdpm.move`*