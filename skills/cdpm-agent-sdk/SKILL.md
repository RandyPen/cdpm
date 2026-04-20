---
name: cdpm-agent-sdk
description: TypeScript SDK guide for AI agents managing CDPM positions. Defines permission boundaries, operation workflows, and automation strategies. Use when building automated liquidity management agents.
---

# CDPM Agent SDK Guide

## Overview

This guide is for AI agents authorized to manage CDPM positions on behalf of users. Agents have limited permissions and operate within specific boundaries.

**Package Address**: `0xbb15c25329fbc85b9cc9cc1d37ee2f913696a7c688d0552ca4dc7e3557598541`

```typescript
import { Transaction } from '@mysten/sui/transactions';
import { SuiGrpcClient } from '@mysten/sui/grpc';
```

## Agent Permission Model

### What Agents CAN Do

| Operation | Description |
|-----------|-------------|
| ✅ Add Liquidity | Add liquidity using PositionManager balance |
| ✅ Remove Liquidity | Remove liquidity and return to balance |
| ✅ Collect Fees | Collect fees from position (goes to fee bag) |
| ✅ Collect Rewards | Collect rewards (goes to fee bag) |
| ✅ Transfer Fee to Balance | Move fees from fee bag to balance |

### What Agents CANNOT Do

| Operation | Reason |
|-----------|--------|
| ❌ Withdraw Funds | Cannot move funds out of PositionManager |
| ❌ Close Position | Only owner can close |
| ❌ Authorize/Revoke Agents | Only owner can manage agents |
| ❌ Modify PositionManager | Cannot change configuration |

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

See `cdpm-calculation` skill for complete reference.

## Complete Example

See [examples/agent-strategy.ts](examples/agent-strategy.ts) for a complete agent implementation with auto-compounding strategy.
