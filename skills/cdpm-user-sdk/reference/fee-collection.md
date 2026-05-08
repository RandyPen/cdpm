# Fee Collection

## Collect Fees

```typescript
async function collectFees(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  poolId: string
) {
  const tx = new Transaction();
  
  const [coinA, coinB] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_collect_fee`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(pmId),
      tx.object(poolId),
      tx.object(globalConfigId),
      tx.object(versionedId),
      tx.object(clockId),
    ],
  });
  
  // Transfer to user
  tx.transferObjects([coinA, coinB], signer.getPublicKey().toSuiAddress());
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## Collect Rewards

```typescript
async function collectRewards(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  poolId: string,
  rewardType: string
) {
  const tx = new Transaction();
  
  const [reward] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_collect_reward`,
    typeArguments: [coinTypeA, coinTypeB, rewardType],
    arguments: [
      tx.object(pmId),
      tx.object(poolId),
      tx.object(globalConfigId),
      tx.object(versionedId),
      tx.object(clockId),
    ],
  });
  
  tx.transferObjects([reward], signer.getPublicKey().toSuiAddress());
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## Withdraw from Fee Bag

```typescript
async function withdrawFromFeeBag(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  coinType: string,
  amount: bigint
) {
  const tx = new Transaction();
  
  const [coin] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_withdraw_fee`,
    typeArguments: [coinType],
    arguments: [
      tx.object(pmId),
      tx.pure.u64(amount),
    ],
  });
  
  tx.transferObjects([coin], signer.getPublicKey().toSuiAddress());
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## Fee Events

```typescript
// Fees collected
interface FeeCollected {
  pm_id: string;
  pool_id: string;
  coin_type_a: string;
  coin_type_b: string;
  amount_a: string;
  amount_b: string;
  by: string;
  timestamp: number;
}

// Subscribe to fee events
const unsubscribe = await client.subscribeEvent({
  filter: {
    MoveEventType: `${CDPM_PACKAGE}::cdpm::FeeCollected`,
  },
  onMessage: (event) => {
    console.log('Fees collected:', event.parsedJson);
  },
});
```

## Fee Collection Strategy

### When to Collect

1. **Threshold-based** - Collect when fees exceed a certain amount
2. **Time-based** - Collect on a regular schedule
3. **Gas-optimized** - Collect only when gas costs < fees

```typescript
// Threshold-based collection
async function shouldCollectFees(
  client: SuiGrpcClient,
  pmId: string,
  threshold: bigint
): Promise<boolean> {
  const { response: pm } = await client.getObject({
    id: pmId,
    include: { content: true },
  });
  
  const feeBag = pm?.content?.fields?.fee;
  if (!feeBag) return false;
  
  // Check if any fee exceeds threshold
  for (const [coinType, amount] of Object.entries(feeBag)) {
    if (BigInt(amount as string) >= threshold) {
      return true;
    }
  }
  
  return false;
}
```
