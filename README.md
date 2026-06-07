# CDPM - Cetus DLMM Position Manager

contract address: `0x3ad00d82541cfd1fd13568f24b43bf9e36718611533a4853e722438b90ea61f3`  
package only_dep_upgrades: `CmP8QVdyQta1EAQiNpjn9mwkvM56WhzVKjnCVaBh5mWU`

> Shared object IDs (`FeeHouse`, `AccessList`, `AdminCap`, `GlobalRecord`) and the `Record` object type live in each skill's `reference/constants.md` so SDK callers can import them directly. See `skills/cdpm-user-sdk/reference/constants.md` for the canonical list.

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
    owner: address,             // Position owner
    agents: VecSet<address>,    // Authorized agents
    position: Option<Position>, // Cetus DLMM position
    balance: Bag,               // Token balances (String -> Balance<T>)
    fee: Bag,                   // Accumulated fees (String -> Balance<T>)
    lending: Bag,               // Scallop sCoin holdings (String -> ScallopVault<T>)
}

public struct ScallopVault<phantom T> has store {
    scoin: Balance<MarketCoin<T>>,   // Scallop sCoin (type-pinned to MarketCoin<T>)
    principal: u64,                  // Underlying principal supplied (net of redemptions)
}
```

#### FeeHouse
Protocol fee management:
```move
public struct FeeHouse has key {
    id: UID,
    fee_rate: u64,  // Protocol fee rate (0-5000 of 10000, capped at MAX_FEE_RATE = 50%)
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
Two entrypoints exist depending on whether the caller already owns a Cetus
`Position` object.

```move
// (a) Deposit raw coins and open a fresh Cetus position inside a new PM.
public fun user_deposit_liquidity<CoinTypeA, CoinTypeB>(
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

// (b) Wrap an existing Cetus Position (e.g. one previously extracted via
//     user_get_and_return_position) into a fresh PM.
public fun user_deposit_position(
    record: &mut Record,
    position: Position,
    ctx: &mut TxContext,
);
```

#### 2. Add Authorized Agent
```move
// Authorize an AI agent (no Clock parameter)
public fun user_insert_agent(
    pm: &mut PositionManager,
    agent: address,
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

> The fee rate is capped at 50% (`MAX_FEE_RATE = 5000`) via `admin_set_fee`. This bound limits admin authority and cannot be bypassed without redeploying.

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
HWJKADRh...` line near the top of this README). There is no pause switch, no
upgrade path, and no emergency admin override beyond `admin_set_fee` (now
capped at 50%) and `admin_transfer`.

Rationale: users get guaranteed semantics; no admin can silently change
behavior. If Cetus DLMM publishes a breaking upgrade, the response is to
publish a **new** CDPM package, not to mutate this one. Users keep full
control via `user_get_and_return_position` (see D-07) and can migrate
positions manually into the new deployment.

### D-06: `user_close_pm` Drain-Preconditions Surface as cdpm Error Codes
`user_close_pm` validates four drain-preconditions up front so the abort
diagnostic is always a cdpm error code, not an upstream framework abort:

- `EPositionHasRewards` (1007) if any reward type in the underlying Cetus
  `PositionInfo.rewards_owned` vector is non-zero. cdpm reads the vector
  through `pool::position_manager` → `position::borrow_position_info` →
  `position::info_rewards` before calling `pool::close_position`.
- `ELendingNotEmpty` (1004) if `pm.lending` still holds any Scallop /
  Kai vault.
- `EBalanceNotEmpty` (1008) if `pm.balance` is non-empty.
- `EFeeNotEmpty` (1009) if `pm.fee` is non-empty.

**How to close safely**: build a PTB that first
1. calls `user_collect_reward<CoinTypeA, CoinTypeB, R>` once for every
   reward type on the pool (set of `R`s is pool-specific and not known
   statically inside cdpm),
2. redeems every Scallop / Kai vault via `scallop_redeem` / `kai_redeem`,
3. drains `pm.balance` via `user_remove_liquidity_from_balance`,
4. drains `pm.fee` via `user_withdraw_fee`,

then calls `user_close_pm` in the same transaction. The user-sdk skill
documents a helper; see `skills/cdpm-user-sdk/reference/workflows.md`.

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

### D-08: Scallop Lending — Direct-Integration Single-Shot Idle Yield
Idle balances in `pm.balance` (assets outside the active bin range) can be
loaned to Scallop to earn interest. The PM stores Scallop's sCoin
`protocol::reserve::MarketCoin<T>` in a `lending: Bag` keyed by underlying
type:

