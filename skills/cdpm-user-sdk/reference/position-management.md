# Position Management

## Helper: Get Pool ID from PositionManager

When working with a PositionManager, you can read the associated pool ID from its `position` field:

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
  const poolId = pm?.content?.fields?.position?.fields?.pool_id;
  return poolId || null;
}

// Alternative using GraphQL
interface PositionManagerInfo {
  id: string;
  owner: string;
  position?: {
    id: string;
    poolId: string;
  };
  agents: string[];
  balance: Record<string, string>;
  fee: Record<string, string>;
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
    position: pmData.position ? {
      id: pmData.position.id,
      poolId: pmData.position.pool_id,
    } : undefined,
    agents: pmData.agents || [],
    balance: pmData.balance || {},
    fee: pmData.fee || {},
  };
}

// Usage
const pmInfo = await getPositionManagerInfo(graphqlClient, pmId);
if (pmInfo?.position?.poolId) {
  console.log(`Pool ID: ${pmInfo.position.poolId}`);
}
```

## Add Liquidity

When adding liquidity, you can either:
- Pass the `poolId` directly (if you already know it)
- Or read it from the PositionManager's `position` field

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
    throw new Error('PositionManager has no associated pool');
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
    throw new Error('PositionManager has no associated pool');
  }
  
  return removeLiquidity(
    client, signer, pmId, poolId,
    bins, liquidityShares
  );
}
```

## Extract Position (for Cetus DLMM Package Upgrade)

In case of a Cetus DLMM package upgrade, the owner can extract the underlying `Position` from the PositionManager. The PositionManager retains its identity and balance/fee bags but its `position` field becomes `None` until a new Position is deposited (e.g. via `user_deposit_position`).

> Signature: `user_get_position(pm: &mut PositionManager, ctx: &TxContext)` — **does not take Clock**.

```typescript
async function getPosition(
  client: SuiGrpcClient,
  signer: any,
  pmId: string
) {
  const tx = new Transaction();

  // Position is transferred directly to ctx.sender() inside Move
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_get_position`,
    arguments: [
      tx.object(pmId),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}

// Variant: get the Position back as a PTB result for further composition
async function getAndReturnPosition(
  client: SuiGrpcClient,
  signer: any,
  pmId: string
) {
  const tx = new Transaction();

  const [position] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_get_and_return_position`,
    arguments: [
      tx.object(pmId),
    ],
  });

  // ... use `position` in subsequent moveCalls, e.g. transfer or re-deposit
  tx.transferObjects([position], signer.getPublicKey().toSuiAddress());

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

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
