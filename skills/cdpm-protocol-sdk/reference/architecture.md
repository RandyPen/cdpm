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
  // Scallop lending vaults — keyed by `type_name<T>` (underlying coin type only).
  // Value type: ScallopVault<T> { scoin: Balance<MarketCoin<T>>, principal: u64 }.
  // At most one vault per T; the sCoin type is structurally pinned to
  // MarketCoin<T> by the type system, so a fake-sCoin variant cannot be supplied.
  lending: Map<string, { scoin: string; principal: string }>;
}
```

### ScallopVault

```typescript
interface ScallopVault<T> {
  scoin: string;      // Balance<MarketCoin<T>> — Scallop sCoin (yield-bearing market coin)
  principal: u64;     // Original underlying deposited; used for yield accounting
}
```

## Scallop Decoupling

cdpm imports only the read-only / hot-potato surface of Scallop:

- `protocol::market::{Self, Market}` (object handle)
- `protocol::reserve` (view-only access to `balance_sheet`)
- `x::wit_table` (view-only)

It does **NOT** import `protocol::mint`, `protocol::redeem`, `protocol::version::Version`, or `protocol::accrue_interest`. As a consequence, Scallop `Version` bumps no longer break cdpm — callers compose `accrue_interest`, `mint::mint` and `redeem::redeem` themselves inside the same PTB.
