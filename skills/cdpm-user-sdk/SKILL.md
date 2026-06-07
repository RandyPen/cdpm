---
name: cdpm-user-sdk
description: TypeScript SDK guide for CDPM (Cetus DLMM Position Manager) end-users. Provides PTB construction patterns for creating positions, managing liquidity, authorizing agents, collecting fees, and supplying/redeeming idle funds via Scallop lending or Kai SAV lending. Use when users need to interact with CDPM contract through TypeScript SDK.
---

# CDPM User SDK Guide

## Overview

CDPM (Cetus DLMM Position Manager) is a proxy contract for managing Cetus DLMM positions with support for user self-management, agent delegation, protocol-managed operations, and two optional lending integrations for idle funds: **Scallop** (single-generic `<T>` market coin) and **Kai SAV** (two-generic `<T, YT>` strategy-aggregating vault). Both integrations share `pm.lending: Bag` and a single `fee_house.fee_rate` knob.

**Package Address**: `0x3ad00d82541cfd1fd13568f24b43bf9e36718611533a4853e722438b90ea61f3` (only-dep-upgrades digest: `CmP8QVdyQta1EAQiNpjn9mwkvM56WhzVKjnCVaBh5mWU` — `cdpm.move` bytecode is locked; only dependency-version upgrades are allowed). Other shared object IDs live in [`reference/constants.md`](reference/constants.md).

> The `PositionManager` struct contains a `lending: Bag` holding both Scallop `ScallopVault<T>` entries (keyed by `type_name<T>`) and Kai SAV `KaiVault<T, YT>` entries (keyed by `type_name<YT>`) — both can coexist on a single PM. See [Scallop Lending](reference/scallop-lending.md) and [Kai SAV Lending](reference/kai-lending.md) for end-user PTB recipes.

## Quick Start

### Installation

```bash
bun add @mysten/sui
```

### Initialize Client

```typescript
import { SuiGrpcClient } from '@mysten/sui/grpc';
import { Transaction } from '@mysten/sui/transactions';

const client = new SuiGrpcClient({
  baseUrl: 'https://fullnode.mainnet.sui.io:443',
  network: 'mainnet',
});
const CDPM_PACKAGE = '0x3ad00d82541cfd1fd13568f24b43bf9e36718611533a4853e722438b90ea61f3';
```

## Topics

### Core Operations
- **[Creating Positions](reference/workflows.md)** - First-time and existing user workflows
- **[Position Management](reference/position-management.md)** - Add/remove liquidity, pool ID helpers
- **[Balance Management](reference/position-management.md#balance-management)** - Deposit to and withdraw from balance

### Agent & Fee Management
- **[Agent Management](reference/agent-management.md)** - Authorize/revoke agents
- **[Fee Collection](reference/fee-collection.md)** - Collect fees and rewards

### Scallop Lending (Idle Funds)
- **[Scallop Lending](reference/scallop-lending.md)** - Single MoveCall `scallop_supply<T>` / `scallop_redeem<T>` against Scallop `Market`; yield-fee math on the interest portion; exit only via `scallop_redeem<T>`.

### Kai SAV Lending (Idle Funds)
- **[Kai SAV Lending](reference/kai-lending.md)** - Single MoveCall `kai_supply<T, YT>` / `kai_redeem<T, ST, YT>` against Kai `Vault<T, YT>`; shared yield-fee math; exit only via `kai_redeem<T, ST, YT>`.

### Web Development & Queries
- **[Web Query Guide](reference/web-query.md)** - GraphQL queries for PositionManagers
- **[Pool Query Guide](reference/pool-query.md)** - Query Cetus DLMM pools by coin types

### Reference
- **[Constants](reference/constants.md)** - Package IDs, object IDs, token addresses

## Calculations

For liquidity calculations, bin price math, position management, and fee calculations, use the **cdpm-calculation** skill with the Cetus DLMM SDK:

```typescript
import { BinUtils, FeeUtils } from '@cetusprotocol/dlmm-sdk/utils'

// Common calculations
const qPrice = BinUtils.getQPriceFromId(binId, binStep)
const liquidity = BinUtils.getLiquidity(amountA, amountB, qPrice)
const binId = BinUtils.getBinIdFromPrice(price, binStep, true, decimalA, decimalB)
```

See `cdpm-calculation` skill for complete reference with formulas, examples, and best practices.

## Security Checklist

Before authorizing an agent:

```typescript
async function securityChecklist(
  client: SuiGrpcClient,
  pmId: string,
  agentAddress: string
) {
  // 1. Verify you are the owner
  const { response: pm } = await client.getObject({ id: pmId, include: { content: true } });
  const owner = pm?.content?.fields?.owner;

  // 2. Check agent is not already authorized
  const agents = await getAuthorizedAgents(client, pmId);
  const isAuthorized = agents.includes(agentAddress);

  return { owner, isAuthorized };
}
```

## Error Handling

Common errors and solutions:

```typescript
try {
  const result = await createPositionSmart(/* ... */);
} catch (e) {
  if (e.message.includes('ENotOwner')) {              // 1001
    console.error('Only the owner can perform this operation');
  } else if (e.message.includes('ENotAllow')) {       // 1002
    console.error('Caller not authorized (not owner / agent / whitelisted protocol with no agents set)');
  } else if (e.message.includes('EInvalidFeeRate')) { // 1003
    console.error('Invalid fee rate configuration (cap is 50% / 5000 bp)');
  } else if (e.message.includes('ELendingNotEmpty')) {// 1004
    console.error('pm.lending is non-empty — redeem every Scallop AND Kai vault entry before user_close_pm');
  } else if (e.message.includes('ENoSuchVault')) {    // 1005
    console.error('No ScallopVault<T> or KaiVault<T, YT> entry in pm.lending for the requested key');
  } else if (e.message.includes('ENoSuchBalance')) {  // 1006
    console.error('withdraw_from_balance / withdraw_from_fee called for an absent type key');
  } else if (e.message.includes('EPositionHasRewards')) { // 1007
    console.error('user_close_pm aborted: collect every reward type on the pool with user_collect_reward<A,B,R> first');
  } else if (e.message.includes('EBalanceNotEmpty')) { // 1008
    console.error('user_close_pm aborted: drain every pm.balance[T] with user_remove_liquidity_from_balance<T>(u64::MAX)');
  } else if (e.message.includes('EFeeNotEmpty')) {    // 1009
    console.error('user_close_pm aborted: drain every pm.fee[T] with user_withdraw_fee<T>(u64::MAX)');
  } else {
    console.error('Transaction failed:', e);
  }
}
```

## End-to-End Workflow

For the full close-PM flow (collect rewards → redeem every lending entry → drain `pm.balance` / `pm.fee` → batched `transferObjects` → `user_close_pm`), see [`reference/workflows.md`](reference/workflows.md) § Close Position Safely.
