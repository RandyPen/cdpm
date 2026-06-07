# CDPM API Reference

## Overview

This document is the canonical reference for the public functions in
`sources/cdpm.move`. It is kept in lock-step with that file; if anything
here disagrees with the source, the source wins.

## Permission Levels

| Level | Identifier | Key Functions |
|-------|------------|---------------|
| **Owner** | `pm.owner == ctx.sender()` | `user_*` functions |
| **Agent** | `vec_set::contains(&pm.agents, &ctx.sender())` | `agent_*` functions |
| **Protocol** | `vec_set::contains(&access.allow, &ctx.sender())` AND `vec_set::is_empty(&pm.agents)` | `protocol_*` functions |
| **Admin** | Holds `AdminCap` | `admin_*` functions |
| **Managed (owner ∨ agent ∨ protocol-and-no-agents)** | `assert_caller_authorized` | `scallop_*` / `kai_*` lending entries |

## Error Codes

| Code | Constant | Meaning |
|------|----------|---------|
| 1001 | `ENotOwner` | Caller is not `pm.owner` |
| 1002 | `ENotAllow` | Caller not in agents / access list (or invariant broken) |
| 1003 | `EInvalidFeeRate` | `admin_set_fee` given rate > `MAX_FEE_RATE` (5000 / 50%) |
| 1004 | `ELendingNotEmpty` | `user_close_pm` called with non-empty `lending` Bag |
| 1005 | `ENoSuchVault` | `pull_from_*_lending` called for an absent vault entry |
| 1006 | `ENoSuchBalance` | `withdraw_from_balance` / `withdraw_from_fee` for an absent type |
| 1007 | `EPositionHasRewards` | `user_close_pm` called with unclaimed Cetus pool rewards |
| 1008 | `EBalanceNotEmpty` | `user_close_pm` called with non-empty `balance` Bag |
| 1009 | `EFeeNotEmpty` | `user_close_pm` called with non-empty `fee` Bag |

---

## Record Management (any user)

### `register_and_return_record`
Creates a per-user `Record` tracking PM IDs the caller owns. Aborts if the
sender already has a Record registered (`table::add` duplicate-key abort).

```move
public fun register_and_return_record(
    global_record: &mut GlobalRecord,
    ctx: &mut TxContext,
): Record;
```
Emits `RecordCreated`.

### `transfer_record`
Sends the Record back to `ctx.sender()`. Typical pattern: call
`register_and_return_record` then `transfer_record` in the same PTB.

```move
public fun transfer_record(record: Record, ctx: &TxContext);
```

### `unregister_record`
Destroys the caller's Record. Requires the Record's internal table to be
empty (close every PM first).

```move
public fun unregister_record(
    global_record: &mut GlobalRecord,
    record: Record,
    ctx: &TxContext,
);
```
Emits `RecordDeleted`.

---

## User Functions (owner-only)

### `user_deposit_liquidity`
Creates a PositionManager and opens a fresh Cetus position with bins.

```move
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
```
Emits `PositionManagerCreated`.

### `user_deposit_position`
Wraps an existing Cetus `Position` (e.g. produced by a previous extract)
into a new PM.

```move
public fun user_deposit_position(
    record: &mut Record,
    position: Position,
    ctx: &mut TxContext,
);
```
Emits `PositionManagerCreated`.

### `user_get_and_return_position` / `user_get_position`
Owner-only escape hatch for Cetus DLMM upgrades. Extracts the underlying
`Position` out of the PM (`pm.position` becomes `None`). The PM shell can
then be closed via `user_close_pm` (no position branch); a re-injection
flow uses a fresh PM via `user_deposit_position`.

```move
public fun user_get_and_return_position(
    pm: &mut PositionManager,
    ctx: &TxContext,
): Position;

public fun user_get_position(pm: &mut PositionManager, ctx: &TxContext);
```
Emits `PositionExtract`.

### `user_add_liquidity_to_position`
Adds liquidity from the caller's `Coin<CoinTypeA>` / `Coin<CoinTypeB>` into
the underlying Cetus position. Unused coin is returned to the caller's
balances (the `&mut Coin` is split internally).

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
);
```
Emits `LiquidityAdded`.

### `user_add_liquidity_to_balance`
Deposits a `Coin<T>` into `pm.balance` (for later use by `agent_/protocol_`
liquidity ops or lending supply).

```move
public fun user_add_liquidity_to_balance<T>(
    pm: &mut PositionManager,
    coin: Coin<T>,
    ctx: &TxContext,
);
```
Emits `BalanceDeposited`.

### `user_remove_liquidity_from_position`
Removes liquidity from the underlying Cetus position. Returns the released
coins directly to the caller.

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
): (Coin<CoinTypeA>, Coin<CoinTypeB>);
```
Emits `LiquidityRemoved`.

