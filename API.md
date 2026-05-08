# CDPM API Reference

## Overview

This document provides a complete reference for all public functions in the CDPM (Cetus DLMM Position Manager) smart contract. Functions are organized by permission level and category.

## Permission Levels

| Level | Identifier | Key Functions |
|-------|------------|---------------|
| **Owner** | `pm.owner == ctx.sender()` | `user_*` functions |
| **Agent** | `vec_set::contains<address>(&pm.agents, &ctx.sender())` | `agent_*` functions |
| **Protocol** | `vec_set::contains<address>(&access.allow, &ctx.sender())` AND `vec_set::is_empty<address>(&pm.agents)` | `protocol_*` functions |
| **Admin** | Holds `AdminCap` | `admin_*` functions |

## User Functions (Owner Permission)

Functions that require the caller to be the owner of the PositionManager.

### 1. Position Creation and Management

#### `user_deposit`
Creates a new PositionManager with initial liquidity.

```move
public fun user_deposit<CoinTypeA, CoinTypeB>(
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
)
```

**Parameters:**
- `record`: User's Record for position tracking
- `pool`: Cetus DLMM pool reference
- `coin_a`, `coin_b`: Input coins for liquidity
- `bins`: Target bin indices
- `amounts_a`, `amounts_b`: Amounts per bin
- `config`: Global configuration
- `versioned`: Version compatibility object
- `clk`: Clock for timestamp
- `ctx`: Transaction context

**Events:**
- `PositionManagerCreated`: New PositionManager created

**Notes:**
- Creates new PositionManager with empty agents, balance, and fee
- Opens position in Cetus DLMM with provided liquidity
- Registers PositionManager in user's Record

### 2. Liquidity Management

#### `user_add_liquidity_to_position`
Adds liquidity to an existing position.

```move
public fun user_add_liquidity_to_position<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
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
)
```

**Events:**
- `LiquidityAdded`: Liquidity added with amounts and bin count

#### `user_remove_liquidity_from_position`
Removes liquidity from a position.

```move
public fun user_remove_liquidity_from_position<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    bins: vector<u32>,
    liquidity_shares: vector<u128>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
): (Coin<CoinTypeA>, Coin<CoinTypeB>)
```

**Returns:** Removed coins (CoinTypeA, CoinTypeB)

**Events:**
- `LiquidityRemoved`: Liquidity removed with bin count

### 3. Fee and Reward Collection

#### `user_collect_fee`
Collects fees from a position.

```move
public fun user_collect_fee<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
): (Coin<CoinTypeA>, Coin<CoinTypeB>)
```

**Returns:** Collected fee coins

**Events:**
- `FeeCollected`: Fees collected with amounts and coin types

#### `user_collect_reward`
Collects rewards from a position.

```move
public fun user_collect_reward<CoinTypeA, CoinTypeB, RewardType>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
): (Coin<RewardType>)
```

**Returns:** Collected reward coin

**Events:**
- `RewardCollected`: Reward collected with amount and coin type

### 4. Balance Management

#### `user_add_liquidity_to_balance`
Deposits coins to PositionManager balance.

```move
public fun user_add_liquidity_to_balance<T>(
    pm: &mut PositionManager,
    coin: Coin<T>,
    clk: &Clock,
    ctx: &TxContext,
)
```

**Events:**
- `BalanceDeposited`: Coin deposited with amount and type

#### `user_remove_liquidity_from_balance`
Withdraws coins from PositionManager balance.

```move
public fun user_remove_liquidity_from_balance<T>(
    pm: &mut PositionManager,
    amount: u64,
    clk: &Clock,
    ctx: &mut TxContext,
): (Coin<T>)
```

**Returns:** Withdrawn coin

**Events:**
- `BalanceWithdrawn`: Coin withdrawn with amount and type

#### `user_withdraw_fee`
Withdraws coins from fee bag.

```move
public fun user_withdraw_fee<T>(
    pm: &mut PositionManager,
    amount: u64,
    clk: &Clock,
    ctx: &mut TxContext,
): (Coin<T>)
```

**Returns:** Withdrawn fee coin

**Events:**
- `UserFeeWithdrawn`: Fee withdrawn with amount and coin type

### 5. Agent Management

