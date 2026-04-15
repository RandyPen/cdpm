# Agent Operations

> **Tip**: Agents can read the `pool_id` from the PositionManager's `position` field instead of passing it as a parameter. This ensures the correct pool is always used.

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

## Add Liquidity

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function agentAddLiquidity(
  client: SuiGrpcClient,
  signer: any,  // Agent's keypair
  pmId: string,
  poolId: string,  // Can be fetched from PositionManager
  amountA: bigint,  // Amount to withdraw from balance
  amountB: bigint,
  bins: number[],
  amountsA: bigint[],
  amountsB: bigint[]
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::agent_add_liquidity`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
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
async function agentAddLiquidityAuto(
  client: SuiGrpcClient,
  signer: any,
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
  
  return agentAddLiquidity(
    client, signer, pmId, poolId,
    amountA, amountB, bins, amountsA, amountsB
  );
}
```

## Remove Liquidity

```typescript
async function agentRemoveLiquidity(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  poolId: string,  // Can be fetched from PositionManager
  bins: number[],
  liquidityShares: bigint[]
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::agent_remove_liquidity`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(pmId),
      tx.object(poolId),
      tx.pure.vector('u32', bins),
      tx.pure.vector('u128', liquidityShares),
      tx.object(globalConfigId),
      tx.object(versionedId),
      tx.object(clockId),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}

// Example: Auto-fetch pool_id from PositionManager
async function agentRemoveLiquidityAuto(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  bins: number[],
  liquidityShares: bigint[]
) {
  // Read pool_id from PositionManager's position field
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no associated pool');
  }
  
  return agentRemoveLiquidity(
    client, signer, pmId, poolId,
    bins, liquidityShares
  );
}
```

## Collect Fees

```typescript
async function agentCollectFees(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  poolId: string  // Can be fetched from PositionManager
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::agent_collect_fee`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(pmId),
      tx.object(poolId),
      tx.object(globalConfigId),
      tx.object(versionedId),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}

// Example: Auto-fetch pool_id from PositionManager
async function agentCollectFeesAuto(
  client: SuiGrpcClient,
  signer: any,
  pmId: string
) {
  // Read pool_id from PositionManager's position field
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no associated pool');
  }
  
  return agentCollectFees(client, signer, pmId, poolId);
}
```

## Collect Rewards

```typescript
async function agentCollectRewards(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  poolId: string,
  rewardType: string
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::agent_collect_reward`,
    typeArguments: [coinTypeA, coinTypeB, rewardType],
    arguments: [
      tx.object(pmId),
      tx.object(poolId),
      tx.object(globalConfigId),
      tx.object(versionedId),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}

// Example: Auto-fetch pool_id from PositionManager
async function agentCollectRewardsAuto(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  rewardType: string
) {
  // Read pool_id from PositionManager's position field
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no associated pool');
  }
  
  return agentCollectRewards(client, signer, pmId, poolId, rewardType);
}
```

## Transfer Fee to Balance

```typescript
async function agentTransferFeeToBalance(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  coinType: string,
  amount: bigint
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::agent_transfer_fee_to_balance`,
    typeArguments: [coinType],
    arguments: [
      tx.object(pmId),
      tx.pure.u64(amount),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```