### `user_collect_fee`
Collects accumulated DLMM trading fees from the position; no protocol cut
(self-management path). Returns fee coins to the caller.

```move
public fun user_collect_fee<CoinTypeA, CoinTypeB>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
): (Coin<CoinTypeA>, Coin<CoinTypeB>);
```
Emits `FeeCollected`.

### `user_collect_reward`
Collects one incentive-reward type from the position; no protocol cut.

```move
public fun user_collect_reward<CoinTypeA, CoinTypeB, RewardType>(
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
): Coin<RewardType>;
```
Emits `RewardCollected`.

### `user_remove_liquidity_from_balance`
Withdraws from `pm.balance`. `amount == 0` short-circuits to
`coin::zero<T>(ctx)` without touching the bag. `amount > 0` of an absent
type aborts with `ENoSuchBalance`.

```move
public fun user_remove_liquidity_from_balance<T>(
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T>;
```
Emits `BalanceWithdrawn`.

### `user_withdraw_fee`
Same as above, against `pm.fee`.

```move
public fun user_withdraw_fee<T>(
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T>;
```
Emits `UserFeeWithdrawn`.

### `user_insert_agent` / `user_remove_agent`
Manage the PM's agent allow-list.

```move
public fun user_insert_agent(pm: &mut PositionManager, agent: address, ctx: &TxContext);
public fun user_remove_agent(pm: &mut PositionManager, agent: address, ctx: &TxContext);
```
Emit `AgentAdded` / `AgentRemoved`.

### `user_close_pm`
Closes the PM. Aborts up front (cdpm error codes, not framework strings)
if any of:
- `pm.balance` non-empty (`EBalanceNotEmpty`, 1008)
- `pm.fee` non-empty (`EFeeNotEmpty`, 1009)
- `pm.lending` non-empty (`ELendingNotEmpty`, 1004)
- Cetus `PositionInfo.rewards_owned` has any non-zero entry (`EPositionHasRewards`, 1007)

```move
public fun user_close_pm<CoinTypeA, CoinTypeB>(
    record: &mut Record,
    pm: PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
);
```
Emits `PositionManagerClosed`.

---

## Protocol Functions (AccessList & no-agents)

Each function requires `vec_set::contains(&access.allow, &sender)` AND
`vec_set::is_empty(&pm.agents)`.

### `protocol_add_liquidity`
Withdraws from `pm.balance`, adds liquidity to the position, returns
unused balances back to `pm.balance`.

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
);
```
Emits `ProtocolLiquidityAdded`.

### `protocol_remove_liquidity`
Removes liquidity from the position into `pm.balance`.

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
);
```
Emits `ProtocolLiquidityRemoved`.

### `protocol_collect_fee`
Collects DLMM trading fees, takes the protocol cut into `fee_house`, puts
the rest into `pm.fee`.

```move
public fun protocol_collect_fee<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    fee_house: &mut FeeHouse,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
);
```
Emits `ProtocolFeeCollected`.

### `protocol_collect_reward`
Same shape, for one reward type.

```move
public fun protocol_collect_reward<CoinTypeA, CoinTypeB, RewardType>(
    access: &AccessList,
    fee_house: &mut FeeHouse,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
);
```
Emits `ProtocolRewardCollected`.

### `protocol_transfer_fee_to_balance`
Moves `pm.fee` entries into `pm.balance` so they can be redeployed as
liquidity. No external transfer.

```move
public fun protocol_transfer_fee_to_balance<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
);
```
Emits `FeeTransferredToBalance`.

---

## Agent Functions (`pm.agents` allow-list)

Mirror of `protocol_*` minus the protocol-fee cut. Functionally same set
of operations; income lands in `pm.fee` directly without the AccessList
check.

| Function | Event |
|----------|-------|
| `agent_add_liquidity` | `AgentLiquidityAdded` |
| `agent_remove_liquidity` | `AgentLiquidityRemoved` |
| `agent_collect_fee` | `AgentFeeCollected` |
| `agent_collect_reward` | `AgentRewardCollected` |
| `agent_transfer_fee_to_balance` | `FeeTransferredToBalance` |

Signatures match the corresponding `protocol_*` shape minus
`access: &AccessList`. See `sources/cdpm.move:957-1107`.

---

## Lending Functions (managed-tier — owner ∨ agent ∨ protocol-and-no-agents)

All four entries gate via `assert_caller_authorized(access, pm, ctx)`.
Income from Scallop / Kai redeems lands in `pm.balance` (not `pm.fee`);
the interest-only protocol cut is taken inline against `fee_house`.