#### `user_insert_agent`
Authorizes an agent address.

```move
public fun user_insert_agent(
    pm: &mut PositionManager,
    agent: address,
    clk: &Clock,
    ctx: &TxContext,
)
```

**Events:**
- `AgentAdded`: Agent authorized

#### `user_remove_agent`
Revokes agent authorization.

```move
public fun user_remove_agent(
    pm: &mut PositionManager,
    agent: address,
    clk: &Clock,
    ctx: &TxContext,
)
```

**Events:**
- `AgentRemoved`: Agent authorization revoked

### 6. Position Closure

#### `user_close_pm`
Closes a PositionManager and returns all funds.

```move
public fun user_close_pm<CoinTypeA, CoinTypeB>(
    record: &mut Record,
    pm: PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
)
```

**Events:**
- `PositionManagerClosed`: PositionManager closed
- If position exists: Position closed in Cetus DLMM

**Notes:**
- Returns all funds to owner
- Destroys PositionManager resources
- Removes from user's Record

## Protocol Functions (AccessList Permission)

Functions that require the caller to be in the AccessList AND no active agents.

### 1. Liquidity Management

#### `protocol_add_liquidity`
Protocol adds liquidity (with protocol fee on rewards).

```move
public fun protocol_add_liquidity<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    amount_a: u64,
    amount_b: u64,
    bins: vector<u32>,
    amounts_a: vector<u64>,
    amounts_b: vector<u64>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
)
```

**Notes:**
- Withdraws specified amounts from balance
- Adds liquidity to position
- Returns any unused amounts to balance
- No immediate fee collection

#### `protocol_remove_liquidity`
Protocol removes liquidity.

```move
public fun protocol_remove_liquidity<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    bins: vector<u32>,
    liquidity_shares: vector<u128>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
)
```

**Notes:**
- Removes liquidity from position
- Adds returned coins to balance

### 2. Fee and Reward Collection (with Protocol Fee)

#### `protocol_collect_fee`
Protocol collects fees (deducts protocol fee).

```move
public fun protocol_collect_fee<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    fee_house: &mut FeeHouse,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
)
```

**Fee Distribution:**
- Protocol fee calculated based on `fee_house.fee_rate`
- Protocol fee added to `fee_house.fee`
- Remaining fees added to user's `pm.fee`

**Events:**
- `ProtocolFeeCollected`: Fees collected with amounts, fees, and coin types

#### `protocol_collect_reward`
Protocol collects rewards (deducts protocol fee).

```move
public fun protocol_collect_reward<CoinTypeA, CoinTypeB, RewardType>(
    access: &AccessList,
    fee_house: &mut FeeHouse,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
)
```

**Events:**
- `ProtocolRewardCollected`: Reward collected with amount, fee, and coin type

### 3. Balance Transfers

#### `protocol_transfer_fee_to_balance`
Transfers fees from fee bag to balance.

```move
public fun protocol_transfer_fee_to_balance<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    amount: u64,
    clk: &Clock,
    ctx: &mut TxContext,
)
```

**Events:**
- `FeeTransferredToBalance`: Fees transferred with amount and coin type

### 4. Emergency Functions

#### `protocol_close_position_emergency`
Emergency position closure (no fee collection).

```move
public fun protocol_close_position_emergency<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
)
```

**Use Case:** Cetus DLMM contract upgrade scenarios

**Events:**
- `EmergencyPositionClosed`: Position closed via emergency

#### `protocol_collect_fee_emergency`
Emergency fee collection (no protocol fee).

```move
public fun protocol_collect_fee_emergency<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    _clk: &Clock,
    ctx: &mut TxContext,
)
```

**Notes:** Adds fees directly to user's `pm.fee` without protocol cut

#### `protocol_collect_reward_emergency`
Emergency reward collection (no protocol fee).

```move
public fun protocol_collect_reward_emergency<CoinTypeA, CoinTypeB, RewardType>(
    access: &AccessList,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    _clk: &Clock,
    ctx: &mut TxContext,
)
```

## Agent Functions (Agent Permission)

Functions that require the caller to be an authorized agent.

### 1. Liquidity Management

#### `agent_add_liquidity`
Agent adds liquidity.

