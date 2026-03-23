---
name: cdpm-user-sdk
description: TypeScript SDK guide for CDPM (Cetus DLMM Position Manager) end-users. Provides PTB construction patterns for creating positions, managing liquidity, authorizing agents, and collecting fees. Use when users need to interact with CDPM contract through TypeScript SDK.
---

# CDPM User SDK Guide

## Overview

CDPM (Cetus DLMM Position Manager) is a proxy contract for managing Cetus DLMM positions with support for user self-management, agent delegation, and protocol-managed operations.

**Package Address**: `0xc280a6679edf7d38b1741c8752fefa22d6aa50510856c63aeeb7d918665d9b85`

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
const CDPM_PACKAGE = '0xc280a6679edf7d38b1741c8752fefa22d6aa50510856c63aeeb7d918665d9b85';
```

## Topics

### Core Operations
- **[Creating Positions](reference/workflows.md)** - First-time and existing user workflows
- **[Position Management](reference/position-management.md)** - Add/remove liquidity, pool ID helpers
- **[Balance Management](reference/position-management.md#balance-management)** - Deposit to and withdraw from balance

### Agent & Fee Management  
- **[Agent Management](reference/agent-management.md)** - Authorize/revoke agents
- **[Fee Collection](reference/fee-collection.md)** - Collect fees and rewards

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
  if (e.message.includes('ENotOwner')) {
    console.error('Only the owner can perform this operation');
  } else if (e.message.includes('ENotAllow')) {
    console.error('Caller not authorized');
  } else if (e.message.includes('EInvalidFeeRate')) {
    console.error('Invalid fee rate configuration');
  } else {
    console.error('Transaction failed:', e);
  }
}
```

## Complete Example

See [examples/user-workflow.ts](examples/user-workflow.ts) for a complete end-to-end workflow.
