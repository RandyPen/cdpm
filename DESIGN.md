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
- **Lending**: Scallop sCoin `MarketCoin<T>` (or Kai SAV YT) wrapped per underlying type along with cumulative principal; populated by `scallop_start_supply` / `scallop_finish_supply` (Kai: `kai_start_supply` / `kai_finish_supply`), drained **exclusively** by `scallop_start_redeem` / `scallop_finish_redeem` (Kai: `kai_start_redeem` / `kai_finish_redeem`). The wrapper type is pinned by Move's type system, blocking fake-wrapper attacks. There is **no escape hatch** for lending: the only way to exit a lending position is to redeem through the upstream protocol's normal path, which lands the underlying in `pm.balance`; the user then withdraws via `user_remove_liquidity_from_balance`.

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
- **Move fees from `fee` bag back into `balance`** via `agent_transfer_fee_to_balance` (intentional auto-compound surface — see §Permission Boundaries below)
- Cannot transfer funds out of the PositionManager
- Cannot modify PositionManager configuration (owner / agents list / position open or close)

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

### Permission Boundaries — Operational Notes

These are intentional design choices. Front-ends and SDKs MUST surface them:

1. **Agents may auto-compound fees.** `agent_transfer_fee_to_balance<T>` lets an authorized agent migrate accumulated `fee` bag entries into `balance`, where they can be redeployed as liquidity by `agent_add_liquidity`. Owners who want fees to settle into a withdraw-only bucket should NOT keep an agent authorized while fees accrue. Funds never leave the PositionManager — only the bucket changes — but the agent does effectively control reinvestment of realized fees.

2. **`user_close_pm` requires zero pending pool rewards.** `pool::close_position` returns a `ClosePositionCert` whose embedded reward state must be drained before `pool::destroy_close_position_cert` is called; otherwise Cetus aborts with `EPositionRewardNotZero`. CDPM does not iterate reward types inside `user_close_pm` (reward types are generic and unknown to the function). Caller responsibility: invoke `user_collect_reward<CoinTypeA, CoinTypeB, R>` for **every** reward type the underlying pool emits, in the same PTB or earlier transactions, before calling `user_close_pm`. SDKs should query the pool's reward types and emit the matching collect calls automatically. Same applies to `pm.lending` — redeem all Scallop / Kai positions first, otherwise close aborts with `ELendingNotEmpty`.

3. **`withdraw_from_balance` / `withdraw_from_fee` short-circuit `amount == 0` to `coin::zero<T>(ctx)`** (no Bag access). Single-sided `protocol_/agent_add_liquidity` therefore works without seeding the unused side. Callers requesting `amount > 0` of a type the PM has never held still abort with `ENoSuchBalance` (1010); SDKs should query the bag before requesting a positive withdraw.

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
   - Supply / redeem idle balance to Scallop (scallop_start_supply / scallop_finish_supply / scallop_start_redeem / scallop_finish_redeem)

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
const ENoSuchVault: u64     = 1005;  // pull_from_scallop_lending called for an absent (T, S) vault
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
  PTB aborts; cdpm itself stays untouched. `pm.lending` is still recoverable
  by retrying once Scallop publishes a SDK update against the new Version —
  the only exit path is the normal `scallop_start_redeem` /
  `scallop_finish_redeem` flow, which deposits the underlying into
  `pm.balance`. cdpm intentionally provides **no escape hatch** that hands
  raw `Coin<MarketCoin<T>>` back to the user, because the wrapper has no
  utility outside of redemption against Scallop's reserve.

### Public surface
```move
public fun scallop_start_supply<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    market: &Market,            // read-only view
    amount: u64,
    ctx: &mut TxContext,
): (Coin<T>, ScallopSupplyTicket<T>);

public fun scallop_finish_supply<T>(
    pm: &mut PositionManager,
    ticket: ScallopSupplyTicket<T>,
    scoin: Coin<MarketCoin<T>>,
);

public fun scallop_start_redeem<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    market: &Market,
    market_coin_amount: u64,    // u64::MAX redeems all
    ctx: &mut TxContext,
): (Coin<MarketCoin<T>>, ScallopRedeemTicket<T>);

public fun scallop_finish_redeem<T>(
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    ticket: ScallopRedeemTicket<T>,
    underlying: Coin<T>,
    ctx: &mut TxContext,
);
```

`ScallopSupplyTicket<T>` and `ScallopRedeemTicket<T>` are hot potatoes (no `key` /
`store` / `copy` / `drop`) — they must be consumed by their paired finisher
in the same PTB. Move's type system enforces this.

