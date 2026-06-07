---
name: cdpm-agent-sdk
description: TypeScript SDK guide for AI agents managing CDPM positions. Defines permission boundaries, operation workflows, automation strategies, and the Scallop and Kai SAV supply/redeem APIs agents share with owners and protocol bots. Use when building automated liquidity management agents.
---

# CDPM Agent SDK Guide

## Overview

This guide is for AI agents authorized to manage CDPM positions on behalf of users. Agents have limited permissions and operate within specific boundaries.

**Package Address**: `0x3ad00d82541cfd1fd13568f24b43bf9e36718611533a4853e722438b90ea61f3` (only-dep-upgrades digest: `CmP8QVdyQta1EAQiNpjn9mwkvM56WhzVKjnCVaBh5mWU` — `cdpm.move` bytecode is locked; only dependency-version upgrades are allowed). Other shared object IDs live in [`reference/constants.md`](reference/constants.md).

```typescript
import { Transaction } from '@mysten/sui/transactions';
import { SuiGrpcClient } from '@mysten/sui/grpc';
```

## Agent Permission Model

### What Agents CAN Do

| Operation | Description |
|-----------|-------------|
| Add Liquidity | Add liquidity using PositionManager balance |
| Remove Liquidity | Remove liquidity and return to balance |
| Collect Fees | Collect fees from position (goes to fee bag) |
| Collect Rewards | Collect rewards (goes to fee bag) |
| Transfer Fee to Balance | Move fees from fee bag to balance |
| Scallop `scallop_supply` | Park idle balance into Scallop |
| Scallop `scallop_redeem` | Pull underlying back; yield fee deducted from interest portion |
| Kai SAV `kai_supply` | Park idle balance into a Kai `Vault<T, YT>` |
| Kai SAV `kai_redeem` | Pull underlying back via the strategy walk; same yield fee on interest |

### What Agents CANNOT Do

| Operation | Reason |
|-----------|--------|
| Withdraw Funds | Cannot move funds out of PositionManager |
| Close Position | Only owner can close |
| Authorize/Revoke Agents | Only owner can manage agents |
| Modify PositionManager | Cannot change configuration |
| `user_get_position` / `user_get_and_return_position` | Owner-only Cetus DLMM `Position` extraction — agents cannot pull the `Position` object |

### Permission Check

```typescript
function canAgentOperate(
  pm: PositionManager,
  agentAddress: string
): boolean {
  return pm.agents.includes(agentAddress);
}

// Example check
const { response: pm } = await client.getObject({ id: pmId, include: { content: true } });
const agents = pm?.content?.fields?.agents || [];
const isAuthorized = agents.includes(agentAddress);
```

## Topics

### Core Operations
- **[Agent Operations](reference/agent-operations.md)** - Add/remove liquidity, collect fees, transfer fees
- **[Scallop Lending](reference/scallop-lending.md)** - Agent-driven `scallop_supply` / `scallop_redeem` (one `tx.moveCall` each); yield fee shares `fee_house.fee_rate` with Kai
- **[Kai SAV Lending](reference/kai-lending.md)** - Agent-driven `kai_supply` / `kai_redeem` (one `tx.moveCall` each); yield fee shares `fee_house.fee_rate` with Scallop
- **[Automation Strategies](reference/automation-strategies.md)** - Auto-compounding, rebalancing, fee collection scheduler

### Monitoring & Best Practices
- **[Event Monitoring](reference/event-monitoring.md)** - Subscribe to agent events
- **[Best Practices](reference/best-practices.md)** - Pre-operation checks, batch operations, gas optimization
- **[Security](reference/best-practices.md#security-guidelines)** - Security checklist for agents

### Reference
- **[Error Handling](reference/error-handling.md)** - Common agent errors and recovery strategies
- **[Constants](reference/constants.md)** - Package IDs and default thresholds

## Calculations

For liquidity calculations, bin price math, position management, and fee calculations, use the **cdpm-calculation** skill with the Cetus DLMM SDK:

```typescript
import { BinUtils, FeeUtils } from '@cetusprotocol/dlmm-sdk/utils'

// Agent-specific calculations
const qPrice = BinUtils.getQPriceFromId(binId, binStep)
const liquidity = BinUtils.getLiquidity(amountA, amountB, qPrice)
const binId = BinUtils.getBinIdFromPrice(price, binStep, true, decimalA, decimalB)
const positionCount = BinUtils.getPositionCount(lowerBinId, upperBinId)
const { amount_a, amount_b } = BinUtils.calculateOutByShare(bin, removeLiquidity)

// Agent strategy helper
function distributeLiquidity(totalA: string, totalB: string, bins: number[], binStep: number) {
  return bins.map(binId => {
    const qPrice = BinUtils.getQPriceFromId(binId, binStep)
    const amountA = (BigInt(totalA) / BigInt(bins.length)).toString()
    const amountB = (BigInt(totalB) / BigInt(bins.length)).toString()
    return { binId, amountA, amountB, liquidity: BinUtils.getLiquidity(amountA, amountB, qPrice) }
  })
}
```

See `cdpm-calculation-skill` for the full reference (formulas, redemption sizing, distribution math).
