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
- **Lending**: Scallop sCoin `MarketCoin<T>` (or Kai SAV YT) wrapped per underlying type along with cumulative principal; populated by `scallop_supply` (Kai: `kai_supply`), drained **exclusively** by `scallop_redeem` (Kai: `kai_redeem`). The wrapper type is pinned by Move's type system, blocking fake-wrapper attacks. There is **no escape hatch** for lending: the only way to exit a lending position is to redeem through the upstream protocol's normal path, which lands the underlying in `pm.balance`; the user then withdraws via `user_remove_liquidity_from_balance`.

### 2. FeeHouse
Global protocol fee management structure.

```move
public struct FeeHouse has key {
    id: UID,
    fee_rate: u64,  // Protocol fee rate (0-10000), capped at MAX_FEE_RATE = 5000 (50%)
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
- Set protocol fee rate (0-50%; capped at `MAX_FEE_RATE = 5000` / `FEE_DENOMINATOR = 10000`)
- Collect accumulated protocol fees
- Manage AccessList (add/remove protocol addresses)
- Transfer admin capability
- Force-return raw stored assets to `pm.owner` (emergency escape hatch — see §Upgrade Considerations)

**Functions:** All `admin_*` functions

### Permission Matrix
| Operation | Owner | Agent | Protocol | Admin |
|-----------|-------|-------|----------|-------|
| Create Position | ✓ | ✗ | ✗ | ✗ |
| Add/Remove Liquidity | ✓ | ✓ | ✓* | ✗ |
| Collect Fees/Rewards | ✓ | ✓† | ✓* | ✗ |
| Withdraw Funds | ✓ | ✗ | ✗ | ✓§ |
| Manage Agents | ✓ | ✗ | ✗ | ✗ |
| Set Fee Rate | ✗ | ✗ | ✗ | ✓ |
| Collect Protocol Fees | ✗ | ✗ | ✗ | ✓ |

*With protocol fee deduction
†To fee bag only
‡Without fee collection
§Emergency escape hatch only — returned to `pm.owner`, never the admin

### Permission Boundaries — Operational Notes

These are intentional design choices. Front-ends and SDKs MUST surface them:

1. **Agents may auto-compound fees.** `agent_transfer_fee_to_balance<T>` lets an authorized agent migrate accumulated `fee` bag entries into `balance`, where they can be redeployed as liquidity by `agent_add_liquidity`. Owners who want fees to settle into a withdraw-only bucket should NOT keep an agent authorized while fees accrue. Funds never leave the PositionManager — only the bucket changes — but the agent does effectively control reinvestment of realized fees.

2. **`user_close_pm` requires zero pending pool rewards (and empty bags).** Caller responsibility: invoke `user_collect_reward<CoinTypeA, CoinTypeB, R>` for **every** reward type the underlying pool emits, in the same PTB or earlier transactions, before calling `user_close_pm`. SDKs should query the pool's reward types and emit the matching collect calls automatically. cdpm reads the Cetus `PositionInfo.rewards_owned` vector via `pool::position_manager` → `position::borrow_position_info` → `position::info_rewards` and aborts with `EPositionHasRewards` (1007) if any entry is non-zero — so the abort surfaces as a cdpm error code rather than Cetus's `EPositionRewardNotZero`. The same up-front check applies to `pm.lending` (`ELendingNotEmpty`, 1004), `pm.balance` (`EBalanceNotEmpty`, 1008), and `pm.fee` (`EFeeNotEmpty`, 1009) — owners must drain all three bags before close.

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
- **Maximum Fee Rate:** `MAX_FEE_RATE = 5000`/10000 = 50% (enforced by `admin_set_fee`)
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
   - Supply / redeem idle balance to Scallop (scallop_supply / scallop_redeem)
   - Supply / redeem idle balance to Kai SAV (kai_supply / kai_redeem)

3. Closure
   user_close_pm() → PositionManagerClosed
   Preconditions (cdpm-named asserts up front):
     - lending bag empty (ELendingNotEmpty, 1004)
     - balance bag empty (EBalanceNotEmpty, 1008)
     - fee bag empty (EFeeNotEmpty, 1009)
     - Cetus PositionInfo.rewards_owned all zero (EPositionHasRewards, 1007)
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
1. **CetusDlmm**: Patched mainnet-v0.9.0 (local path; one missing
   `use sui::vec_map;` import added inside a `#[test_only]` helper at
   `partner.move:193` to unblock `sui move test`. Production bytecode is
   identical to upstream `mainnet-v0.9.0`. See `Move.toml` for the
   patched path.)
   - `pool::` module for liquidity operations
   - `position::Position` structure + `position::borrow_position_info` /
     `position::info_rewards` for the in-contract reward-residual check
     used by `user_close_pm`
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
const ENotOwner: u64           = 1001;  // caller is not pm.owner
const ENotAllow: u64           = 1002;  // caller not in agents / access list (or invariant broken)
const EInvalidFeeRate: u64     = 1003;  // admin_set_fee given rate > MAX_FEE_RATE (50%)
const ELendingNotEmpty: u64    = 1004;  // user_close_pm called with non-empty lending Bag
const ENoSuchVault: u64        = 1005;  // pull_from_*_lending called for an absent vault entry
const ENoSuchBalance: u64      = 1006;  // withdraw_from_balance / withdraw_from_fee for an absent type
const EPositionHasRewards: u64 = 1007;  // user_close_pm called with unclaimed Cetus pool rewards
const EBalanceNotEmpty: u64    = 1008;  // user_close_pm called with non-empty balance Bag
const EFeeNotEmpty: u64        = 1009;  // user_close_pm called with non-empty fee Bag
```

`user_close_pm` validates all four drain-preconditions up front (lending /
balance / fee bags empty, and zero pool-reward residuals) so the abort
diagnostic is always a cdpm error code, not the framework's generic
`EBagNotEmpty` or Cetus's `EPositionRewardNotZero`. Callers must:

1. Collect every reward type on the underlying Cetus pool via
   `user_collect_reward<CoinTypeA, CoinTypeB, R>` for each `R` the pool emits.
2. Redeem every lending position (Scallop / Kai) via the respective
   `*_redeem` so `pm.lending` is empty.
3. Withdraw any residual `pm.balance` via `user_remove_liquidity_from_balance`.
4. Withdraw any residual `pm.fee` via `user_withdraw_fee`.

Then `user_close_pm` succeeds and the underlying Cetus position is closed
inside the same call.

### Error Code Categorization (Aspirational)

The current `1001`–`1009` range mixes permission, state, and parameter
faults. A future redeploy could renumber as:
- **1000-1999**: Permission errors
- **2000-2999**: Parameter validation errors
- **3000-3999**: State-related errors
- **4000-4999**: External dependency errors

Not pursued in the current DEP_ONLY package — any renumbering would
require a fresh deploy.

## Security Considerations

### Contract Invariants
1. **Fee Rate Bound**: `0 <= fee_rate <= MAX_FEE_RATE` (5000 / 10000 = 50%); enforced by `admin_set_fee`
2. **Balance Non-Negative**: All token balances are non-negative
3. **Permission Hierarchy**: Strict separation between permission tiers
4. **Agent Restriction**: Agents cannot withdraw user funds
5. **Protocol Check**: Protocol operations require no active agents

### Upgrade Considerations

The current deployment uses the irreversible `UpgradePolicy::DEP_ONLY (192)`
and the publisher retains the restricted UpgradeCap (see `publish.md`). This
means:

1. **Bytecode locked** — the published `cdpm.move` implementation cannot be
   changed.
2. **Dependency upgrades allowed** — a follow-up `sui client upgrade` with
   the same source but a newer `cetusdlmm` / `protocol` / `kai_sav` /
   `kai_leverage` version is accepted. Use case: Scallop bumps its
   `Version`, or Cetus DLMM ships a non-breaking SDK update — neither
   requires touching cdpm source.
3. **Position migration**: still supported via `user_get_position` /
   `user_get_and_return_position` for the rare case where an upstream
   protocol publishes a breaking new package and dep-only upgrade is
   insufficient (a fresh cdpm deploy is then needed).
4. **Admin emergency return (asset evacuation)** — the `admin_force_return_*`
   / `admin_force_close_pm` escape hatch lets the `AdminCap` holder force raw
   stored assets (balance, fee, raw `Position`, raw sCoin / YT) out of any PM
   and back to `pm.owner` when a dependency ships a breaking upgrade. It can
   only "un-stick" funds, never steal them (recipient is hard-coded to
   `pm.owner`). There is no pause function.

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

The PM proxies idle balances into the Scallop lending market with **direct
calls** to Scallop's public API. cdpm itself invokes `protocol::mint::mint`
and `protocol::redeem::redeem`, threading Scallop's `Version` shared object
through as a parameter. The asset returned from each call flows directly
into PM storage; no PTB-supplied `Coin<*>` ever enters cdpm.

### Public surface
```move
public fun scallop_supply<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    version: &ScallopVersion,
    market: &mut Market,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun scallop_redeem<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    version: &ScallopVersion,
    market: &mut Market,
    scoin_amount: u64,     // u64::MAX redeems the entire vault
    clock: &Clock,
    ctx: &mut TxContext,
);
```

Each function takes the asset amount to operate on, withdraws it from /
deposits it to PM internally, and emits `ScallopSupplied` /
`ScallopRedeemed`.

### Imports
```move
use protocol::market::Market;
use protocol::reserve::MarketCoin;
use protocol::version::Version as ScallopVersion;
use protocol::mint;
use protocol::redeem;
```

`MarketCoin<T>` is imported because `ScallopVault.scoin:
Balance<MarketCoin<T>>` uses it as a type pin.

### Caller authorization
`scallop_supply` and `scallop_redeem` each call `assert_caller_authorized`
at entry. The three managed-tier callers (owner / agent / (protocol & no
agents)) are accepted. The owner-only exit path remains
`scallop_redeem` → `pm.balance` → `user_remove_liquidity_from_balance`; the
admin emergency path is `admin_force_return_scallop<T>` (redeems to underlying
`Coin<T>` to `pm.owner`, same interest-only fee as `scallop_redeem` — see
§Upgrade Considerations).

### Freshness
`protocol::mint::mint` and `protocol::redeem::redeem` both call
`accrue_interest_for_market` as their first step (Scallop's
`accrue_interest.move`). Under direct-call cdpm, the exchange rate
Scallop uses for cdpm's `mint`/`redeem` is the live post-accrual rate
by definition — no PTB-level race window exists, no freshness guard
needed.

### Yield fee model (unchanged)
Every `scallop_redeem` call deducts `fee_rate` on the **interest portion**.
Principal is amortized linearly when partial-redeeming:

```
principal_portion = ScallopVault.principal × redeem_scoin_amount / total_scoin
interest          = max(0, redeemed_underlying - principal_portion)
fee_amount        = interest × FeeHouse.fee_rate / FEE_DENOMINATOR
```

When `redeemed_underlying ≤ principal_portion` (socialized loss), `fee_amount
= 0`. The user receives `redeemed_underlying - fee_amount` into `pm.balance`.

#### F-04: rounding-floor fee evasion (documented residual risk)
`fee_amount = floor(interest × fee_rate / 10_000)` rounds down. A redeem
where `interest × fee_rate < 10_000` produces `fee_amount = 0`. At
`fee_rate = 2000` (default 20%) this means slices with `interest < 5`
underlying units. Sui's reference gas per move-call exceeds the evaded
value by 4–5 orders of magnitude, so the break-even is unfavorable to
the attacker. Recorded as accepted residual risk; no structural defense
warranted.

### PTB templates
**Supply**
```
PTB[0] cdpm::scallop_supply<T>(access, pm, version, market, amount, clock)
```

**Redeem**
```
PTB[0] cdpm::scallop_redeem<T>(access, pm, fee_house, version, market, scoin_amount, clock)
```

Each lending operation is now a single MoveCall. No external `mint::mint` /
`redeem::redeem` step appears in the caller's PTB — cdpm handles it inline.

### Lifecycle invariants
- `user_close_pm` aborts with `ELendingNotEmpty` (1004) if `pm.lending`
  still holds any vault; with `EBalanceNotEmpty` (1008) if `pm.balance`
  is non-empty; with `EFeeNotEmpty` (1009) if `pm.fee` is non-empty;
  and with `EPositionHasRewards` (1007) if the underlying Cetus position
  has any unclaimed reward type. Callers must redeem all lending, drain
  balance + fee bags, and collect all pool rewards first.
- Re-entry of underlying must go through `Coin<T>` → `pm.balance` via
  `user_add_liquidity_to_balance`. No `user_inject_market_coin` exists.
- **The sCoin type is fixed to `MarketCoin<T>`** for any given underlying.
  `ScallopVault<phantom T> { scoin: Balance<MarketCoin<T>> }`. Migration to a
  different Scallop sCoin type identity (Scallop publishes a fresh package
  with new `MarketCoin<T>` definition) requires either a dep-only upgrade
  to the new Scallop or a cdpm redeploy.

### Trust boundary

The security ceiling of cdpm's Scallop integration is **the integrity of
the Scallop team and their custody of the `ScallopProtocol` package
upgrade-cap + `app::AdminCap`**. A backdoored `protocol::reserve` upgrade
can drain the underlying `Balance<T>` out of every existing `Reserve`
shared object. cdpm inherits exactly the same Scallop-trust assumption
every other Scallop consumer takes — no more, no less.

The cdpm DEP_ONLY policy adds a *new* trust assumption: the holder of cdpm's
UpgradeCap can upgrade cdpm's dependency set. The cap should be transferred
to a multisig (see `publish.md`) so dep upgrades require collective action.

User mitigations:
- **Don't trust Scallop? Don't supply.** Choose an agent / protocol bot
  whose off-chain scheduler does NOT call `scallop_supply`. Scallop
  integration is opt-in per-strategy.
- **Bound per-PM Scallop exposure** via the off-chain scheduler.

### Admin escape hatch for lending (D-12)
The *owner*-only exit for lending remains the normal `scallop_redeem` →
`pm.balance` → `user_remove_liquidity_from_balance` flow, which preserves the
principal-counter accounting that protocol-fee math depends on. The *admin*
emergency path is `admin_force_return_scallop<T>` — it redeems the vault to
the underlying `Coin<T>` via `redeem::redeem` (charging the same interest-only
protocol fee as `scallop_redeem`) and returns it to `pm.owner`, for the
"upgrade incompatible" scenario. The Cetus `Position`
likewise has an admin emergency exit: `admin_force_return_position` returns
the raw `Position` object to `pm.owner` (see §Upgrade Considerations).

### Events (no `by` field; tx metadata records the sender)
```move
public struct ScallopSupplied   { pm_id, coin_type, deposit_amount,
                                  market_coin_minted };
