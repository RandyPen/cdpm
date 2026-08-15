# Position Management

## Contents

- [Helper: Get Pool ID from PositionManager](#helper-get-pool-id-from-positionmanager)
- [Add Liquidity](#add-liquidity)
- [Remove Liquidity](#remove-liquidity)
- [Extract Position (for Cetus DLMM Package Upgrade)](#extract-position-for-cetus-dlmm-package-upgrade)
- [Balance Management](#balance-management)

## Helper: Get Pool ID from PositionManager

`pool_id` is a top-level field on `PositionManager` — it binds the PM to a
specific Cetus pool at creation time (`user_deposit_liquidity` /
`user_deposit_position`) and no longer lives inside the `position` field.
The `position` field itself is now `Option<Position>`: it is `null` when an
agent destroyed the position (`agent_destroy_position`) or when no position
has been created yet.

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
  const poolId = pm?.content?.fields?.pool_id;
  return poolId || null;
}

// Alternative using GraphQL
interface PositionManagerInfo {
  id: string;
  owner: string;
  pool_id: string;  // top-level: pool the PM is bound to
  position?: {      // Option<Position> — null if destroyed / never created
    id: string;
  };
  agents: string[];
  balance: Record<string, string>;
  fee: Record<string, string>;
  // Lending bag — holds both Scallop and Kai entries on the same PM.
  //   Scallop: key = type_name<T>, value = ScallopVault<T> { scoin: Balance<MarketCoin<T>>, principal: u64 }
  //   Kai SAV: key = type_name<YT>, value = KaiVault<T, YT> { yt_balance: Balance<YT>, principal: u64 }
  // The two value shapes are disambiguated by the bag entry's Move type tag, not the key.
  lending: Record<string, { scoin?: string; yt_balance?: string; principal: string }>;
}

async function getPositionManagerInfo(
  client: SuiGraphQLClient,
  pmId: string
): Promise<PositionManagerInfo | null> {
  const query = `
    query GetPositionManager($pmId: SuiAddress!) {
      object(address: $pmId) {
        address
        asMoveObject {
          contents {
            json
          }
        }
      }
    }
  `;
  
  const result = await client.query({
    query,
    variables: { pmId },
  });
  
  const pmData = result.object?.asMoveObject?.contents?.json;
  if (!pmData) return null;
  
  return {
    id: pmId,
    owner: pmData.owner,
    pool_id: pmData.pool_id,
    position: pmData.position ? {
      id: pmData.position.id,
    } : undefined,
    agents: pmData.agents || [],
    balance: pmData.balance || {},
    fee: pmData.fee || {},
    lending: pmData.lending || {},
  };
}

// Usage
const pmInfo = await getPositionManagerInfo(graphqlClient, pmId);
if (pmInfo?.pool_id) {
  console.log(`Pool ID: ${pmInfo.pool_id}`);
}
console.log(`Position active: ${Boolean(pmInfo?.position)}`);
```

## Add Liquidity

When adding liquidity, you can either:
- Pass the `poolId` directly (if you already know it)
- Or read it from the PositionManager's top-level `pool_id` field

```typescript
async function addLiquidity(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  poolId: string,  // Can be fetched from PositionManager if not provided
  coinA: string,
  coinB: string,
  bins: number[],
  amountsA: bigint[],
  amountsB: bigint[]
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_add_liquidity_to_position`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(pmId),
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

// Example: Add liquidity with poolId from PositionManager
async function addLiquidityWithAutoPoolId(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  coinA: string,
  coinB: string,
  bins: number[],
  amountsA: bigint[],
  amountsB: bigint[]
) {
  // Read pool_id from PositionManager
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no bound pool');
  }
  
  return addLiquidity(
    client, signer, pmId, poolId,
    coinA, coinB, bins, amountsA, amountsB
  );
}
```

## Remove Liquidity

Similarly, when removing liquidity:

```typescript
async function removeLiquidity(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  poolId: string,  // Can be fetched from PositionManager if not provided
  bins: number[],
  liquidityShares: bigint[]
) {
  const tx = new Transaction();
  
  const [coinA, coinB] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_remove_liquidity_from_position`,
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
  
  // Transfer returned coins to user
  tx.transferObjects([coinA, coinB], signer.getPublicKey().toSuiAddress());
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}

// Example: Remove liquidity with poolId from PositionManager
async function removeLiquidityWithAutoPoolId(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  bins: number[],
  liquidityShares: bigint[]
) {
  // Read pool_id from PositionManager
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no bound pool');
  }
  
  return removeLiquidity(
    client, signer, pmId, poolId,
    bins, liquidityShares
  );
}
```

## Wrap an Existing Position into a New PM

`user_deposit_position` wraps a `Position` object the caller already owns
(e.g. one obtained directly from a Cetus DLMM call) into a fresh
`PositionManager`. The owner is set to `ctx.sender()`, the `pool_id` is read
from the wrapped `Position` (`position::pool_id`), the `position` field is
filled with `option::some(position)`, and all three bags (`balance`, `fee`,
`lending`) start empty.

```move
public fun user_deposit_position(record: &mut Record, position: Position, ctx: &mut TxContext);
```

```typescript
async function depositPosition(
  client: SuiGrpcClient,
  signer: any,
  recordId: string,
  positionId: string,        // Position object owned by caller
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_deposit_position`,
    arguments: [
      tx.object(recordId),     // mut: PM ID is added to record.record table
      tx.object(positionId),   // owned by sender; consumed
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Emits `PositionManagerCreated { pm_id, owner, pool_id, lower_bin_id, upper_bin_id, liquidity_shares }`.

## Balance Management

### Deposit to Balance

```typescript
async function depositToBalance(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  coin: string,  // Coin object ID
  coinType: string
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_add_liquidity_to_balance`,
    typeArguments: [coinType],
    arguments: [
      tx.object(pmId),
      tx.object(coin),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

### Withdraw from Balance

```typescript
async function withdrawFromBalance(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  coinType: string,
  amount: bigint
) {
  const tx = new Transaction();
  
  const [coin] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_remove_liquidity_from_balance`,
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
