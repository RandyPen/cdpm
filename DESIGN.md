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
    lending: Bag,               // Scallop sCoin holdings (String -> ScallopVault<T>)
}

public struct ScallopVault<phantom T> has store {
    scoin: Balance<MarketCoin<T>>,   // Scallop sCoin, type-pinned to MarketCoin<T>
    principal: u64,                  // Underlying principal supplied (net of redemptions)
}
```

**Key Characteristics:**
- **Owner**: Immutable after creation, controls all owner functions
- **Agents**: Dynamic set, can be added/removed by owner
- **Position**: Optional, exists when user has active liquidity
- **Balance**: Generic token balances for deposit/withdrawal
- **Fee**: Accumulated fees from agent/protocol operations
- **Lending**: Scallop sCoin `MarketCoin<T>` wrapped per underlying type along with cumulative principal; populated by `start_supply` / `finish_supply`, drained by `start_redeem` / `finish_redeem` / `user_extract_market_coin`. The sCoin type is pinned by Move's type system, blocking fake-sCoin extraction attacks.

### 2. FeeHouse
Global protocol fee management structure.

```move
public struct FeeHouse has key {
    id: UID,
    fee_rate: u64,  // Protocol fee rate (0-10000), capped at MAX_FEE_RATE = 3000 (30%)
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
- Set protocol fee rate (0-30%; capped at `MAX_FEE_RATE = 3000` / `FEE_DENOMINATOR = 10000`)
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
- **Maximum Fee Rate:** `MAX_FEE_RATE = 3000`/10000 = 30% (enforced by `admin_set_fee`)
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
   user_deposit_liquidity()  → PositionManagerCreated  (creates a fresh Cetus position from coins)
   user_deposit_position()   → PositionManagerCreated  (wraps an existing Position into a new PM)
   State: position = some, balance = empty, fee = empty, lending = empty, agents = empty

2. Normal Operations
   - Add/remove liquidity (position or balance side)
   - Collect fees/rewards
   - Manage agents
   - Deposit/withdraw funds
   - Supply / redeem idle balance to Scallop (start_supply / finish_supply / start_redeem / finish_redeem)

3. Closure
   user_close_pm() → PositionManagerClosed
   Precondition: lending must be empty (ELendingNotEmpty otherwise).
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
const ENotOwner: u64        = 1001;  // caller is not pm.owner
const ENotAllow: u64        = 1002;  // caller not in agents / access list
const EInvalidFeeRate: u64  = 1003;  // admin_set_fee given rate > MAX_FEE_RATE (30%)
const ELendingNotEmpty: u64 = 1004;  // user_close_pm called with non-empty lending Bag
const ENoSuchVault: u64     = 1005;  // pull_from_lending called for an absent (T, S) vault
const EReserveEmpty: u64    = 1006;  // Scallop reserve has zero supply or zero (cash+debt-revenue)
const EZeroExpected: u64    = 1007;  // start_* would yield 0 scoin/underlying (amount too small)
const EWrongPm: u64         = 1008;  // hot-potato ticket consumed against a different PM
const EAmountShortfall: u64 = 1009;  // finish_* received Coin with value < ticket.expected
```

### Error Code Recommendations (Future Improvement)
Suggested categorization:
- **1000-1999**: Permission errors
- **2000-2999**: Parameter validation errors
- **3000-3999**: State-related errors
- **4000-4999**: External dependency errors

## Security Considerations

### Contract Invariants
1. **Fee Rate Bound**: `0 <= fee_rate <= MAX_FEE_RATE` (3000 / 10000 = 30%); enforced by `admin_set_fee`
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

## Scallop Lending Integration (D-08 / D-09)

The PM proxies idle balances into the Scallop lending market through a
**hot-potato decoupling** pattern. cdpm does not call Scallop's `mint` /
`redeem` / `Version` from inside the contract — those are invoked by the
caller in the same PTB. cdpm exposes paired `start_*` / `finish_*` functions
that yield/consume non-droppable tickets, with conversion amounts computed
on-chain from Scallop's `balance_sheet` so callers cannot fabricate them.

### Decoupling rationale
Scallop's `Version` is bumped frequently. If cdpm imported `protocol::mint` /
`protocol::redeem`, every `Version` bump would freeze cdpm's lending API,
forcing a full cdpm redeploy (cdpm is non-upgradeable). With hot-potato:

- cdpm imports only **view types and view functions** (`protocol::market::vault`,
  `protocol::reserve::balance_sheets` / `balance_sheet`,
  `protocol::reserve::MarketCoin` as a phantom-type pin on the lending
  vault, and `x::wit_table::borrow`). None of these enforce `Version`;
  `MarketCoin<T>` is a pure marker struct (`has drop`) defined in
  `protocol::reserve` and never touches the runtime version checks that live
  in `protocol::mint` / `redeem` / `accrue_interest`.
- Caller PTB calls Scallop's `accrue_interest`, `mint`, `redeem` directly
  with the live Version object. When Scallop bumps Version, only the caller
  PTB aborts; cdpm itself stays untouched and `pm.lending` remains
  recoverable via the owner-only escape hatch.

### Public surface
```move
public fun start_supply<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    market: &Market,            // read-only view
    amount: u64,
    ctx: &mut TxContext,
): (Coin<T>, SupplyTicket<T>);

