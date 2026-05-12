---
name: cdpm-protocol-sdk
description: TypeScript SDK guide for CDPM protocol integration and management. Covers architecture, permission system, fee mechanics, admin operations, and the Scallop and Kai SAV hot-potato supply/redeem APIs for agents-empty PMs. Use when building protocol integrations, managing AccessList, or configuring protocol parameters.
---

# CDPM Protocol SDK Guide

## Overview

CDPM (Cetus DLMM Position Manager) protocol layer provides managed liquidity services with fee extraction. This guide covers protocol integration, admin operations, and architecture details.

**Package Address**: `0x3e926116ec95d753b83b80d768e310ef492d84892dee5cc86b51c1d3a876d5b7` (immutable digest: `HWJKADRhTY2XKoB49UCe3c9pYcRRdVKZfHaJZ8URmS16`). Other shared object IDs live in [`../cdpm-user-sdk/reference/constants.md`](../cdpm-user-sdk/reference/constants.md).

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
- **[Admin Operations](reference/admin-operations.md)** - Set fee rate (cap 30%), manage AccessList, collect fees
- **[Protocol Operations](reference/protocol-operations.md)** - Protocol-managed liquidity operations and Scallop supply/redeem
- **[Scallop Lending](reference/scallop-lending.md)** - **REQUIRED PTB[0]: `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)` — cdpm-enforced via `EStaleScallopState (1011)`, NOT injected by `scallopTx.deposit` / `depositQuick`.** Protocol-tier `scallop_start_supply` / `scallop_start_redeem`; canonical `Market` rebinding on `finish_*` (`EWrongMarket = 1012`); agents-empty gating; shared yield-fee math; trust-boundary discussion.
- **[Kai SAV Lending](reference/kai-lending.md)** - Protocol-tier `kai_start_supply` / `kai_start_redeem` with strategy walk and canonical `Vault` rebinding on `finish_*` (`EWrongVault = 1013`); agents-empty gating; shared yield-fee math

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
  maxFeeRate: 3000,  // 30%
  
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
  ENotOwner:           1001, // Caller is not pm.owner (user_get_position / user_get_and_return_position — Cetus DLMM Position escape, the sole owner-only function)
  ENotAllow:           1002, // Caller not in agents / access list (or invariant broken)
  EInvalidFeeRate:     1003, // admin_set_fee given rate > MAX_FEE_RATE (3000 / 30%)
  ELendingNotEmpty:    1004, // user_close_pm called with non-empty lending Bag (any Scallop or Kai entry)
  ENoSuchVault:        1005, // pull_from_scallop_lending or pull_from_kai_lending for an absent vault entry
  EReserveEmpty:       1006, // Scallop reserve degenerate (cash+debt-revenue == 0) OR Kai vault total_yt_supply == 0
  EZeroExpected:       1007, // scallop_start_* / kai_start_* would yield 0 — amount too small
  EWrongPm:            1008, // Hot-potato ticket consumed against a different PM (Scallop or Kai)
  EAmountShortfall:    1009, // scallop_finish_* / kai_finish_* received Coin with value < ticket.expected
  ENoSuchBalance:      1010, // withdraw_from_balance / withdraw_from_fee for an absent type key
  EStaleScallopState:  1011, // scallop_start_* called before accrue_interest_for_market in the same PTB second
  EWrongMarket:        1012, // scallop_finish_* received a Market with id != ticket.market_id
  EWrongVault:         1013, // kai_finish_* received a Vault with id != ticket.vault_id
};

function parseError(error: string): string {
  if (error.includes('ENotOwner')) {
    return 'Operation requires owner permission';
  } else if (error.includes('ENotAllow')) {
    return 'Caller not in AccessList, or PositionManager has active agents';
  } else if (error.includes('EInvalidFeeRate')) {
    return 'Fee rate must be between 0 and 3000 (30% cap enforced by admin_set_fee)';
  } else if (error.includes('ELendingNotEmpty')) {
    return 'PositionManager.lending is non-empty; drain every ScallopVault<T> AND KaiVault<T, YT> entry before user_close_pm';
  } else if (error.includes('EReserveEmpty')) {
    return 'Underlying reserve degenerate. Scallop: zero supply or zero (cash+debt-revenue) — accrue_interest_for_market first. Kai: total_yt_supply == 0.';
  } else if (error.includes('EAmountShortfall')) {
    return 'finish_* Coin value < ticket.expected. Scallop: likely stale accrual — run accrue_interest_for_market first. Kai: vault state moved between snapshot and signing — re-snapshot.';
  } else if (error.includes('EStaleScallopState')) {
    return 'scallop_start_* called without accrue_interest::accrue_interest_for_market in the same PTB. Make it command 0 of the batch — cdpm enforces this.';
  } else if (error.includes('EWrongMarket')) {
    return 'scallop_finish_* received a Market with id != ticket.market_id. Reuse the same tx.object(SCALLOP_MARKET_ID) handle across start_* and finish_*.';
  } else if (error.includes('EWrongVault')) {
    return 'kai_finish_* received a Vault with id != ticket.vault_id. Reuse the same tx.object(vaultObjectId) handle across start_* and finish_*.';
  }
  return 'Unknown error';
}
```

## Complete Example

See [examples/protocol-integration.ts](examples/protocol-integration.ts) for a complete protocol integration example.
