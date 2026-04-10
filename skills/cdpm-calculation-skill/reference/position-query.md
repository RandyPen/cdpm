# PositionManager Query Guide

This guide explains how to query PositionManager information, including asset balances, unclaimed fees, and rewards. The queries use transaction simulation to get accurate, up-to-date data.

## Overview

To query a PositionManager's assets and fees, you need to:
1. Fetch basic PositionManager data from chain
2. Simulate a transaction to get position details (assets, fees, rewards)
3. Parse and normalize the results

## Setup

```typescript
import { SuiGrpcClient } from '@mysten/sui/grpc';
import { Transaction } from '@mysten/sui/transactions';
import { bcs } from '@mysten/sui/bcs';
import { normalizeStructTag, parseStructTag } from '@mysten/sui/utils';
import { dlmmMainnet } from '@cetusprotocol/dlmm-sdk';

// Constants
const CDPM_PACKAGE = '0xc280a6679edf7d38b1741c8752fefa22d6aa50510856c63aeeb7d918665d9b85';
const CETUS_MAINNET = {
  VERSIONED_ID: '0x05370b2d656612dd5759cbe80463de301e3b94a921dfc72dd9daa2ecdeb2d0a8',
};
const CLOCK_ID = '0x6';
```

## Type Definitions

```typescript
export interface PositionManagerData {
  pmId: string;
  owner: string;
  positionId: string;
  poolId: string;
  coinTypeA: string;
  coinTypeB: string;
  symbolA: string;
  symbolB: string;
  decimalsA: number;
  decimalsB: number;
}

export interface FeesAndRewards {
  amounts: {
    amountA: { raw: bigint; normalized: number };
    amountB: { raw: bigint; normalized: number };
  };
  fees: {
    feeA: { raw: bigint; normalized: number };
    feeB: { raw: bigint; normalized: number };
  };
  rewards: {
    rawBcsData?: Uint8Array;  // Rewards need parsing based on pool configuration
  };
}
```

## Core Functions

### Fetch PositionManager Basic Data

```typescript
export async function fetchPositionManagerData(
  client: SuiGrpcClient,
  pmId: string
): Promise<PositionManagerData> {
  const pmObject = await client.getObject({
    objectId: pmId,
    include: { json: true },
  });

  const content = pmObject.object?.json as any;
  if (!content) {
    throw new Error(`PositionManager ${pmId} object content is empty`);
  }

  const owner = content.owner;
  const positionId = content.position?.id;
  const poolId = content.position?.pool_id;
  let coinTypeA = content.position?.coin_type_a;
  let coinTypeB = content.position?.coin_type_b;

  if (!positionId || !poolId || !coinTypeA || !coinTypeB) {
    throw new Error(`Failed to extract position info from PositionManager ${pmId}`);
  }

  // Helper function to extract base coin type from possibly full coin type
  const getBaseCoinType = (type: string): string => {
    try {
      // Try to parse as struct tag
      const parsed = parseStructTag(type);
      // If it's a Coin<T> type, extract the inner type
      if (parsed.address === '0x2' && parsed.module === 'coin' && parsed.name === 'Coin' && parsed.typeParams.length === 1) {
        const innerType = parsed.typeParams[0];
        return normalizeStructTag(typeof innerType === 'string' ? innerType : innerType);
      }
      // Otherwise, normalize the type as-is
      return normalizeStructTag(type);
    } catch {
      // If parsing fails, normalize as-is
      return normalizeStructTag(type);
    }
  };

  // Extract and normalize base coin types
  const baseCoinTypeA = getBaseCoinType(coinTypeA);
  const baseCoinTypeB = getBaseCoinType(coinTypeB);

  // Get token metadata using client.getCoinMetadata
  const [metadataA, metadataB] = await Promise.all([
    client.getCoinMetadata({ coinType: baseCoinTypeA }),
    client.getCoinMetadata({ coinType: baseCoinTypeB }),
  ]);

  // Extract decimals and symbols from metadata
  const decimalsA = metadataA.coinMetadata?.decimals ?? 9;
  const decimalsB = metadataB.coinMetadata?.decimals ?? 9;
  const symbolA = metadataA.coinMetadata?.symbol ?? 'Unknown';
  const symbolB = metadataB.coinMetadata?.symbol ?? 'Unknown';

  return {
    pmId,
    owner,
    positionId,
    poolId,
    coinTypeA: baseCoinTypeA,
    coinTypeB: baseCoinTypeB,
    symbolA,
    symbolB,
    decimalsA,
    decimalsB,
  };
}
```

### Query Position Details via Simulation