public struct ScallopRedeemed   { pm_id, coin_type, market_coin_redeemed,
                                  redeemed_amount, principal_portion, interest,
                                  fee_amount };
```

## Kai SAV Lending Integration (D-10 / D-11)

The PM proxies idle balances into Kai's **Single-Asset Vault (SAV)**, a
multi-strategy yield optimizer maintained by Kunalabs. cdpm calls Kai
directly with the same direct-integration shape used for Scallop. The
production Kai SAV stack uses `kai_leverage_supply_pool` as the single
strategy module on every vault (`Vault<SUI,YSUI>`, `Vault<USDC,YUSDC>`,
etc.), and that module's `withdraw<T, ST, YT>` function is generic — so
cdpm covers the full set of supported vaults with one generic redeem
function.

### Architecture
- Storage: `lending: Bag` (shared with Scallop) keyed by **YT's** `type_name`
  (Bag entry value is `KaiVault<phantom T, phantom YT>`). Same T can hold a
  Scallop vault (key=T) and a Kai vault (key=YT) simultaneously.
- API: `kai_supply<T, YT>` + `kai_redeem<T, ST, YT>`. The entire
  `vault::withdraw → klsp::withdraw → vault::redeem_withdraw_ticket`
  chain runs inside `kai_redeem`.
- Fee model: identical to Scallop. `MAX_FEE_RATE = 5000` cap shared.

### Public surface
```move
public fun kai_supply<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &mut kai_vault::Vault<T, YT>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun kai_redeem<T, ST, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    vault: &mut kai_vault::Vault<T, YT>,
    strategy: &mut klsp::Strategy<T, ST>,
    supply_pool: &mut SupplyPool<T, ST>,
    yt_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);