```move
public struct ScallopVault<phantom T> has store {
    scoin: Balance<MarketCoin<T>>,
    principal: u64,
}
```

**Type-pinned sCoin.** `MarketCoin<T>` has only the `drop` ability and no
public constructor, so the only way to obtain a non-zero
`Balance<MarketCoin<T>>` is through Scallop's own `mint` flow. cdpm
populates `ScallopVault.scoin` exclusively via `mint::mint<T>` called from
inside `scallop_supply` — no PTB-supplied share token ever reaches storage.

**Single-shot API** (post-refactor):

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
    scoin_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);
```

Each operation is a single MoveCall. cdpm itself invokes `mint::mint` /
`redeem::redeem`; the returned share token / underlying flows directly into
PM storage. Both upstream functions call `accrue_interest_for_market` as
their first step, so the exchange rate used is always fresh by construction
— no `EStaleScallopState` freshness guard is needed.

All three managed-tier callers (owner / agent / protocol & no-agents) are
accepted via `assert_caller_authorized`. **Yield interest is treated as
protocol income** — every `scallop_redeem` deducts `fee_rate` (capped at
`MAX_FEE_RATE = 50%`) from the interest portion
(`max(0, redeemed_amount - principal_portion)`); principal returns to
`pm.balance` intact. Departure from D-01 is intentional: lending is a
recurring protocol-managed yield, not self-management.

**PTB templates**:

```
Supply:
  cdpm::scallop_supply<T>(access, pm, version, market, amount, clock)

Redeem:
  cdpm::scallop_redeem<T>(access, pm, fee_house, version, market, scoin_amount, clock)
```

Operational risks:

1. **Liquidity risk** — Scallop is over-collateralized lending. At ≈100%
   utilization, `redeem::redeem` aborts. Off-chain scheduler must reserve a
   non-Scallop buffer for emergency rebalancing.
2. **Version risk** — Scallop bumping `Version` aborts cdpm's `mint`/`redeem`
   call. Resolution path: a cdpm DEP_ONLY upgrade to the new Scallop
   `protocol` dep (cdpm source unchanged).
3. **Whitelist risk** — Scallop checks `tx_context::sender(ctx)`; cdpm is
   the immediate sender from Scallop's perspective. If Scallop disables
   `allow_all`, supply/redeem fails until cdpm's address is whitelisted.
4. **Asset deactivation** — Scallop's `mint` aborts on disabled coin types.
5. **Supply cap** — Scallop enforces a per-asset `supply_limit`; large mints
   may abort.
6. **Gas vs yield** — every redeem call accrues interest first; tiny
   positions can be net-negative.
7. **Scallop package re-deploy** — if Scallop ever publishes a NEW package
   with a new `MarketCoin<T>` type identity, cdpm's bytecode references the
   OLD `MarketCoin<T>` and cannot accept the new sCoin type. Resolution:
   a fresh cdpm deploy is required to track the new `MarketCoin<T>`.

**Trust boundary.** The security ceiling of cdpm's Scallop integration is
**the integrity of the Scallop team and their custody of the
`ScallopProtocol` package upgrade-cap + `AdminCap`**. A backdoored
`protocol::reserve` upgrade can drain underlying `Balance<T>` out of every
existing `Reserve` shared object. cdpm inherits exactly the same
Scallop-trust assumption every other Scallop consumer takes — no more, no
less.

**No escape hatch for lending.** cdpm exposes no owner-only function that
hands raw `Coin<MarketCoin<T>>` back to the user. The only exit is the
normal `scallop_redeem` → `pm.balance` → `user_remove_liquidity_from_balance`
flow, which preserves the principal-counter accounting that protocol-fee
math depends on. User mitigations are purely off-chain (don't supply if you
don't trust Scallop; bound per-PM exposure via the scheduler).

`user_close_pm` asserts `lending` is empty (`ELendingNotEmpty = 1004`).
Callers must redeem every vault before closing the PM.

### D-09: Kai SAV Lending — Direct-Integration Single-Shot Yield
A second yield destination alongside Scallop. Targets Kai's
**Single-Asset Vault (SAV)** layer — `kai_sav::vault` — with the
production-only `kai_leverage_supply_pool` strategy module. cdpm calls
the full chain (`vault::deposit` for supply; `vault::withdraw` →
`klsp::withdraw` → `vault::redeem_withdraw_ticket` for redeem) inline.

```move
public struct KaiVault<phantom T, phantom YT> has store {
    yt_balance: Balance<YT>,
    principal: u64,
}
```

Stored in the same `lending: Bag` as `ScallopVault`. Bag key is **YT's**
`type_name` (not T's), so a single underlying `T` can simultaneously have a
Scallop vault (key = `T`) and a Kai vault (key = `YT`) without collision.

**Type-pin defense**: `lp_treasury: TreasuryCap<YT>` lives inside Kai's
`Vault<T, YT>` and only `kai_sav::vault` itself can mint `YT` balances.
Combined with `kai_sav::vault::new` being `public(package)`
(`vault.move:235`), no external code can publish a fake `Vault<USDC, EvilYT>`
and forge `Coin<EvilYT>` of attacker-chosen value — cdpm does not need an
admin-curated vault registry.

**Public surface**:
```move
public fun kai_supply<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &mut kai_sav::vault::Vault<T, YT>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun kai_redeem<T, ST, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    vault: &mut kai_sav::vault::Vault<T, YT>,
    strategy: &mut klsp::Strategy<T, ST>,
    supply_pool: &mut SupplyPool<T, ST>,
    yt_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);