```typescript
export async function queryPositionDetails(
  client: SuiGrpcClient,
  pmData: PositionManagerData
): Promise<FeesAndRewards> {
  const DLMM_PACKAGE_ID = dlmmMainnet.dlmm_pool.published_at;
  const VERSIONED_ID = CETUS_MAINNET.VERSIONED_ID;

  const tx = new Transaction();

  // 1. Refresh position info
  const positionDetail = tx.moveCall({
    package: DLMM_PACKAGE_ID,
    module: 'pool',
    function: 'refresh_position_info',
    arguments: [
      tx.object(pmData.poolId),
      tx.pure.address(pmData.positionId),
      tx.object(VERSIONED_ID),
      tx.object(CLOCK_ID),
    ],
    typeArguments: [pmData.coinTypeA, pmData.coinTypeB],
  });

  // 2. Get asset amounts
  const [amountA, amountB] = tx.moveCall({
    package: DLMM_PACKAGE_ID,
    module: 'pool',
    function: 'position_detail_amounts',
    arguments: [positionDetail],
  });

  // 3. Get fees
  const [feeA, feeB] = tx.moveCall({
    package: DLMM_PACKAGE_ID,
    module: 'pool',
    function: 'position_detail_fees',
    arguments: [positionDetail],
  });

  // 4. Get rewards
  const [rewards] = tx.moveCall({
    package: DLMM_PACKAGE_ID,
    module: 'pool',
    function: 'position_detail_rewards',
    arguments: [positionDetail],
  });

  // Simulate transaction
  const simulationResult = await client.simulateTransaction({
    transaction: tx,
    include: { commandResults: true },
    checksEnabled: false,
  });

  const results = simulationResult.commandResults!;
  if (results.length < 4) {
    throw new Error('Simulation returned insufficient results');
  }

  // Helper to safely get BCS data
  const getBcsValue = (resultIndex: number, valueIndex: number): Uint8Array => {
    const result = results[resultIndex];
    if (!result || !result.returnValues || result.returnValues.length <= valueIndex) {
      throw new Error(`Cannot get result at index ${resultIndex}.${valueIndex}`);
    }
    const value = result.returnValues[valueIndex] as { bcs?: Uint8Array; value?: Uint8Array };
    const bcsData = value.bcs || value.value;
    if (!bcsData) {
      throw new Error(`Result at index ${resultIndex}.${valueIndex} has no BCS data`);
    }
    return bcsData;
  };

  const getOptionalBcsValue = (resultIndex: number, valueIndex: number): Uint8Array | undefined => {
    const result = results[resultIndex];
    if (!result || !result.returnValues || result.returnValues.length <= valueIndex) {
      return undefined;
    }
    const value = result.returnValues[valueIndex] as { bcs?: Uint8Array; value?: Uint8Array };
    return value.bcs || value.value;
  };

  // Parse results
  const rawAmountA = bcs.U64.parse(getBcsValue(1, 0));
  const rawAmountB = bcs.U64.parse(getBcsValue(1, 1));
  const rawFeeA = bcs.U64.parse(getBcsValue(2, 0));
  const rawFeeB = bcs.U64.parse(getBcsValue(2, 1));
  const rewardsBcs = getOptionalBcsValue(3, 0);

  return {
    amounts: {
      amountA: {
        raw: rawAmountA,
        normalized: normalizeAmount(rawAmountA, pmData.decimalsA),
      },
      amountB: {
        raw: rawAmountB,
        normalized: normalizeAmount(rawAmountB, pmData.decimalsB),
      },
    },
    fees: {
      feeA: {
        raw: rawFeeA,
        normalized: normalizeAmount(rawFeeA, pmData.decimalsA),
      },
      feeB: {
        raw: rawFeeB,
        normalized: normalizeAmount(rawFeeB, pmData.decimalsB),
      },
    },
    rewards: {
      rawBcsData: rewardsBcs,
    },
  };
}
```

### Normalization Functions

```typescript
// Normalize raw amount to human-readable format
export function normalizeAmount(raw: bigint, decimals: number): number {
  if (raw === BigInt(0)) return 0;
  const divisor = BigInt(10 ** decimals);
  const whole = raw / divisor;
  const fraction = raw % divisor;
  return Number(whole) + Number(fraction) / Number(divisor);
}

// Format amount with appropriate decimal places
export function formatAmount(amount: number, decimals: number): string {
  return amount.toLocaleString('en-US', {
    minimumFractionDigits: Math.min(decimals, 6),
    maximumFractionDigits: Math.min(decimals, 6),
  });
}

// Calculate total value in quote token
export function calculateTotalValue(
  amountA: number,
  amountB: number,
  priceAInQuote: number,  // Price of token A in quote token (e.g., USDC)
  priceBInQuote: number   // Price of token B in quote token
): number {
  return (amountA * priceAInQuote) + (amountB * priceBInQuote);
}
```

## Usage Examples

### Complete Query Function

```typescript
export async function queryPositionManagerFeesAndAssets(
  client: SuiGrpcClient,
  pmId: string
): Promise<{
  pmData: PositionManagerData;
  results: FeesAndRewards;
}> {
  // 1. Get PositionManager data
  const pmData = await fetchPositionManagerData(client, pmId);

  // 2. Query position details
  const results = await queryPositionDetails(client, pmData);

  return { pmData, results };
}
```

