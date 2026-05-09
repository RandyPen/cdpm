# Protocol Operations

> **Tip**: Protocol operations can read the `pool_id` from the PositionManager's `position` field instead of passing it as a parameter.

## Helper: Get Pool ID from PositionManager

```typescript
async function getPoolIdFromPositionManager(
  client: SuiGrpcClient,
  pmId: string
): Promise<string | null> {
  const { response: pm } = await client.getObject({
    id: pmId,
    include: { content: true },
  });
  
  // Read pool_id from PositionManager's position field
  return pm?.content?.fields?.position?.fields?.pool_id || null;
}
```

## Add Liquidity (Protocol)

```typescript
async function protocolAddLiquidity(
  client: SuiGrpcClient,
  signer: any,  // Must be in AccessList
  accessListId: string,
  pmId: string,
  poolId: string,  // Can be fetched from PositionManager
  amountA: bigint,
  amountB: bigint,
  bins: number[],
  amountsA: bigint[],
  amountsB: bigint[]
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::protocol_add_liquidity`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(accessListId),
      tx.object(pmId),
      tx.object(poolId),
      tx.pure.u64(amountA),
      tx.pure.u64(amountB),
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

// Example: Auto-fetch pool_id from PositionManager
async function protocolAddLiquidityAuto(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  pmId: string,
  amountA: bigint,
  amountB: bigint,
  bins: number[],
  amountsA: bigint[],
  amountsB: bigint[]
) {
  // Read pool_id from PositionManager's position field
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no associated pool');
  }
  
  return protocolAddLiquidity(
    client, signer, accessListId, pmId, poolId,
    amountA, amountB, bins, amountsA, amountsB
  );
}
```

## Collect Fees (Protocol)

```typescript
async function protocolCollectFees(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  feeHouseId: string,
  pmId: string,
  poolId: string  // Can be fetched from PositionManager
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::protocol_collect_fee`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(accessListId),
      tx.object(feeHouseId),
      tx.object(pmId),
      tx.object(poolId),
      tx.object(globalConfigId),
      tx.object(versionedId),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}

// Example: Auto-fetch pool_id from PositionManager
async function protocolCollectFeesAuto(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  feeHouseId: string,
  pmId: string
) {
  // Read pool_id from PositionManager's position field
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no associated pool');
  }
  
  return protocolCollectFees(
    client, signer, accessListId, feeHouseId, pmId, poolId
  );
}
```