### Caller authorization
`start_*` / `finish_*` accept all three managed-tier callers (owner / agent /
(protocol & no agents)) via `assert_caller_authorized`. There is no
owner-only bypass for the lending wrapper — exit is constrained to the
redeem-into-`pm.balance` path on purpose (see "No escape hatch for lending"
below).

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

1. **Type pin** — `scallop_finish_supply`'s `scoin` parameter is typed
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
PTB[1] (coin_t, ticket) = cdpm::scallop_start_supply<T>(access, pm, market, amount)
PTB[2] scoin = mint::mint<T>(version, market, coin_t, clock)
PTB[3] cdpm::scallop_finish_supply<T>(pm, ticket, scoin)
```

**Redeem**
```
PTB[0] accrue_interest::accrue_interest_for_market(version, market, clock)
PTB[1] (scoin, ticket) = cdpm::scallop_start_redeem<T>(access, pm, market, market_coin_amount)
PTB[2] underlying = redeem::redeem<T>(version, market, scoin, clock)
PTB[3] cdpm::scallop_finish_redeem<T>(pm, fee_house, ticket, underlying)
```

### Yield fee model
Unlike swap fee / reward collection (D-01), every `scallop_finish_redeem` call
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

### Trust boundary

The security ceiling of cdpm's Scallop integration is **the integrity of
the Scallop team and their custody of the `ScallopProtocol` package
upgrade-cap + `app::AdminCap`** (`protocol/sources/app/app.move:35`).
A backdoored `protocol::reserve` upgrade can drain the underlying
`Balance<T>` out of every existing `Reserve` shared object — every cdpm
`ScallopVault<T>` would be left holding `Balance<MarketCoin<T>>` that no
longer redeems for anything. The current `AdminCap` already exposes
`add_whitelist_address` / `remove_whitelist_address` /
`reject_all_address` (`app.move:120-160`) plus interest/risk model
mutators with the change-delay enforced at 0; the upgrade-cap can extend
this set arbitrarily.

cdpm intentionally does **not** maintain an admin-curated MarketCoin
whitelist on top of this. External fake-`MarketCoin` is already
structurally impossible (`MarketCoin<T>` has only `drop` and no public
constructor outside `protocol::reserve`), and no whitelist on cdpm's
side can defend against a Scallop-team-issued malicious upgrade — the
attack would just backdoor the whitelisted MarketCoin's underlying
reserve, which is exactly the same `Reserve` shared object cdpm already
trusts. cdpm therefore inherits exactly the same Scallop-trust
assumption every other Scallop consumer takes — no more, no less. We do
not attempt to remove or hide that assumption. The mitigation surface
for users is **agent selection**, not runtime escape:

- **Don't trust Scallop? Don't supply.** Choose an agent / protocol bot
  whose off-chain scheduler does NOT call `scallop_start_supply` for Scallop;
  Scallop integration is opt-in per-strategy.
- **Bound per-PM Scallop exposure** via the off-chain scheduler.

### No escape hatch for lending
cdpm intentionally exposes **no** owner-only function that hands raw
`Coin<MarketCoin<T>>` back to the user. The lending protocol is decoupled
from cdpm at the call boundary — every mutating Scallop call lives in the
caller's PTB — so cdpm itself has no broken state to escape from: a
Scallop Version bump aborts only the caller PTB, not cdpm. The wrapper
also has no off-protocol utility: a `Coin<MarketCoin<T>>` outside cdpm is
only redeemable back through Scallop's `redeem`. Constraining exit to
`scallop_start_redeem` → `scallop_finish_redeem` → `pm.balance` →
`user_remove_liquidity_from_balance` removes a class of "principal-
laundering" footguns (extracting wrappers without burning the cumulative
principal counter that protocol-fee accounting depends on) at zero cost to
the legitimate exit path.

The Cetus DLMM `Position` is the only object cdpm cannot recover from
upstream breakage in-band, because `Position` is held inside cdpm and its
lifecycle is gated by Cetus's `Versioned`. That one case is handled by
the owner-only `user_get_position` / `user_get_and_return_position`
extraction (see "Position lifecycle" section).

### Events (no `by` field; tx metadata records the sender; no `scoin_type` — sCoin is always `MarketCoin<T>`)
```move
public struct ScallopSupplied   { pm_id, coin_type, deposit_amount,
                                  market_coin_minted };
public struct ScallopRedeemed   { pm_id, coin_type, market_coin_redeemed,
                                  redeemed_amount, principal_portion, interest,
                                  fee_amount };
