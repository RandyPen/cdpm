# Pool Query Guide

Query pools by coin types and fee tier. Coin types must be sorted alphabetically.

## Sort Coin Types

```typescript
/**
 * Sort coin types for CDPM and Cetus Pool (SUI always as CoinB)
 * Both CDPM and Cetus use the same order: larger lexicographical order = CoinA
 * Example: USDC (larger) = CoinA, SUI (smaller) = CoinB
 */
function sortCoinTypes(coinA: string, coinB: string): [string, string] {
  // Return [larger, smaller]
  return coinA > coinB ? [coinA, coinB] : [coinB, coinA];
}

// Example: USDC/SUI pair
const [coinA, coinB] = sortCoinTypes(
  '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',  // larger
  '0x2::sui::SUI'  // smaller
);
// Result: [USDC, SUI] - USDC is CoinA, SUI is CoinB
```

## Query Pool by Registry

Use GraphQL to find pool by coin types, bin step, and base factor:

```typescript
interface PoolInfo {
  id: string;
  coinTypeA: string;
  coinTypeB: string;
  binStep: number;
  baseFactor: number;
  fee: string;
  activeBinId: number;
}

async function findPoolByCoinTypesAndFee(
  coinTypeA: string,
  coinTypeB: string,
  binStep: number,
  baseFactor: number
): Promise<PoolInfo | null> {
  // Sort coin types: larger = CoinA, smaller = CoinB
  const [sortedA, sortedB] = sortCoinTypes(coinTypeA, coinTypeB);
  
  const query = `
    query FindPool($registryId: SuiAddress!, $coinTypeA: String!, $coinTypeB: String!) {
      object(address: $registryId) {
        asMoveObject {
          contents {
            json
          }
        }
      }
    }
  `;

  const result = await graphqlClient.query({
    query,
    variables: {
      registryId: CETUS_MAINNET.REGISTRY_ID,
      coinTypeA: sortedA,
      coinTypeB: sortedB,
    },
  });

  const registryData = result.object?.asMoveObject?.contents?.json;
  if (!registryData?.table) return null;

  // Find pool in registry table matching coin types, bin_step, and base_factor
  const poolEntry = Object.entries(registryData.table).find(([_, pool]: [string, any]) => {
    return (
      pool.coin_type_x === sortedA &&
      pool.coin_type_y === sortedB &&
      pool.base_factor === baseFactor
    );
  });

  if (!poolEntry) return null;

  const [poolId, poolData] = poolEntry as [string, any];
  return {
    id: poolId,
    coinTypeA: poolData.coin_type_x,
    coinTypeB: poolData.coin_type_y,
    binStep: poolData.bin_step,
    baseFactor: poolData.base_factor,
    fee: calculateFee(poolData.base_factor, poolData.bin_step),
    activeBinId: poolData.active_index,
  };
}

// Calculate fee from base factor and bin step
function calculateFee(baseFactor: number, binStep: number): string {
  const FEE_PRECISION = 1000000000;  // 1e9
  const fee = (BigInt(baseFactor) * BigInt(binStep) * 10000n) / BigInt(FEE_PRECISION);
  return (Number(fee) / 10000).toFixed(6);
}

// Calculate base factor from fee rate and bin step
function calculateBaseFactor(feeRate: string, binStep: number): number {
  const FEE_PRECISION = 1000000000;  // 1e9
  // feeRate example: '0.003' = 0.3%
  const fee = parseFloat(feeRate);
  const baseFactor = (fee * FEE_PRECISION) / binStep;
  return Math.round(baseFactor);
}

// Example:
// Fee 0.3% = 0.003, binStep = 30
// baseFactor = (0.003 * 1,000,000,000) / 30 = 100,000
```

## Alternative: Query Pool Created Events

Query pools by token pair, bin step, and fee rate from creation events:

```typescript
async function findPoolFromEvents(
  coinAType: string,  // Token with larger lexicographical order
  coinBType: string,  // Token with smaller lexicographical order (e.g., SUI)
  binStep: number,
  feeRate: string,    // e.g., '0.003' for 0.3%
  startTime?: string  // Optional: ISO timestamp filter
): Promise<string[]> {
  // Calculate baseFactor from fee rate
  const baseFactor = calculateBaseFactor(feeRate, binStep);
  
  const query = `
    query PoolCreatedEvents($type: String!) {
      events(
        first: 100
        filter: { 
          type: $type
        }
      ) {
        nodes {
          contents {
            type { repr }
            json
          }
          timestamp
        }
      }
    }
  `;

  const result = await graphqlClient.query({
    query,
    variables: {
      type: '0x93f180cdf9fd66cb0479b63395e90c83c755898fc62a7f10a77c3a6b90e0af0b::event::CreatePoolEvent',
    },
  });

  const events = result.events?.nodes || [];
  const poolIds: string[] = [];

  for (const event of events) {
    const poolData = event.contents?.json;
    if (
      poolData?.coin_type_a === coinAType &&
      poolData?.coin_type_b === coinBType &&
      poolData?.bin_step === binStep &&
      poolData?.base_factor === baseFactor
    ) {
      // Filter by start time if provided
      if (startTime && event.timestamp) {
        if (new Date(event.timestamp) < new Date(startTime)) continue;
      }
      poolIds.push(poolData.pool_id);
    }
  }

  return poolIds;
}
```

### Query Pool by Token Pair and Fee

```typescript
// Query USDC/SUI pool with 0.3% fee and binStep=30
// Note: USDC (0xdba3...) has larger lexicographical order than SUI (0x2...)
const poolIds = await findPoolFromEvents(
  '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC', // coinAType (larger)
  '0x2::sui::SUI',                                                                       // coinBType (smaller)
  30,         // binStep
  '0.003',    // fee rate (0.3%)
);
// Returns: ['0x...pool_id']
```

## Available Fee Configurations

Common fee configurations in Cetus DLMM:

| Base Fee | Bin Step | Base Factor |
|----------|----------|-------------|
| 0.01%    | 1        | 10,000      |
| 0.02%    | 1        | 20,000      |
| 0.05%    | 5        | 10,000      |
| 0.10%    | 10       | 10,000      |
| 0.30%    | 30       | 10,000      |
| 0.60%    | 80       | 7,500       |
| 1.00%    | 100      | 10,000      |
| 2.00%    | 200      | 10,000      |

Formula: `fee = (baseFactor * binStep) / 1,000,000,000`
