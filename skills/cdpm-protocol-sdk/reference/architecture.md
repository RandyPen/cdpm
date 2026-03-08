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
  fee_rate: number;  // Basis points (2000 = 20%)
  fee: Map<string, string>;  // coin_type -> balance
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
}
```