### `scallop_supply`
Withdraws `Coin<T>` from `pm.balance`, calls `mint::mint<T>` inline,
stores the returned `Balance<MarketCoin<T>>` into a typed `ScallopVault<T>`
inside `pm.lending`. Principal counter accumulates by `coin.value()`.

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
```
Emits `ScallopSupplied`.

### `scallop_redeem`
Pulls `scoin_amount` of share tokens (or `u64::MAX` for full vault),
calls `redeem::redeem<T>` inline, charges `fee_rate` on
`max(0, redeemed - principal_portion)`, returns the rest to `pm.balance`.

```move
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
Emits `ScallopRedeemed`.

### `kai_supply`
Withdraws `Coin<T>` from `pm.balance`, calls `kai_vault::deposit<T, YT>`
inline, stores the returned `Balance<YT>` into a typed `KaiVault<T, YT>`
inside `pm.lending`.

```move
public fun kai_supply<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &mut kai_sav::vault::Vault<T, YT>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);
```
Emits `KaiSupplied`.

### `kai_redeem`
Single-shot wrapper around the three-step Kai withdraw chain
(`vault::withdraw` → `klsp::withdraw` → `vault::redeem_withdraw_ticket`).
Hardcoded to the `kai_leverage_supply_pool` strategy module — see
DESIGN.md for the "why klsp-only" rationale.

```move
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
Emits `KaiRedeemed`.

---

## Admin Functions (`AdminCap` capability)

### `admin_transfer`
Hands the `AdminCap` to another address.
```move
public fun admin_transfer(admin_cap: AdminCap, to: address, ctx: &TxContext);
```
Emits `AdminTransferred`.

### `admin_set_fee`
Sets `fee_house.fee_rate`. Aborts with `EInvalidFeeRate` if
`fee_rate > MAX_FEE_RATE` (5000 / 50%).
```move
public fun admin_set_fee(_: &AdminCap, fee_house: &mut FeeHouse, fee_rate: u64);
```
Emits `FeeRateUpdated`.

### `admin_collect_fee_return_coin`
Removes the entire accumulated `Balance<T>` from `fee_house` and returns
it as a `Coin<T>` for caller chaining.
```move
public fun admin_collect_fee_return_coin<T>(
    _: &AdminCap,
    fee_house: &mut FeeHouse,
    ctx: &mut TxContext,
): Coin<T>;
```
Emits `AdminFeeCollected`.

### `admin_collect_fee`
Same as above but transfers the coin directly to `ctx.sender()`.
```move
public fun admin_collect_fee<T>(_: &AdminCap, fee_house: &mut FeeHouse, ctx: &mut TxContext);
```
Emits `AdminFeeCollected`.

### `admin_insert_access_list` / `admin_remove_access_list`
Manage the AccessList (protocol-caller allow set).
```move
public fun admin_insert_access_list(_: &AdminCap, access: &mut AccessList, bot: address);
public fun admin_remove_access_list(_: &AdminCap, access: &mut AccessList, bot: address);
```
Emit `AccessGranted` / `AccessRevoked`.

---

## Events

Position lifecycle: `PositionManagerCreated`, `PositionExtract`,
`PositionManagerClosed`, `RecordCreated`, `RecordDeleted`.

Liquidity: `LiquidityAdded`, `LiquidityRemoved`, `ProtocolLiquidityAdded`,
`ProtocolLiquidityRemoved`, `AgentLiquidityAdded`, `AgentLiquidityRemoved`.

Fee / Reward: `FeeCollected`, `RewardCollected`, `ProtocolFeeCollected`,
`ProtocolRewardCollected`, `AgentFeeCollected`, `AgentRewardCollected`,
`FeeTransferredToBalance`, `UserFeeWithdrawn`, `AdminFeeCollected`.

Balance: `BalanceDeposited`, `BalanceWithdrawn`.

Agent: `AgentAdded`, `AgentRemoved`.

Lending: `ScallopSupplied`, `ScallopRedeemed`, `KaiSupplied`, `KaiRedeemed`.

Admin: `FeeRateUpdated`, `AccessGranted`, `AccessRevoked`,
`AdminTransferred`.

Sender address is NOT a field on any event — the transaction's `sender`
metadata is the canonical source.

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `FEE_DENOMINATOR` | `10000` | Fee rate denominator (basis-points-ish) |
| `MAX_FEE_RATE` | `5000` | Max admin-settable rate (50%) |
| Default fee rate at deploy | `2000` | 20% |

---

## See Also

- `DESIGN.md` — architecture, permission model, lending integration
- `SPEC.md` — formal verification scope and reproducible spec run
- `publish.md` — current deployment state and dep-upgrade procedure
- `SECURITY.md` — security analysis (historical F-01..F-04 retained for record)