```

**PTB templates**:
```
Supply:
  cdpm::kai_supply<T, YT>(access, pm, vault, amount, clock)

Redeem:
  cdpm::kai_redeem<T, ST, YT>(
      access, pm, fee_house, vault, strategy, supply_pool, yt_amount, clock)
```

The full Kai withdrawal chain runs inside `kai_redeem` atomically.
`vault.withdraw_ticket_issued` flips to `true` at the first step and back to
`false` at the third, all within one Move function; no intermediate state
ever escapes the call.

Yield fee semantics match Scallop (`MAX_FEE_RATE = 50%`, charged on
`max(0, redeemed - principal_portion)`).

Operational caveats:
- **Bootstrap (`yt_supply == 0`)**: Kai's `vault::deposit` returns YT at
  the bootstrap 1:1 rate. cdpm records the actual returned `yt_balance`
  as principal accumulation; no `EZeroExpected` guard exists.
- **Strategy losses** (`StrategyLossEvent` in `vault::redeem_withdraw_ticket`):
  when the strategy returns less than requested, cdpm consumes the smaller
  amount. The fee formula yields `interest = 0` for any redeem where the
  loss eats into principal — the user is not double-taxed. The user
  receives `redeemed - 0 = redeemed` into `pm.balance`.
- **Admin pause / TVL cap / rate limiter**: caller PTB aborts at the live
  `vault::*` / `klsp::*` call. cdpm unaffected; `pm.lending` intact,
  awaiting unpause.
- **New Kai strategy module**: if Kai future-deploys a vault using a
  different strategy module, `kai_redeem` on that vault aborts at PTB
  construction or strategy::withdraw execution. Resolution: a new cdpm
  release that adds a parallel `kai_redeem_via_<newmodule>` entry.

**Trust boundary.** Identical shape to Scallop's: integrity of Kunalabs
and their custody of the `kai_sav` / `kai_leverage` upgrade-caps. No
admin-curated YT whitelist; the type-system suffices.

**No escape hatch** for Kai lending either — same as Scallop. Only exit is
`kai_redeem` → `pm.balance` → `user_remove_liquidity_from_balance`.

## Security Features

### 1. Permission Separation
- Clear boundaries between owner, agent, protocol, and admin roles
- Agent-limited operations (cannot withdraw funds)
- Protocol access controlled by admin-managed allow list

### 2. Input Validation
- Fee rate bounds checking (0-50%, `MAX_FEE_RATE = 5000`)
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
│   └── cdpm.move          # Main contract
├── tests/
│   └── cdpm_tests.move    # Test suite (to be implemented)
├── Move.toml              # Package configuration
└── Move.lock             # Dependency lock
```

### Dependencies
- **CetusDlmm**: Cetus DLMM interface (patched mainnet-v0.9.0 — see `Move.toml`)
- **IntegerMate**: Integer utilities (mainnet-v1.3.0)
- **MoveSTL**: Move standard template library (mainnet-v1.3.0)
- **ScallopProtocol** / **X**: Scallop lending protocol (local sibling checkout — see `Move.toml`)
- **kai_sav**: Kai Single-Asset Vault (patched local sibling — see `Move.toml`)

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

## License

This project is licensed under the terms of the original repository.

## Contributing

1. Review the design notes (D-01 through D-11) in [DESIGN.md](DESIGN.md) before changing protocol behavior
2. Ensure comprehensive testing for all changes
3. Maintain backward compatibility where possible

## Support

For issues, questions, or security concerns:
1. Review documentation
2. Check existing issues
3. Contact maintainers through appropriate channels

---

*Last Updated: 2026-02-28*
*Contract Version: As deployed*
*Documentation Version: 1.0*