```move
public fun agent_add_liquidity<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    amount_a: u64,
    amount_b: u64,
    bins: vector<u32>,
    amounts_a: vector<u64>,
    amounts_b: vector<u64>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
)
```

**Notes:**
- Withdraws from balance
- Adds liquidity to position
- Returns unused amounts to balance

#### `agent_remove_liquidity`
Agent removes liquidity.

```move
public fun agent_remove_liquidity<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    bins: vector<u32>,
    liquidity_shares: vector<u128>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
)
```

**Notes:** Adds returned coins to balance

### 2. Fee and Reward Collection

#### `agent_collect_fee`
Agent collects fees.

```move
public fun agent_collect_fee<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    _clk: &Clock,
    ctx: &mut TxContext,
)
```

**Notes:** Adds fees to user's `pm.fee`

#### `agent_collect_reward`
Agent collects rewards.

```move
public fun agent_collect_reward<CoinTypeA, CoinTypeB, RewardType>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    _clk: &Clock,
    ctx: &mut TxContext,
)
```

**Notes:** Adds rewards to user's `pm.fee`

## Admin Functions (AdminCap Permission)

Functions that require the caller to hold the AdminCap.

### 1. Fee Management

#### `admin_set_fee`
Sets the protocol fee rate.

```move
public fun admin_set_fee(
    _: &AdminCap,
    fee_house: &mut FeeHouse,
    fee_rate: u64,
    clk: &Clock,
    ctx: &TxContext,
)
```

**Validation:** `fee_rate <= FEE_DENOMINATOR` (10000 = 100%)

**Events:**
- `FeeRateUpdated`: Old and new fee rates

#### `admin_collect_fee`
Collects accumulated protocol fees.

```move
public fun admin_collect_fee<T>(
    _: &AdminCap,
    fee_house: &mut FeeHouse,
    clk: &Clock,
    ctx: &mut TxContext,
): Coin<T>
```

**Returns:** Collected protocol fees

**Events:**
- `AdminFeeCollected`: Fees collected with amount and coin type

### 2. Access List Management

#### `admin_insert_access_list`
Adds address to AccessList.

```move
public fun admin_insert_access_list(
    _: &AdminCap,
    access: &mut AccessList,
    bot: address,
    clk: &Clock,
    ctx: &TxContext,
)
```

**Events:**
- `AccessGranted`: Address added to AccessList

#### `admin_remove_access_list`
Removes address from AccessList.

```move
public fun admin_remove_access_list(
    _: &AdminCap,
    access: &mut AccessList,
    bot: address,
    clk: &Clock,
    ctx: &TxContext,
)
```

**Events:**
- `AccessRevoked`: Address removed from AccessList

### 3. Admin Transfer

#### `admin_transfer`
Transfers AdminCap to new address.

```move
public fun admin_transfer(
    admin_cap: AdminCap,
    to: address,
    clk: &Clock,
    ctx: &TxContext,
)
```

**Events:**
- `AdminTransferred`: AdminCap transferred from/to addresses

## Record Management Functions

### `register_and_return_record`
Registers a new user record.

```move
public fun register_and_return_record(
    global_record: &mut GlobalRecord,
    ctx: &mut TxContext,
): Record
```

**Returns:** New Record for the caller

**Notes:** Called automatically when needed

### `share_record`
Shares a Record for public access.

```move
public fun share_record(
    record: Record
)
```

**Notes:** Makes Record accessible for position management

## Event Reference

### Event Structures

#### FeeCollected
```move
public struct FeeCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type_a: String,  // Coin type of token A
    coin_type_b: String,  // Coin type of token B
    amount_a: u64,
    amount_b: u64,
    by: address,
    timestamp: u64,
}
```

#### RewardCollected
```move
public struct RewardCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type: String,  // Coin type of the reward token
    amount: u64,
    by: address,
    timestamp: u64,
}
```

#### ProtocolFeeCollected
```move
public struct ProtocolFeeCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type_a: String,  // Coin type of token A
    coin_type_b: String,  // Coin type of token B
    amount_a: u64,        // Amount after fee (user portion)
    amount_b: u64,        // Amount after fee (user portion)
    fee_a: u64,           // Protocol fee amount (token A)
    fee_b: u64,           // Protocol fee amount (token B)
    timestamp: u64,
}
```

