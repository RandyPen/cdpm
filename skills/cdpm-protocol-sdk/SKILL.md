---
name: cdpm-protocol-sdk
description: TypeScript SDK guide for CDPM protocol integration and management. Covers architecture, permission system, fee mechanics, admin operations, and the Scallop and Kai SAV supply/redeem APIs for agents-empty PMs. Use when building protocol integrations, managing AccessList, or configuring protocol parameters.
---

# CDPM Protocol SDK Guide

## Overview

CDPM (Cetus DLMM Position Manager) protocol layer provides managed liquidity services with fee extraction. This guide covers protocol integration, admin operations, and architecture details.

**Package Address**: `0x3ad00d82541cfd1fd13568f24b43bf9e36718611533a4853e722438b90ea61f3` (only-dep-upgrades digest: `CmP8QVdyQta1EAQiNpjn9mwkvM56WhzVKjnCVaBh5mWU` — `cdpm.move` bytecode is locked; only dependency-version upgrades are allowed). Other shared object IDs live in [`../cdpm-user-sdk/reference/constants.md`](../cdpm-user-sdk/reference/constants.md).

```typescript
import { Transaction } from '@mysten/sui/transactions';
import { SuiGrpcClient } from '@mysten/sui/grpc';
```

## Topics

### Architecture & Permissions
- **[Architecture](reference/architecture.md)** - System components and data structures
- **[Permission System](reference/permission-system.md)** - Permission matrix and access requirements
- **[Fee Mechanics](reference/permission-system.md#fee-mechanics)** - Fee calculation and distribution

### Operations
- **[Admin Operations](reference/admin-operations.md)** - Set fee rate (cap 50%), manage AccessList, collect fees
- **[Protocol Operations](reference/protocol-operations.md)** - Protocol-managed liquidity operations, Cetus reward collection, and Scallop / Kai SAV supply / redeem
- **[Scallop Lending](reference/scallop-lending.md)** - `scallop_supply<T>` / `scallop_redeem<T>` — one `tx.moveCall` each; agents-empty gating; shared yield-fee math; trust-boundary discussion.
- **[Kai SAV Lending](reference/kai-lending.md)** - `kai_supply<T, YT>` / `kai_redeem<T, ST, YT>` — one `tx.moveCall` each; agents-empty gating; shared yield-fee math.

### Reference
- **[Events](reference/events.md)** - Admin, protocol, Scallop, and Kai operation events
- **[Constants](../cdpm-user-sdk/reference/constants.md)** - See user-sdk constants

## Calculations

For liquidity calculations, bin price math, position management, and fee calculations, use the **cdpm-calculation** skill with the Cetus DLMM SDK:

```typescript
import { BinUtils, FeeUtils } from '@cetusprotocol/dlmm-sdk/utils'

// Protocol-specific calculations
const qPrice = BinUtils.getQPriceFromId(binId, binStep)
const liquidity = BinUtils.getLiquidity(amountA, amountB, qPrice)

// Protocol fee calculation
const protocolFees = FeeUtils.getProtocolFees(feeA, feeB, protocolFeeRate)
```

See `cdpm-calculation` skill for complete reference with formulas and best practices.

## Integration Guide

### Move.toml Configuration

```toml
[package]
name = "YourProtocol"
version = "1.0.0"
edition = "2024.beta"

[dependencies]
CetusDlmm = { git = "https://github.com/CetusProtocol/cetus-dlmm-interface.git", subdir = "packages/dlmm", rev = "mainnet-v0.5.0" }
IntegerMate = { git = "https://github.com/CetusProtocol/integer-mate.git", rev = "mainnet-v1.3.0" }
MoveSTL = { git = "https://github.com/CetusProtocol/move-stl.git", rev = "mainnet-v1.3.0" }
CDPM = { git = "https://github.com/your-repo/cdpm.git", rev = "main" }

[addresses]
your_protocol = "0x0"
```

### Querying Protocol State

```typescript
async function getProtocolState(
  client: SuiGrpcClient,
  feeHouseId: string,
  accessListId: string
) {
  const [feeHouseResult, accessListResult] = await Promise.all([
    client.getObject({ id: feeHouseId, include: { content: true } }),
    client.getObject({ id: accessListId, include: { content: true } }),
  ]);
  
  const feeHouse = feeHouseResult.response;
  const accessList = accessListResult.response;
  
  return {
    feeRate: feeHouse?.content?.fields?.fee_rate,
    protocolFees: feeHouse?.content?.fields?.fee,
    allowedAddresses: accessList?.content?.fields?.allow,
  };
}
```

## Security Considerations

### AdminCap Security

```typescript
// Best practices for AdminCap management
const adminSecurity = {
  // 1. Use multi-sig for AdminCap
  useMultisig: true,
  
  // 2. Set reasonable fee rate limits
  maxFeeRate: 5000,  // 50% — contract-enforced ceiling
  
  // 3. Regular access list audits
  auditInterval: 7 * 24 * 60 * 60 * 1000,  // 7 days
  
  // 4. Monitor protocol fee accumulation
  feeCollectionThreshold: 10000n,  // Collect when fees exceed threshold
};
```

### Protocol Operation Checks

```typescript
async function validateProtocolOperation(
  client: SuiGrpcClient,
  accessListId: string,
  pmId: string,
  protocolAddress: string
): Promise<{ valid: boolean; reason?: string }> {
  // Check if in AccessList
  const { response: accessList } = await client.getObject({ 
    id: accessListId, 
    include: { content: true } 
  });
  const allowed = accessList?.content?.fields?.allow || [];
  
  if (!allowed.includes(protocolAddress)) {
    return { valid: false, reason: 'Not in AccessList' };
  }
  
  // Check if agents are empty
  const { response: pm } = await client.getObject({ 
    id: pmId, 
    include: { content: true } 
  });
  const agents = pm?.content?.fields?.agents || [];
  
  if (agents.length > 0) {
    return { valid: false, reason: 'Position has active agents' };
  }
  
  return { valid: true };
}
```

## Error Handling

```typescript
// Source: sources/cdpm.move — codes are SHARED between Scallop and Kai integrations.
const ERROR_CODES = {
  ENotOwner:           1001, // Caller is not pm.owner (user-only operations such as user_get_position / user_get_and_return_position)
  ENotAllow:           1002, // Caller not in agents / access list, or protocol-tier gating with non-empty pm.agents
  EInvalidFeeRate:     1003, // admin_set_fee given rate > MAX_FEE_RATE (5000 / 50%)
  ELendingNotEmpty:    1004, // user_close_pm called with non-empty lending Bag (any Scallop or Kai entry)
  ENoSuchVault:        1005, // pull_from_scallop_lending or pull_from_kai_lending for an absent vault entry
  ENoSuchBalance:      1006, // withdraw_from_balance / withdraw_from_fee for an absent type key
  EPositionHasRewards: 1007, // user_close_pm called with unclaimed Cetus pool rewards on PositionInfo.rewards_owned
  EBalanceNotEmpty:    1008, // user_close_pm called with non-empty balance Bag
  EFeeNotEmpty:        1009, // user_close_pm called with non-empty fee Bag
};

function parseError(error: string): string {
  if (error.includes('ENotOwner')) {
    return 'Operation requires owner permission';
  } else if (error.includes('ENotAllow')) {
    return 'Caller not in AccessList, or PositionManager has active agents (protocol tier requires pm.agents empty)';
  } else if (error.includes('EInvalidFeeRate')) {
    return 'Fee rate must be between 0 and 5000 (50% cap enforced by admin_set_fee)';
  } else if (error.includes('ELendingNotEmpty')) {
    return 'PositionManager.lending is non-empty; drain every ScallopVault<T> AND KaiVault<T, YT> entry before user_close_pm';
  } else if (error.includes('ENoSuchVault')) {
    return 'scallop_redeem / kai_redeem invoked for a (T) or (T, YT) pair with no entry in pm.lending';
  } else if (error.includes('ENoSuchBalance')) {
    return 'Internal withdraw_from_balance / withdraw_from_fee called for a coin type not present in the bag';
  } else if (error.includes('EPositionHasRewards')) {
    return 'user_close_pm aborted because Cetus PositionInfo.rewards_owned has nonzero entries — call user_collect_reward for each reward type first';
  } else if (error.includes('EBalanceNotEmpty')) {
    return 'user_close_pm aborted because pm.balance still holds at least one coin type — drain via user_remove_liquidity_from_balance first';
  } else if (error.includes('EFeeNotEmpty')) {
    return 'user_close_pm aborted because pm.fee still holds at least one coin type — drain via user_withdraw_fee first';
  }
  return 'Unknown error';
}
```