public fun finish_supply<T>(
    pm: &mut PositionManager,
    ticket: SupplyTicket<T>,
    scoin: Coin<MarketCoin<T>>,
);

public fun start_redeem<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    market: &Market,
    market_coin_amount: u64,    // u64::MAX redeems all
    ctx: &mut TxContext,
): (Coin<MarketCoin<T>>, RedeemTicket<T>);

public fun finish_redeem<T>(
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    ticket: RedeemTicket<T>,
    underlying: Coin<T>,
    ctx: &mut TxContext,
);

public fun user_extract_market_coin<T>(
    pm: &mut PositionManager,
    market_coin_amount: u64,    // u64::MAX extracts all
    ctx: &mut TxContext,
): Coin<MarketCoin<T>>;
```

`SupplyTicket<T>` and `RedeemTicket<T>` are hot potatoes (no `key` /
`store` / `copy` / `drop`) — they must be consumed by their paired finisher
in the same PTB. Move's type system enforces this.

### Caller authorization
`start_*` / `finish_*` accept all three managed-tier callers (owner / agent /
(protocol & no agents)) via `assert_caller_authorized`.
`user_extract_market_coin` is **owner-only** and takes no Scallop objects, so
it remains usable even when Scallop is unreachable.

### Computed-amount integrity
The conversion amount in each ticket is computed by cdpm from Scallop's
balance sheet, not provided by the caller:

```
expected_scoin       = floor(coin × supply / (cash + debt − revenue))
expected_underlying  = floor(scoin × (cash + debt − revenue) / supply)
```

`finish_*` asserts `actual >= expected` (`EAmountShortfall`):

- For supply: Scallop must mint at least the sCoin amount cdpm computed.
- For redeem: Scallop must return at least the underlying amount cdpm
  computed.

This blocks the agent-extraction attack on TWO axes:

1. **Type pin** — `finish_supply`'s `scoin` parameter is typed
   `Coin<MarketCoin<T>>`, not a free generic `Coin<S>`. `MarketCoin<T>` has
   only `drop` and no public constructor; the only way to obtain a non-zero
   `Coin<MarketCoin<T>>` is through Scallop's `mint`. An agent cannot mint
   their own coin type and pass it as fake sCoin.
2. **Quantity floor** — `actual >= expected` ensures Scallop's `mint` was
   actually invoked with the diverted underlying, not bypassed.

Together these make agent extraction economically null: stealing `Coin<T>`
forces the agent to deliver an authentic `Coin<MarketCoin<T>>` of equivalent
value, which itself costs equivalent `Coin<T>` to mint at Scallop. There is
no upper bound on `actual` — `actual > expected` is permitted because any
"extra" came from the caller's own pocket (donation) or from accrued interest
the caller helpfully realized; in either case the protocol/user benefit and
there is no exploitation path. The intentional asymmetry means PTBs that skip
`accrue_interest_for_market` succeed only when Scallop returns *more* than
cdpm's stale view (redeem direction) and abort cleanly when Scallop returns
*less* (supply direction); no fund loss in either case.

There is no admin-tunable drift; the contract surface is a tight `>=`.

### PTB contract (caller side)
Callers MUST call Scallop's `accrue_interest_for_market(version, market,
clock)` as the first PTB command. Without it, `balance_sheet` returns stale
data and `expected ≠ actual`, causing `finish_*` to abort cleanly (no
fund loss). Templates:

**Supply**
```
PTB[0] accrue_interest::accrue_interest_for_market(version, market, clock)
PTB[1] (coin_t, ticket) = cdpm::start_supply<T>(access, pm, market, amount)
PTB[2] scoin = mint::mint<T>(version, market, coin_t, clock)
PTB[3] cdpm::finish_supply<T>(pm, ticket, scoin)
```

**Redeem**
```
PTB[0] accrue_interest::accrue_interest_for_market(version, market, clock)
PTB[1] (scoin, ticket) = cdpm::start_redeem<T>(access, pm, market, market_coin_amount)
PTB[2] underlying = redeem::redeem<T>(version, market, scoin, clock)
PTB[3] cdpm::finish_redeem<T>(pm, fee_house, ticket, underlying)
```

### Yield fee model
Unlike swap fee / reward collection (D-01), every `finish_redeem` call
deducts `fee_rate` on the **interest portion** regardless of caller, because
lending interest is a recurring protocol-managed yield rather than a
self-managed activity. Principal is amortized linearly when partial-redeeming
sCoin:

```
principal_portion = ScallopVault.principal × redeem_scoin_amount / total_scoin
interest          = max(0, redeemed_underlying - principal_portion)
fee_amount        = interest × FeeHouse.fee_rate / FEE_DENOMINATOR
```

When `redeemed_underlying ≤ principal_portion` (e.g. socialized loss),
`fee_amount = 0` and the user does not pay tax on a principal shortfall.

### Lifecycle invariants
- `user_close_pm` aborts with `ELendingNotEmpty` if `pm.lending` still holds
  any vault; callers must redeem (or extract) first.
- Re-entry of extracted assets must go through `Coin<T>` (after external
  redemption) and `user_add_liquidity_to_balance` — no inverse
  `user_inject_market_coin` exists, by design (D-09).
- **The sCoin type is fixed to `MarketCoin<T>` for any given underlying `T`.**
  cdpm's lending vault is `ScallopVault<phantom T> { scoin: Balance<MarketCoin<T>> }`.
  There is no longer a free `S` type parameter on the public surface, so
  the `(T, S1)` vs `(T, S2)` collision case from earlier hot-potato drafts
  cannot arise. Migration to a different Scallop sCoin type identity (e.g.
  Scallop publishes a new package with a fresh `MarketCoin<T>` definition)
  requires a fresh cdpm deploy that imports the new type — a rare event
  treated like any other Sui struct-identity change.

### Events (no `by` field; tx metadata records the sender; no `scoin_type` — sCoin is always `MarketCoin<T>`)
```move
public struct ScallopSupplied   { pm_id, coin_type, deposit_amount,
                                  market_coin_minted };
public struct ScallopRedeemed   { pm_id, coin_type, market_coin_redeemed,
                                  redeemed_amount, principal_portion, interest,
                                  fee_amount };
public struct MarketCoinExtracted { pm_id, coin_type, market_coin_amount,
                                    principal_removed };
```

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