#### ProtocolRewardCollected
```move
public struct ProtocolRewardCollected has copy, drop {
    pm_id: ID,
    pool_id: ID,
    coin_type: String,  // Coin type of the reward token
    amount: u64,        // Amount after fee (user portion)
    fee_amount: u64,    // Protocol fee amount
    timestamp: u64,
}
```

#### Complete Event List
- Position management: `PositionManagerCreated`, `PositionManagerClosed`
- Liquidity: `LiquidityAdded`, `LiquidityRemoved`
- Fees/rewards: `FeeCollected`, `RewardCollected`, `ProtocolFeeCollected`, `ProtocolRewardCollected`, `UserFeeWithdrawn`, `AdminFeeCollected`
- Balance: `BalanceDeposited`, `BalanceWithdrawn`, `FeeTransferredToBalance`
- Agents: `AgentAdded`, `AgentRemoved`
- Admin: `FeeRateUpdated`, `AccessGranted`, `AccessRevoked`, `AdminTransferred`
- Emergency: `EmergencyPositionClosed`

## Error Codes

### Current Error Codes
```move
const ENotOwner: u64 = 1001;      // Caller is not the owner
const ENotAllow: u64 = 1002;      // Caller not authorized (agent/protocol)
const EInvalidFeeRate: u64 = 2001; // Fee rate exceeds FEE_DENOMINATOR
```

### Recommended Additional Error Codes
```move
// Proposed future error codes
const EInvalidAmount: u64 = 2002;      // Amount must be > 0
const EInvalidArrayLength: u64 = 2003; // Array length mismatch
const EInsufficientBalance: u64 = 3001; // Insufficient balance
const EPositionNotExist: u64 = 3002;   // Position does not exist
```

## Constants

### `FEE_DENOMINATOR`
```move
const FEE_DENOMINATOR: u128 = 10000;  // 100% in basis points
```

**Usage:** `fee_amount = amount * fee_rate / FEE_DENOMINATOR`

### Default Fee Rate
Default protocol fee rate: 2000 = 20%

## Type Parameters

### Generic Type Parameters
- `<CoinTypeA, CoinTypeB>`: Pool token types
- `<RewardType>`: Reward token type
- `<T>`: Generic token type

### Common Parameters
- `pm: &mut PositionManager`: Position manager reference
- `pool: &mut Pool<CoinTypeA, CoinTypeB>`: Cetus DLMM pool
- `config: &GlobalConfig`: Global configuration
- `versioned: &Versioned`: Version compatibility
- `clk: &Clock`: Timestamp source
- `ctx: &mut TxContext`: Transaction context

## Best Practices

### 1. Error Handling
- Check return values and error codes
- Validate inputs before operations
- Use appropriate error codes for different failure scenarios

### 2. Event Monitoring
- Monitor all emitted events for off-chain tracking
- Use event data for analytics and accounting
- Validate event consistency with operations

### 3. Permission Management
- Follow principle of least privilege
- Regularly review agent authorizations
- Secure AdminCap with appropriate safeguards

### 4. Emergency Preparedness
- Have emergency procedures for dependency upgrades
- Monitor Cetus DLMM for upcoming changes
- Test emergency functions regularly

## Examples

### Example 1: User Creates Position and Adds Agent
```move
// 1. Create position
user_deposit<USDC, USDT>(record, pool, &mut usdc_coin, &mut usdt_coin, bins, amounts_a, amounts_b, config, versioned, clk, ctx);

// 2. Authorize agent
user_insert_agent(pm, agent_address, clk, ctx);
```

### Example 2: Protocol Collects Fees with 20% Fee
```move
// Protocol collects fees (20% protocol fee)
protocol_collect_fee<USDC, USDT>(access, fee_house, pm, pool, config, versioned, clk, ctx);
// Results: 80% to user's fee bag, 20% to protocol fee bag
```

### Example 3: Emergency Position Closure
```move
// Emergency closure during Cetus DLMM upgrade
protocol_close_position_emergency<USDC, USDT>(access, pm, pool, config, versioned, clk, ctx);
// Position closed, funds returned to balance (no fee collection)
```

---

*Last Updated: 2026-02-28*
*API Documentation Version: 1.0*
*Contract Version: As analyzed in `sources/cdpm.move`*