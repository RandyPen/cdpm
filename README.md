# CDPM - Cetus DLMM Position Manager

published at: 0xbb15c25329fbc85b9cc9cc1d37ee2f913696a7c688d0552ca4dc7e3557598541  
package immutable: 4Hf19dTMwHVoSbMAyTysyJpvtELwhFw2yhXkXMshcqVb

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

> The fee rate is capped at 30% (`MAX_FEE_RATE = 3000`) via `admin_set_fee`. This bound limits admin authority and cannot be bypassed without redeploying.

### Fee Distribution
1. **User Operations**: No protocol fee
2. **Protocol Operations**: Protocol takes fee (default 20%)
3. **Agent Operations**: No protocol fee (fees go to user's fee bag)

## Design Notes

The following behaviors are **intentional design choices**, not defects. They
are documented here so that integrators and auditors do not mistake them for
bugs.

### D-01: Protocol Fee Only Applies to Protocol-Executed Collections
The `fee_rate` in `FeeHouse` is a **service fee for protocol-executed
automation**, not a tax on all yield generated by the position.

- `protocol_collect_fee` / `protocol_collect_reward` call `take_fee` and deduct
  the configured rate.
- `user_collect_fee` / `user_collect_reward` and
  `agent_collect_fee` / `agent_collect_reward` **do not charge a fee**;
  100% of the collected yield is credited to the user's fee bag.

Rationale: users who self-manage (or delegate to their own agent) are not
consuming protocol automation services, so no fee is charged.

### D-02: Empty `agents` Set Means "Protocol May Operate"
Each `PositionManager` has an `agents: VecSet<address>` field that acts as a
**mutually exclusive switch** between protocol-managed and agent-managed modes:

| `agents` state | Who may call `protocol_*` | Who may call `agent_*` |
| --- | --- | --- |
| empty (default) | whitelisted protocol addresses | nobody |
| non-empty       | nobody                         | only addresses in `agents` |

When the owner authorizes at least one agent, the protocol is automatically
excluded from managing the position — the user has opted into a custom agent
and the protocol must step aside. Conversely, when no agent is configured, the
position is considered opted into protocol management.

### D-03: `fee_rate` Changes Take Effect Immediately
`admin_set_fee` updates `FeeHouse.fee_rate` without a timelock or per-position
checkpoint. The new rate applies to the next `protocol_collect_*` call,
including any Cetus fees/rewards that accrued before the rate change.

Rationale: rebalancing and fee collection happen **frequently**, so the amount
of yield that could possibly accrue between two rate changes is small. The
economic impact of retroactive application is therefore bounded and acceptable
in exchange for operational simplicity.

### D-04: `withdraw_from_balance` / `withdraw_from_fee` Truncate on Insufficient Balance
When the requested `amount` is greater than or equal to the current balance,
the internal withdrawal helpers return the **entire available balance** rather
than aborting:

```move
if (amount >= balance_amount) {
    bag::remove<String, Balance<T>>(&mut pm.balance, coin_type).into_coin(ctx)
} else {
    balance::split<T>(bag::borrow_mut(&mut pm.balance, coin_type), amount).into_coin(ctx)
}
```

This is **intentional**. It lets callers pass a conservative upper bound (for
example `u64::MAX` for "withdraw everything") and guarantees that dust from
rounding never strands a bag entry. Downstream functions that require an exact
amount (e.g. `pool::add_liquidity`) will still abort, so no funds can be lost.

### D-05: Contract Is Intentionally Immutable
The CDPM package is published as immutable (see the `package immutable:
AGwrmbp...` line near the top of this README). There is no pause switch, no
upgrade path, and no emergency admin override beyond `admin_set_fee` (now
capped at 30%) and `admin_transfer`.

Rationale: users get guaranteed semantics; no admin can silently change
behavior. If Cetus DLMM publishes a breaking upgrade, the response is to
publish a **new** CDPM package, not to mutate this one. Users keep full
control via `user_get_and_return_position` (see D-07) and can migrate
positions manually into the new deployment.

### D-06: `user_close_pm` Forfeits Uncollected Reward Tokens
`pool::close_position` (called inside `user_close_pm`) returns only the
underlying token balances and accumulated trading fees. Any **incentive reward
tokens** still held by the position are destroyed together with the internal
`ClosePositionCert`.

This is not fixed at the contract layer because the set of `RewardType`s is
pool-specific and not known statically (a pool may have 1–3 reward tokens).

**How to close safely**: build a PTB that first calls
`user_collect_reward<CoinTypeA, CoinTypeB, RewardType>` once for every reward
type on the pool, then calls `user_close_pm` in the same transaction. The
user-sdk skill documents a helper; see
`skills/cdpm-user-sdk/reference/workflows.md`.

### D-07: `user_get_and_return_position` Is a Cetus-Upgrade Escape Hatch
When Cetus DLMM ships a breaking upgrade that invalidates the current CDPM
package, existing positions could become stranded.
`user_get_and_return_position` lets the owner extract the raw `Position`
object out of their `PositionManager` so they can interact with the upgraded
Cetus package directly, or deposit it into a newly deployed CDPM version via
`user_deposit_position`.

After extraction `pm.position = None`. The original `PositionManager` is
effectively retired: `balance` / `fee` bags can still be withdrawn normally,
and the shell can be closed via `user_close_pm` (the `None` branch handles
this). There is intentionally no "put back into the same PM" function —
migration flows through a fresh PM.

## Security Features

### 1. Permission Separation
- Clear boundaries between owner, agent, protocol, and admin roles
- Agent-limited operations (cannot withdraw funds)
- Protocol access controlled by admin-managed allow list

### 2. Input Validation
- Fee rate bounds checking (0-100%)
- Permission validation on all operations
- Safe mathematical operations (u128 for fee calculations)

### 3. Event System
Comprehensive event emission for all operations:
- Position creation/closing
- Liquidity addition/removal
- Fee/reward collection
- Agent management
- Admin operations

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