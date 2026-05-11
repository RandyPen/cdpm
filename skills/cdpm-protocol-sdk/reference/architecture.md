# Architecture

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
  fee_rate: number;          // Basis points (2000 = 20%); cap is 3000 / 30%
  fee: Map<string, string>;  // coin_type -> balance (collected protocol cuts + Scallop yield fees)
}
```

### AccessList

```typescript
interface AccessList {
  id: string;
  allow: string[];  // Authorized protocol addresses
}
```

### PositionManager

```typescript
interface PositionManager {
  id: string;
  owner: string;
  agents: string[];       // Authorized agent addresses
  position: string | null; // Cetus DLMM Position ID
  balance: Map<string, string>;  // Available funds
  fee: Map<string, string>;      // Accumulated fees
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

## Scallop Decoupling

cdpm imports only the read-only / hot-potato surface of Scallop:

- `protocol::market::{Self, Market}` (object handle)
- `protocol::reserve` (view-only access to `balance_sheet`)
- `protocol::borrow_dynamics` (view-only `last_updated_by_type` — used by the freshness floor in `assert_scallop_state_fresh`)
- `x::wit_table` (view-only)

It does **NOT** import `protocol::mint`, `protocol::redeem`, `protocol::version::Version`, or `protocol::accrue_interest`. As a consequence, Scallop `Version` bumps no longer break cdpm — callers compose `accrue_interest`, `mint::mint` and `redeem::redeem` themselves inside the same PTB. The caller's `accrue_interest::accrue_interest_for_market(version, market, clock)` pre-step is mandatory (cdpm asserts `borrow_dynamics::last_updated_by_type == clock::timestamp_ms / 1000` and aborts with `EStaleScallopState (1011)` otherwise); the `borrow_dynamics` accessors used for this check are version-free `public` views, so the decoupling from Scallop `Version` is preserved.

## Kai SAV Decoupling

cdpm imports only the read-only surface of Kai SAV:

- `kai_sav::vault as kai_vault` for the `Vault<T, YT>` type and the view functions
  `total_available_balance(vault, clock)` and `total_yt_supply(vault)`.

It does **NOT** import `kai_sav::vault::deposit`, `kai_sav::vault::withdraw`,
`kai_sav::vault::redeem_withdraw_ticket`, or any strategy module. The mint/burn
side is composed by the caller inside the PTB exactly like Scallop's `mint::mint`
/ `redeem::redeem`. Strategy walks (`<strategy_module>::strategy_withdraw_for_vault`)
are also caller-composed; cdpm never holds a `WithdrawTicket`.

> **Trust boundary.** Both Scallop and Kai integrations inherit upstream-team-trust
> assumptions for their respective protocols. cdpm has no admin-side YT whitelist
> and no Scallop-market whitelist; the mitigation surface is agent / protocol-bot
> selection by the PM owner. See README D-08 / D-10 and DESIGN for the full
> trust-boundary discussion.
