# Architecture

## Contents

- [System Components](#system-components)
- [Core Data Structures](#core-data-structures)
- [Scallop Integration Surface](#scallop-integration-surface)
- [Kai SAV Integration Surface](#kai-sav-integration-surface)
- [Trust Boundary](#trust-boundary)

## System Components

```
┌─────────────────────────────────────────────────────────────┐
│                     Protocol Layer                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  FeeHouse   │  │ AccessList  │  │      AdminCap       │  │
│  │ (Fee config)│  │(Protocol ACL)│  │   (Admin control)   │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└────────────────────┬────────────────────────────────────────┘
                     │
        ┌────────────┼────────────┐
        ▼            ▼            ▼
   ┌─────────┐  ┌─────────┐  ┌─────────┐
   │  User   │  │  Agent  │  │ Protocol│
   │ (Owner) │  │(Limited)│  │(Managed)│
   └─────────┘  └─────────┘  └─────────┘
```

## Core Data Structures

### FeeHouse

```typescript
interface FeeHouse {
  id: string;
  fee_rate: number;          // Basis points (2000 = 20%); cap is 5000 / 50%
  fee: Map<string, string>;  // coin_type -> Balance (collected protocol cuts and lending yield fees)
}
```

### AccessList

```typescript
interface AccessList {
  id: string;
  allow: string[];  // Authorized protocol addresses (VecSet<address>)
}
```

### AdminCap

```typescript
interface AdminCap {
  id: string;  // Owned object; the unique privileged capability
}
```

### PositionManager

```typescript
interface PositionManager {
  id: string;
  owner: string;
  agents: string[];            // VecSet<address> — authorized agent addresses
  pool_id: string;             // The Cetus pool this PM is bound to (set at creation)
  position: string | null;     // Option<Position> — the Cetus DLMM Position, or null when destroyed/never created
  balance: Map<string, string>;  // type_name<T> -> Balance<T>: spendable funds
  fee: Map<string, string>;      // type_name<T> -> Balance<T>: yield bookkeeping
  // Unified lending bag — holds both Scallop and Kai SAV entries:
  //   Scallop: key = type_name<T>,  value = ScallopVault<T> { scoin: Balance<MarketCoin<T>>, principal }
  //   Kai SAV: key = type_name<YT>, value = KaiVault<T, YT>  { yt_balance: Balance<YT>,     principal }
  // At most one Scallop vault per T (sCoin type is pinned to MarketCoin<T> by the type
  // system, so a fake-sCoin variant cannot be supplied). At most one Kai vault per YT
  // (YT's TreasuryCap is held by kai_sav::vault::Vault<T, YT>, so external code cannot
  // forge Coin<YT>). The same T can have both a Scallop and a Kai entry simultaneously
  // because the bag keys differ.
  lending: Map<string, { scoin?: string; yt_balance?: string; principal: string }>;
}
```

`position` is `Option<Position>` in the Move struct. Agents control the Cetus
position lifecycle independently of the owner:

- `agent_create_position<A, B>` opens a fresh position from `pm.balance`
  (asserts the PM holds no position — `EPositionAlreadyExists` 1010 — and
  that the passed pool matches `pm.pool_id` — `EWrongPool` 1012).
- `agent_destroy_position<A, B>` closes the position and routes underlying
  assets back to `pm.balance` (asserts a position exists — `ENoPosition`
  1011 — and all Cetus rewards were collected — `EPositionHasRewards` 1007).

All position-accessing functions (`user_*_from_position`,
`protocol_remove_liquidity` / `protocol_collect_*`, and the agent
equivalents) assert `ENoPosition` when `position` is `None`.

### ScallopVault

```typescript
interface ScallopVault<T> {
  scoin: string;      // Balance<MarketCoin<T>> — Scallop sCoin (yield-bearing market coin)
  principal: u64;     // Original underlying deposited; used for yield accounting
}
```

### KaiVault

```typescript
interface KaiVault<T, YT> {
  yt_balance: string; // Balance<YT> — Kai SAV yield token issued by Vault<T, YT>
  principal: u64;     // Original underlying deposited; used for yield accounting
}
```

### GlobalRecord and Record

```typescript
interface GlobalRecord {
  id: string;
  record: Map<string, string>;  // owner address -> Record id
}

interface Record {
  id: string;
  record: Map<string, boolean>; // PositionManager id -> tracking flag
}
```

`GlobalRecord` is the shared index of registered owners; each owner holds one `Record` object that catalogues their `PositionManager` ids.

## Scallop Integration Surface

cdpm imports the Scallop modules needed for in-call supply / redeem:

- `protocol::market::Market` (object handle, passed to mint / redeem)
- `protocol::reserve::MarketCoin` (the sCoin yield token type)
- `protocol::version::Version` (passed alongside the market)
- `protocol::mint` (called inside `scallop_supply<T>`)
- `protocol::redeem` (called inside `scallop_redeem<T>`)

`scallop_supply<T>` and `scallop_redeem<T>` are each one `tx.moveCall` from the caller's perspective; cdpm runs the Scallop calls itself between withdrawing from the PM balance and re-depositing the resulting sCoin (supply) or underlying (redeem).

## Kai SAV Integration Surface

cdpm imports the Kai SAV modules needed for in-call supply / redeem:

- `kai_sav::vault as kai_vault` for `Vault<T, YT>` plus `deposit`, `withdraw`, and `redeem_withdraw_ticket`.
- `kai_sav::kai_leverage_supply_pool as klsp` for `Strategy<T, ST>` and `klsp::withdraw`.
- `kai_leverage::supply_pool::SupplyPool` for the strategy backing store.

`kai_supply<T, YT>` is one `tx.moveCall`. `kai_redeem<T, ST, YT>` is also one `tx.moveCall` and is generic over the supply-pool strategy `<T, ST>`; cdpm walks `vault::withdraw → klsp::withdraw → vault::redeem_withdraw_ticket` internally.

## Trust Boundary

Both Scallop and Kai integrations inherit upstream-team-trust assumptions for their respective protocols. cdpm has no admin-side YT whitelist and no Scallop-market whitelist; the mitigation surface is agent / protocol-bot selection by the PM owner. See README D-08 / D-10 and DESIGN for the full trust-boundary discussion.