```

## Kai SAV Lending Integration (D-10 / D-11)

The PM proxies idle balances into Kai's **Single-Asset Vault (SAV)**, a
multi-strategy yield optimizer maintained by Kunalabs. SAV is intentionally
the user-facing layer of Kai's stack — it wraps `kai_leverage::supply_pool`
(which requires Kai's access-management `Entity` allowlist) and exposes
permissionless `vault::deposit` / `vault::withdraw` / `redeem_withdraw_ticket`
to third-party integrators.

### Architecture mirror
- Storage: `lending: Bag` (shared with Scallop) keyed by **YT's** `type_name`
  (Bag entry value is `KaiVault<phantom T, phantom YT>`). Same T can hold a
  Scallop vault (key=T) and a Kai vault (key=YT) simultaneously.
- API shape: `kai_start_supply` / `kai_finish_supply` /
  `kai_start_redeem` / `kai_finish_redeem`. No owner-only wrapper-extract
  function: lending exit must go through `kai_finish_redeem` (which deposits
  the underlying into `pm.balance`), then `user_remove_liquidity_from_balance`.
- Fee model: identical to Scallop. `kai_finish_redeem` deducts
  `fee_rate × max(0, redeemed - principal_portion)` from the interest
  portion. `MAX_FEE_RATE = 3000` cap shared.

### Decoupling profile (vs Scallop)
cdpm imports only `kai_sav::vault` (the module, for the `Vault<T, YT>` type
and `total_available_balance` / `total_yt_supply` view functions). cdpm
does **not** import:
- `kai_sav::vault::deposit` / `withdraw` / `redeem_withdraw_ticket` (called
  by caller's PTB only — version-coupled within Kai but isolated from cdpm)
- `kai_leverage::*` (Kai's lower-level lending primitives)
- `access_management::*` (the allowlist framework for `kai_leverage::supply`)
- All strategy modules (`kai_leverage_supply_pool`, `scallop_*` SAV
  strategies, etc.)

When Kai bumps its vault `MODULE_VERSION` (kai-sav-core/vault.move:27),
caller PTB aborts at `vault::deposit/withdraw`; cdpm itself stays
operational. `pm.lending` is recoverable by retrying the normal
`kai_start_redeem` → `vault::withdraw` → `kai_finish_redeem` flow once
Kunalabs ships an SDK update against the new Version; no in-cdpm bypass
is offered or needed.

### Type-pin defense
`Coin<YT>` cannot be forged externally:
1. `lp_treasury: TreasuryCap<YT>` is held inside Kai's `Vault<T, YT>` — only
   `kai_sav::vault` module mints/burns YT balances.
2. `kai_sav::vault::new<T, YT>` is `public(package)` (vault.move:235) — no
   external code can publish a `Vault<T, EvilYT>` shared object with
   attacker-controlled YT.

Therefore cdpm does not need an admin-curated registry of approved Kai
vault IDs. Move's type system suffices.

### Compute helpers
```move
fun compute_expected_yt<T, YT>(vault: &kai_vault::Vault<T, YT>, clock: &Clock, t_amount: u64): u64 {
    let total = kai_vault::total_available_balance<T, YT>(vault, clock);
    let yt_supply = kai_vault::total_yt_supply<T, YT>(vault);
    if (total == 0) { t_amount }
    else { ((yt_supply as u128) * (t_amount as u128) / (total as u128)) as u64 }
}

fun compute_expected_underlying_kai<T, YT>(vault, clock, yt_amount): u64 {
    let total = kai_vault::total_available_balance<T, YT>(vault, clock);
    let yt_supply = kai_vault::total_yt_supply<T, YT>(vault);
    assert!(yt_supply > 0, EReserveEmpty);
    ((yt_amount as u128) * (total as u128) / (yt_supply as u128)) as u64
}
```

`total_available_balance` already accounts for `tlb::max_withdrawable`
(time-locked profit unlock), so cdpm doesn't reimplement that math.

### Caller PTB contract
**Supply** (3 steps, same shape as Scallop):
```
PTB[0] (coin_t, ticket) = cdpm::kai_start_supply<T, YT>(access, pm, vault, amount, clock)
PTB[1] yt_balance = vault::deposit<T, YT>(vault, coin_t.into_balance(), clock)
PTB[2] cdpm::kai_finish_supply<T, YT>(pm, ticket, yt_balance.into_coin())
```

**Redeem** (variable length — vault::withdraw is async via strategies):
```
PTB[0] (yt_coin, ticket) = cdpm::kai_start_redeem<T, YT>(access, pm, vault, yt_amount, clock)
PTB[1] withdraw_ticket = vault::withdraw<T, YT>(vault, yt_coin.into_balance(), clock)
PTB[2..N+1] for each strategy with `to_withdraw > 0`:
            <strategy_module>::strategy_withdraw_for_vault(strategy, vault, withdraw_ticket, ...)
            // strategy module discharges its own access-management ActionRequest internally