### Example with Formatting

```typescript
async function exampleQuery(pmId: string) {
  const client = new SuiGrpcClient({
    baseUrl: 'https://fullnode.mainnet.sui.io:443',
    network: 'mainnet',
  });

  try {
    const { pmData, results } = await queryPositionManagerFeesAndAssets(client, pmId);

    console.log('PositionManager:', pmData.pmId);
    console.log('Owner:', pmData.owner);
    console.log('Pool:', pmData.poolId);
    console.log('');

    console.log('Asset Balances:');
    console.log(`  ${pmData.symbolA}:`, 
      formatAmount(results.amounts.amountA.normalized, pmData.decimalsA));
    console.log(`  ${pmData.symbolB}:`, 
      formatAmount(results.amounts.amountB.normalized, pmData.decimalsB));
    console.log('');

    console.log('Unclaimed Fees:');
    console.log(`  ${pmData.symbolA}:`, 
      formatAmount(results.fees.feeA.normalized, pmData.decimalsA));
    console.log(`  ${pmData.symbolB}:`, 
      formatAmount(results.fees.feeB.normalized, pmData.decimalsB));

  } catch (error) {
    console.error('Query failed:', error);
  }
}
```

## Integration with Cetus DLMM SDK

For additional calculations, combine with Cetus DLMM SDK:

```typescript
import { BinUtils } from '@cetusprotocol/dlmm-sdk/utils';

async function analyzePositionPerformance(
  client: SuiGrpcClient,
  pmId: string,
  historicalPrices: Map<number, number> // binId -> price
) {
  const { pmData, results } = await queryPositionManagerFeesAndAssets(client, pmId);
  
  // Get pool info for bin calculations
  const poolObject = await client.getObject({
    objectId: pmData.poolId,
    include: { json: true },
  });
  
  const poolData = poolObject.object?.json as any;
  const binStep = poolData?.bin_step || 10;
  
  // Calculate value at different price points
  const currentValue = calculatePositionValue(
    results.amounts.amountA.raw,
    results.amounts.amountB.raw,
    historicalPrices,
    binStep,
    pmData.decimalsA,
    pmData.decimalsB
  );
  
  return {
    currentValue,
    unclaimedFees: results.fees,
    poolInfo: {
      binStep,
      activeBin: poolData?.active_index,
    },
  };
}

function calculatePositionValue(
  amountA: bigint,
  amountB: bigint,
  prices: Map<number, number>,
  binStep: number,
  decimalsA: number,
  decimalsB: number
): number {
  // Implementation depends on your valuation model
  // This could calculate value based on current market prices
  return 0;
}
```

## Best Practices

### 1. Cache Results
```typescript
const queryCache = new Map<string, { data: FeesAndRewards; timestamp: number }>();
const CACHE_TTL = 60000; // 1 minute

async function cachedQuery(
  client: SuiGrpcClient,
  pmId: string
): Promise<FeesAndRewards> {
  const cached = queryCache.get(pmId);
  if (cached && Date.now() - cached.timestamp < CACHE_TTL) {
    return cached.data;
  }
  
  const { results } = await queryPositionManagerFeesAndAssets(client, pmId);
  queryCache.set(pmId, { data: results, timestamp: Date.now() });
  return results;
}
```

### 2. Batch Queries
```typescript
async function batchQueryPositionManagers(
  client: SuiGrpcClient,
  pmIds: string[]
): Promise<Map<string, FeesAndRewards>> {
  const results = new Map();
  
  // Process in batches to avoid rate limiting
  const batchSize = 5;
  for (let i = 0; i < pmIds.length; i += batchSize) {
    const batch = pmIds.slice(i, i + batchSize);
    const batchResults = await Promise.allSettled(
      batch.map(id => queryPositionManagerFeesAndAssets(client, id))
    );
    
    batchResults.forEach((result, index) => {
      if (result.status === 'fulfilled') {
        results.set(batch[index], result.value.results);
      }
    });
    
    // Small delay between batches
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  
  return results;
}
```

### 3. Error Handling
```typescript
async function robustQuery(
  client: SuiGrpcClient,
  pmId: string,
  maxRetries = 3
): Promise<FeesAndRewards | null> {
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      const { results } = await queryPositionManagerFeesAndAssets(client, pmId);
      return results;
    } catch (error) {
      console.warn(`Attempt ${attempt} failed:`, error.message);
      if (attempt === maxRetries) {
        console.error(`Failed to query ${pmId} after ${maxRetries} attempts`);
        return null;
      }
      await new Promise(resolve => setTimeout(resolve, 1000 * attempt)); // Exponential backoff
    }
  }
  return null;
}
```

## Related Calculations

Combine with other calculation utilities:

1. **Fee Analysis** - Calculate fee collection efficiency
2. **Performance Metrics** - Track position performance over time
3. **Risk Assessment** - Evaluate concentration and market exposure
4. **Rebalancing Decisions** - Determine when to adjust position

See other reference guides for more calculation utilities.