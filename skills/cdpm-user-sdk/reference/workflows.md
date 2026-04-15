# Creating Positions

## 1. Create Position (First Time User)

For first-time users without a Record, create Record and PositionManager in the same PTB:

```typescript
async function createPositionWithNewRecord(
  client: SuiGrpcClient,
  signer: any,
  poolId: string,
  coinA: string, // Coin object ID for token A
  coinB: string, // Coin object ID for token B
  bins: number[],
  amountsA: bigint[],
  amountsB: bigint[]
) {
  const tx = new Transaction();
  
  // Step 1: Create Record (only for first-time users)
  const [record] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::register_and_return_record`,
    arguments: [
      tx.object(globalRecordId), // GlobalRecord shared object
    ],
  });
  
  // Step 2: Create PositionManager with initial liquidity
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_deposit_liquidity`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      record,                    // Record created above
      tx.object(poolId),         // Cetus DLMM Pool
      tx.object(coinA),          // Coin A object
      tx.object(coinB),          // Coin B object
      tx.pure.vector('u32', bins),
      tx.pure.vector('u64', amountsA),
      tx.pure.vector('u64', amountsB),
      tx.object(globalConfigId), // Cetus GlobalConfig
      tx.object(versionedId),    // Cetus Versioned
      tx.object(clockId),        // Clock
    ],
  });
  
  // Step 3: Transfer the Record to sender
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::transfer_record`,
    arguments: [record],
  });
  
  const result = await client.signAndExecuteTransaction({
    signer,
    transaction: tx,
  });
  
  return result;
}
```

## 2. Create Position (Existing User)

For users who already have a Record:

```typescript
async function createPositionWithExistingRecord(
  client: SuiGrpcClient,
  signer: any,
  recordId: string,            // User's existing Record
  poolId: string,
  coinA: string,
  coinB: string,
  bins: number[],
  amountsA: bigint[],
  amountsB: bigint[]
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_deposit_liquidity`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(recordId),       // Existing Record
      tx.object(poolId),
      tx.object(coinA),
      tx.object(coinB),
      tx.pure.vector('u32', bins),
      tx.pure.vector('u64', amountsA),
      tx.pure.vector('u64', amountsB),
      tx.object(globalConfigId),
      tx.object(versionedId),
      tx.object(clockId),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## 3. Check if User Has Record

Before creating a position, check if the user already has a Record:

```typescript
async function getUserRecordId(
  client: SuiGrpcClient,
  userAddress: string
): Promise<string | null> {
  try {
    // Query owned objects with Record type
    const records = await client.listOwnedObjects({
      owner: userAddress,
      filter: {
        StructType: `${CDPM_PACKAGE}::cdpm::Record`,
      },
      include: { content: false },
    });

    // Return the first Record object ID if exists
    if (records.objects && records.objects.length > 0) {
      return records.objects[0].data?.objectId || null;
    }
    return null;
  } catch (e) {
    return null;
  }
}

// Usage
async function createPositionSmart(
  client: SuiGrpcClient,
  signer: any,
  userAddress: string,
  // ... other params
) {
  const existingRecordId = await getUserRecordId(client, userAddress);
  
  if (existingRecordId) {
    return createPositionWithExistingRecord(client, signer, existingRecordId, /* ... */);
  } else {
    return createPositionWithNewRecord(client, signer, /* ... */);
  }
}
```

## Close Position

```typescript
async function closePosition(
  client: SuiGrpcClient,
  signer: any,
  recordId: string,
  pmId: string,
  poolId: string
) {
  const tx = new Transaction();
  
  // Note: pm is passed by value (consumed)
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_close_pm`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(recordId),
      tx.object(pmId),        // PositionManager (will be consumed)
      tx.object(poolId),
      tx.object(globalConfigId),
      tx.object(versionedId),
      tx.object(clockId),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## Events

### Monitor User Events

> Event timestamps are available on `SuiEvent.timestampMs`; the on-chain payload no longer includes a `timestamp` field.

```typescript
// Position created
interface PositionManagerCreated {
  pm_id: string;
  owner: string;
  pool_id: string;
  lower_bin_id: { bits: number };
  upper_bin_id: { bits: number };
  liquidity_shares: string[];
}

// Liquidity added (scalar actual amounts consumed by the pool)
interface LiquidityAdded {
  pm_id: string;
  pool_id: string;
  bins: number[];
  amount_a: string;  // Actual amount A consumed
  amount_b: string;  // Actual amount B consumed
  by: string;
}

// Subscribe to events
const unsubscribe = await client.subscribeEvent({
  filter: {
    MoveModule: {
      package: CDPM_PACKAGE,
      module: 'cdpm',
    },
  },
  onMessage: (event) => {
    console.log('Event:', event);
  },
});
```
