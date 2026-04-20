---
name: cdpm-protocol-sdk
description: TypeScript SDK guide for CDPM protocol integration and management. Covers architecture, permission system, fee mechanics, and admin operations. Use when building protocol integrations, managing AccessList, or configuring protocol parameters.
---

# CDPM Protocol SDK Guide

## Overview

CDPM (Cetus DLMM Position Manager) protocol layer provides managed liquidity services with fee extraction. This guide covers protocol integration, admin operations, and architecture details.

**Package Address**: `0xbb15c25329fbc85b9cc9cc1d37ee2f913696a7c688d0552ca4dc7e3557598541`

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
- **[Admin Operations](reference/admin-operations.md)** - Set fee rate, manage AccessList, collect fees
- **[Protocol Operations](reference/protocol-operations.md)** - Protocol-managed liquidity operations

### Reference
- **[Events](reference/events.md)** - Admin and protocol operation events
- **[Constants](reference/../cdpm-user-sdk/reference/constants.md)** - See user-sdk constants

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
const ERROR_CODES = {
  ENotOwner: 1001,        // Caller is not owner
  ENotAllow: 1002,        // Caller not authorized
  EInvalidFeeRate: 1003,  // Fee rate exceeds FEE_DENOMINATOR
};

function parseError(error: string): string {
  if (error.includes('ENotOwner')) {
    return 'Operation requires owner permission';
  } else if (error.includes('ENotAllow')) {
    return 'Caller not in AccessList or position has active agents';
  } else if (error.includes('EInvalidFeeRate')) {
    return 'Fee rate must be between 0 and 10000';
  }
  return 'Unknown error';
}
```

## Complete Example

See [examples/protocol-integration.ts](examples/protocol-integration.ts) for a complete protocol integration example.