```

### Imports
```move
use kai_sav::vault as kai_vault;
use kai_sav::kai_leverage_supply_pool as klsp;
use kai_leverage::supply_pool::SupplyPool;
```

### Why klsp-only
cdpm hardcodes `kai_leverage_supply_pool::withdraw` as the strategy
withdrawal call. This matches the production deployment shape (verified
against on-chain PTBs as of 2026-06): every Kai SAV under management uses
`Strategy<T, ST>` from `kai_leverage_supply_pool`, pulling from a
`SupplyPool<T, ST>`. Earlier per-vault strategy modules
(`scallop_sui`, `scallop_whusdce`, `scallop_*_proper`) are not supported
through cdpm's Kai path. Users who want direct Scallop exposure use
`scallop_supply` / `scallop_redeem` instead — that's the entire point of
having both integrations.

### Type-pin defense
`Coin<YT>` cannot be forged externally:
1. `lp_treasury: TreasuryCap<YT>` is held inside Kai's `Vault<T, YT>` — only
   `kai_sav::vault` mints/burns YT balances.
2. `kai_sav::vault::new<T, YT>` is `public(package)` (vault.move:235) — no
   external code can publish a `Vault<T, EvilYT>` shared object.

`Strategy<T, ST>` / `SupplyPool<T, ST>` likewise can only be created by
their owning packages. cdpm does not need an admin-curated registry; the
type system suffices.

### PTB templates

**Supply** (1 step):
```
PTB[0] cdpm::kai_supply<T, YT>(access, pm, vault, amount, clock)
```

**Redeem** (1 step):
```
PTB[0] cdpm::kai_redeem<T, ST, YT>(
            access, pm, fee_house, vault, strategy, supply_pool,
            yt_amount, clock)
