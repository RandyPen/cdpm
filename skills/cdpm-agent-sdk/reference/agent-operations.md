# Agent Operations

## Contents

- [Helper: Get Pool ID from PositionManager](#helper-get-pool-id-from-positionmanager)
- [Create Position (Position Lifecycle)](#create-position-position-lifecycle)
- [Destroy Position (Position Lifecycle)](#destroy-position-position-lifecycle)
- [Add Liquidity](#add-liquidity)
- [Remove Liquidity](#remove-liquidity)
- [Collect Fees](#collect-fees)
- [Collect Rewards](#collect-rewards)
- [Transfer Fee to Balance](#transfer-fee-to-balance)

## Helper: Get Pool ID from PositionManager

`pool_id` is a top-level field on `PositionManager` (it binds the PM to a
specific Cetus pool and no longer lives inside the `position` field):

```typescript
async function getPoolIdFromPositionManager(
  client: SuiGrpcClient,
  pmId: string
): Promise<string | null> {
  const { response: pm } = await client.getObject({
    id: pmId,
    include: { content: true },
  });
  
  // pool_id is a top-level field on PositionManager
  return pm?.content?.fields?.pool_id || null;
}
```

## Create Position (Position Lifecycle)

`agent_create_position` opens a fresh Cetus position from `pm.balance`. It
asserts the PM currently holds **no** position (`EPositionAlreadyExists`,
1010), that the passed pool matches the PM's bound `pool_id` (`EWrongPool`,
1012), and that the caller is in `pm.agents` (`ENotAllow`, 1002). Unused coin
remainder is returned to `pm.balance`.

```typescript
async function agentCreatePosition(
  client: SuiGrpcClient,
  signer: any,  // Agent's keypair
  pmId: string,
  poolId: string,  // Must equal PositionManager.pool_id
  bins: number[],
  amountsA: bigint[],
  amountsB: bigint[]
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::agent_create_position`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(pmId),
      tx.object(poolId),
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

// Example: Auto-fetch pool_id from PositionManager top-level field
async function agentCreatePositionAuto(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  bins: number[],
  amountsA: bigint[],
  amountsB: bigint[]
) {
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no bound pool');
  }
  
  return agentCreatePosition(
    client, signer, pmId, poolId, bins, amountsA, amountsB
  );
}
```

Emits `AgentPositionCreated { pm_id, pool_id, lower_bin_id, upper_bin_id, liquidity_shares }`.

## Destroy Position (Position Lifecycle)

`agent_destroy_position` closes the Cetus position and routes the underlying
assets back into `pm.balance`. It asserts the PM currently holds a position
(`ENoPosition`, 1011), that all Cetus rewards have been collected first
(`EPositionHasRewards`, 1007), and that the caller is in `pm.agents`
(`ENotAllow`, 1002).

```typescript
async function agentDestroyPosition(
  client: SuiGrpcClient,
  signer: any,  // Agent's keypair
  pmId: string,
  poolId: string  // Must equal PositionManager.pool_id
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::agent_destroy_position`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(pmId),
      tx.object(poolId),
      tx.object(globalConfigId),
      tx.object(versionedId),
      tx.object(clockId),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}

// Example: Auto-fetch pool_id from PositionManager top-level field
async function agentDestroyPositionAuto(
  client: SuiGrpcClient,
  signer: any,
  pmId: string
) {
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no bound pool');
  }
  
  return agentDestroyPosition(client, signer, pmId, poolId);
}
```

Emits `AgentPositionDestroyed { pm_id, pool_id, coin_type_a, coin_type_b, amount_a, amount_b }`.

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
  // Read pool_id from PositionManager (top-level field)
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no bound pool');
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
  // Read pool_id from PositionManager (top-level field)
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no bound pool');
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
  // Read pool_id from PositionManager (top-level field)
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no bound pool');
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
  // Read pool_id from PositionManager (top-level field)
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no bound pool');
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

For Scallop and Kai lending recipes (`scallop_supply` / `scallop_redeem`, `kai_supply` / `kai_redeem`), see [`scallop-lending.md`](./scallop-lending.md) and [`kai-lending.md`](./kai-lending.md).