PTB[N+2] balance_t = vault::redeem_withdraw_ticket<T, YT>(vault, withdraw_ticket)
PTB[N+3] cdpm::kai_finish_redeem<T, YT>(pm, fee_house, ticket, balance_t.into_coin())
```

The strategy walk is mandatory when the vault has active strategies with
non-zero `to_withdraw`. Caller's SDK enumerates active strategies from
on-chain vault state. cdpm does not track or care about which strategies
the vault uses.

### Operational risks (caller-side, documented for SDK)

1. **Bootstrap (`yt_supply == 0`)**: Kai's deposit auto-mints performance
   fees on first deposit (vault.move:580-598), changing `yt_supply` mid-
   call. cdpm's `compute_expected_yt` returns 0 in this state, triggering
   `EZeroExpected`. Practical: vaults are seeded by Kunalabs before
   public use; cdpm callers won't hit this.
2. **Strategy losses**: vault.move:817-823 — strategy returning less than
   requested doesn't abort the vault, but cdpm's `kai_finish_redeem`
   asserts `actual >= expected_underlying`. PTB aborts atomically; no fund
   loss, only gas waste.
3. **Admin pause / TVL cap / rate limiter** (vault.move:484-548): caller
   PTB aborts at the live `vault::*` call. cdpm unaffected; `pm.lending`
   intact, awaiting unpause / cap raise / next rate-limit window.
4. **Kai package re-deploy with new YT type identity**: `pm.lending`
   continues to hold `Balance<YT_old>` indefinitely; recovery requires
   Kunalabs to publish a migration path for the old YT (e.g., a swap
   vault). cdpm does not attempt to second-guess that recovery — the
   `Balance<YT_old>` is preserved untouched and the principal counter
   stays accurate for any future redemption.

### Trust boundary

The security ceiling of cdpm's Kai integration is **the integrity of the
Kunalabs team and their custody of the `kai_sav` package upgrade-cap**.
A backdoored upgrade to `kai_sav::vault` can drain every existing
`Vault<T, YT>` shared object — and therefore every `KaiVault<T, YT>` in
every cdpm `pm.lending` — irrespective of which YT types cdpm accepts.

cdpm intentionally does **not** maintain an admin-curated YT whitelist.
Such a whitelist would only block external fake-Vault attacks, which are
already structurally impossible (`kai_sav::vault::new` is
`public(package)` — only the kai_sav module itself can publish a
`Vault<T, YT>` shared object). Against the dominant threat (a malicious
or compromised Kunalabs upgrade), a whitelist provides no defense at all
— Kunalabs would just backdoor the existing whitelisted `Vault` rather
than mint a new one. The whitelist would only add ongoing admin
overhead with zero security gain.

cdpm therefore inherits exactly the same Kunalabs-trust assumption every
other Kai SAV consumer (including Kunalabs's own SAV strategies) already
takes — no more, no less. We do not attempt to remove or hide that
assumption. The mitigation surface for users is **agent selection**, not
runtime escape:

- **Don't trust Kai? Don't supply.** Choose an agent / protocol bot whose
  off-chain scheduler does NOT call `kai_start_supply`. The Kai
  integration is opt-in per-strategy; an agent that never invokes
  `kai_start_supply` leaves `pm.lending` Kai-free and the trust
  assumption never accrues.
- **Bound per-PM Kai exposure** via the off-chain scheduler (e.g., cap
  `kai_start_supply` amount as a fraction of `pm.balance`).

cdpm does **not** expose a `user_extract_kai_yt`-style wrapper-extraction
function. As with Scallop, lending exit is constrained to the normal
redeem → `pm.balance` → `user_remove_liquidity_from_balance` flow: the
caller's PTB is decoupled from cdpm at every mutating Kai call, so cdpm
itself has no stuck state to escape; and a raw `Coin<YT>` outside cdpm is
only useful for redemption back through the same `vault::withdraw` path,
so handing it out would only delete the principal-counter accounting that
protocol-fee math depends on. The mitigation for a hostile Kunalabs
upgrade is opt-out at the scheduler tier (above), not an in-protocol
escape hatch.

### Events (no `by`; sender in tx metadata)
```move
public struct KaiSupplied      { pm_id, coin_type, yt_type, deposit_amount,
                                 yt_minted };
public struct KaiRedeemed      { pm_id, coin_type, yt_type, yt_burned,
                                 redeemed_amount, principal_portion, interest,
                                 fee_amount };
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