```

The full Kai withdrawal chain — `vault::withdraw` → `klsp::withdraw` →
`vault::redeem_withdraw_ticket` — runs inside `kai_redeem` atomically.
`vault.withdraw_ticket_issued` flips to `true` at the first step and
back to `false` at the third, all within one Move function; no
intermediate state ever escapes the call.

### Operational risks

1. **Bootstrap (`yt_supply == 0`)**: Kai's `vault::deposit` returns
   YT at the bootstrap rate when `total_available_balance == 0`. cdpm's
   `kai_supply` faithfully records the actual returned `yt_balance.value()`
   as principal accumulation; no `EZeroExpected` guard exists anymore.
2. **Strategy losses** (`StrategyLossEvent` in
   `vault::redeem_withdraw_ticket`): when strategy `out` is less than the
   requested `to_withdraw`, cdpm's `kai_redeem` consumes the smaller
   amount. The fee formula `interest = max(0, redeemed - principal_portion)`
   yields `interest = 0` for any redeem where the strategy loss eats into
   principal, so the user is not double-taxed on a principal shortfall.
   The user receives `redeemed - fee = redeemed - 0 = redeemed` into
   `pm.balance` — i.e., the loss flows through to the user but no fee is
   charged. **Behavioral note**: pre-refactor cdpm reverted on strategy
   loss; post-refactor it absorbs. This is a deliberate trade-off — the
   redeem still completes (releasing `pm.lending` capacity) instead of
   stranding the position.
3. **Admin pause / TVL cap / rate limiter**: caller PTB aborts at the
   live `vault::*` / `klsp::*` call. cdpm unaffected; `pm.lending`
   intact, awaiting unpause.
4. **New Kai strategy module**: if Kai future-deploys a vault using a
   different strategy module (not `kai_leverage_supply_pool`), `kai_redeem`
   on that vault aborts (`Strategy<T, ST>` type mismatch caught at PTB
   construction or `klsp::withdraw` execution). Resolution: a new cdpm
   release that adds a parallel `kai_redeem_via_<newmodule>` entry. The
   existing positions in old-strategy vaults continue to redeem normally.

### Trust boundary

Identical to Scallop's: integrity of Kunalabs and their custody of the
`kai_sav` / `kai_leverage` upgrade-caps. cdpm intentionally does not
maintain a YT whitelist — external fake-Vault is structurally impossible,
and a Kunalabs-issued malicious upgrade would just backdoor the
whitelisted vault. The mitigation surface remains agent selection.

### Events (no `by`; sender in tx metadata)
```move
public struct KaiSupplied      { pm_id, coin_type, yt_type, deposit_amount,
                                 yt_minted };
public struct KaiRedeemed      { pm_id, coin_type, yt_type, yt_burned,
                                 redeemed_amount, principal_portion, interest,
                                 fee_amount };
```

## D-11: Scallop unification across cdpm and Kai

cdpm and Kai both depend on Scallop's `protocol` package. The patched Kai
source (`kai-contracts/kai/sav/core-prover-patched/Move.toml`) points its
`protocol` dep at `../../../../sui-lending-protocol/contracts/protocol` —
the same path cdpm uses. `sui move build` resolves a single `protocol`
package; the on-chain deployment has a single Scallop `Version` shared
object that both cdpm and Kai reference.

`spool` remains at its `_vendor/Scallop/spool-v2` location because the
standalone Scallop tree does not include a `spool` sub-package. Kai's
strategy modules (`scallop_sui`, `scallop_whusdce`) module-level `use
spool::*` so the dep must resolve for build, but cdpm's runtime call
path (which only uses `kai_leverage_supply_pool`) never touches spool
code.

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
