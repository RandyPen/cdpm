---
name: cdpm-user-sdk
description: TypeScript SDK guide for CDPM (Cetus DLMM Position Manager) end-users. Provides PTB construction patterns for creating positions, managing liquidity, authorizing agents, collecting fees, and supplying/redeeming idle funds via Scallop lending or Kai SAV lending. Use when users need to interact with CDPM contract through TypeScript SDK.
---

# CDPM User SDK Guide

## Overview

CDPM (Cetus DLMM Position Manager) is a proxy contract for managing Cetus DLMM positions with support for user self-management, agent delegation, protocol-managed operations, and optional Scallop lending integration for idle funds.

**Package Address**: `0x0000000000000000000000000000000000000000000000000000000000000000`

> The `PositionManager` struct now contains a fourth bag, `lending: Bag`, holding both Scallop `ScallopVault<T>` entries (keyed by `type_name<T>`) and Kai SAV `KaiVault<T, YT>` entries (keyed by `type_name<YT>`) — both can coexist on a single PM. See [Scallop Lending](reference/scallop-lending.md) and [Kai SAV Lending](reference/kai-lending.md) for end-user PTB recipes.

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
const CDPM_PACKAGE = '0x0000000000000000000000000000000000000000000000000000000000000000';
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
- **[Scallop Lending](reference/scallop-lending.md)** - Hot-potato supply/redeem PTBs, owner-only escape hatch, yield-fee math

### Kai SAV Lending (Idle Funds)
- **[Kai SAV Lending](reference/kai-lending.md)** - Two-generic `<T, YT>` hot-potato supply/redeem with strategy walk, owner-only `user_extract_kai_yt` escape, shared yield-fee math

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
    console.error('Caller not authorized');
  } else if (e.message.includes('EInvalidFeeRate')) { // 1003
    console.error('Invalid fee rate configuration (cap is 30% / 3000 bp)');
  } else if (e.message.includes('ELendingNotEmpty')) {// 1004
    console.error('PositionManager.lending is non-empty — drain Scallop vaults before user_close_pm');
  } else if (e.message.includes('ENoSuchVault')) {    // 1005
    console.error('No ScallopVault for that underlying coin type');
  } else if (e.message.includes('EReserveEmpty')) {   // 1006
    console.error('Scallop reserve has zero supply or zero (cash+debt-revenue) — accrue_interest first?');
  } else if (e.message.includes('EZeroExpected')) {   // 1007
    console.error('scallop_start_supply/scallop_start_redeem amount too small — would yield 0 scoin/underlying');
  } else if (e.message.includes('EWrongPm')) {        // 1008
    console.error('Hot-potato ticket consumed against a different PositionManager');
  } else if (e.message.includes('EAmountShortfall')) {// 1009
    console.error('finish_* received Coin with value < ticket.expected — Scallop returned less than predicted');
  } else {
    console.error('Transaction failed:', e);
  }
}
```

## Complete Example

See [examples/user-workflow.ts](examples/user-workflow.ts) for a complete end-to-end workflow.
