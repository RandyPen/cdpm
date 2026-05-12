---
name: cdpm-user-sdk
description: TypeScript SDK guide for CDPM (Cetus DLMM Position Manager) end-users. Provides PTB construction patterns for creating positions, managing liquidity, authorizing agents, collecting fees, and supplying/redeeming idle funds via Scallop lending or Kai SAV lending. Use when users need to interact with CDPM contract through TypeScript SDK.
---

# CDPM User SDK Guide

## Overview

CDPM (Cetus DLMM Position Manager) is a proxy contract for managing Cetus DLMM positions with support for user self-management, agent delegation, protocol-managed operations, and two optional lending integrations for idle funds: **Scallop** (single-generic `<T>` market coin) and **Kai SAV** (two-generic `<T, YT>` strategy-aggregating vault). Both integrations share `pm.lending: Bag`, the hot-potato ticket pattern, and a single `fee_house.fee_rate` knob.

**Package Address**: `0x3e926116ec95d753b83b80d768e310ef492d84892dee5cc86b51c1d3a876d5b7` (immutable digest: `HWJKADRhTY2XKoB49UCe3c9pYcRRdVKZfHaJZ8URmS16`). Other shared object IDs live in [`reference/constants.md`](reference/constants.md).

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
const CDPM_PACKAGE = '0x3e926116ec95d753b83b80d768e310ef492d84892dee5cc86b51c1d3a876d5b7';
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
- **[Scallop Lending](reference/scallop-lending.md)** - **REQUIRED PTB[0]: `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)` — cdpm-enforced via `EStaleScallopState (1011)`, NOT injected by `scallopTx.deposit` / `depositQuick`.** Hot-potato supply/redeem PTBs; canonical `Market` re-binding on `finish_*` (`EWrongMarket = 1012`); yield-fee math; no wrapper-extract escape (exit only via the full redeem flow).

### Kai SAV Lending (Idle Funds)
- **[Kai SAV Lending](reference/kai-lending.md)** - Two-generic `<T, YT>` hot-potato supply/redeem with strategy walk and canonical `Vault` re-binding on `finish_*`; shared yield-fee math; no wrapper-extract escape (exit only via the full redeem flow)

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
    console.error('PositionManager.lending is non-empty — drain every Scallop AND Kai vault entry before user_close_pm');
  } else if (e.message.includes('ENoSuchVault')) {    // 1005
    console.error('No ScallopVault<T> or KaiVault<T, YT> entry in pm.lending for the requested key');
  } else if (e.message.includes('EReserveEmpty')) {   // 1006
    console.error('Lending reserve degenerate. Scallop: zero supply or zero (cash+debt-revenue) — call accrue_interest_for_market first. Kai: total_yt_supply == 0.');
  } else if (e.message.includes('EZeroExpected')) {   // 1007
    console.error('scallop_start_* / kai_start_* amount too small — would yield 0 scoin / yt / underlying');
  } else if (e.message.includes('EWrongPm')) {        // 1008
    console.error('Hot-potato ticket (Scallop or Kai) consumed against a different PositionManager');
  } else if (e.message.includes('EAmountShortfall')) {// 1009
    console.error('finish_* received Coin with value < ticket.expected. Scallop: stale accrual. Kai: vault state moved between snapshot and signing.');
  } else if (e.message.includes('ENoSuchBalance')) {  // 1010
    console.error('withdraw_from_balance / withdraw_from_fee called for an absent type key');
  } else if (e.message.includes('EStaleScallopState')) { // 1011
    console.error('scallop_start_* called without accrue_interest::accrue_interest_for_market in the same PTB. Make it command 0 of the batch.');
  } else if (e.message.includes('EWrongMarket')) {    // 1012
    console.error('scallop_finish_* received a Market with id != ticket.market_id. Pass the same Market across start_* and finish_*.');
  } else if (e.message.includes('EWrongVault')) {     // 1013
    console.error('kai_finish_* received a Vault with id != ticket.vault_id. Pass the same Vault across start_* and finish_*.');
  } else {
    console.error('Transaction failed:', e);
  }
}
```

## Complete Example

See [examples/user-workflow.ts](examples/user-workflow.ts) for a complete end-to-end workflow.
