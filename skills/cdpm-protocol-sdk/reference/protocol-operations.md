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

## Remove Liquidity (Protocol)

> Signature keeps `clk: &Clock` because it is forwarded to `pool::remove_liquidity` in the Cetus DLMM SDK.

Removed assets are returned to the PositionManager's internal balance bag (not to the caller). Use `protocol_transfer_fee_to_balance` or other balance helpers to move funds afterward.

```typescript
async function protocolRemoveLiquidity(
  client: SuiGrpcClient,
  signer: any,  // Must be in AccessList
  accessListId: string,
  pmId: string,
  poolId: string,  // Can be fetched from PositionManager
  bins: number[],
  liquidityShares: bigint[]
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::protocol_remove_liquidity`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(accessListId),
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
```

## Transfer Fee to Balance (Protocol)

Move accumulated fee bag funds back into the PositionManager's balance bag so they can be used by subsequent protocol operations.

> Signature: `protocol_transfer_fee_to_balance<T>(access, pm, amount, ctx)` — **does not take Clock**.

The emitted `FeeTransferredToBalance.amount` reflects the actual coin value moved (which may be smaller than the requested `amount` when the fee bag holds less than requested).

```typescript
async function protocolTransferFeeToBalance(
  client: SuiGrpcClient,
  signer: any,  // Must be in AccessList
  accessListId: string,
  pmId: string,
  coinType: string,
  amount: bigint
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::protocol_transfer_fee_to_balance`,
    typeArguments: [coinType],
    arguments: [
      tx.object(accessListId),
      tx.object(pmId),
      tx.pure.u64(amount),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
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

## Scallop Lending (Supply / Redeem)

The Scallop hot-potato API is open to whitelisted protocol bots, but only when `pm.agents` is empty (the protocol-tier invariant). `assert_caller_authorized` inside `start_supply` / `start_redeem` lets the bot through under the union `is_owner || is_agent || (is_in_access_list && pm.agents.is_empty())`.

`finish_supply` / `finish_redeem` only verify `ticket.pm_id == object::id(pm)` — the auth check is done up front.

### Pre-flight: Accrue Interest First

cdpm reads Scallop's `balance_sheet` view-only inside `compute_expected_scoin` / `compute_expected_underlying`. If the reserve hasn't been accrued in this block, the prediction will exceed what `mint::mint` / `redeem::redeem` actually return, and `finish_*` aborts cleanly with `EAmountShortfall (1009)`. The fix is the same for every caller: run `accrue_interest_for_market` as the **first** PTB command.

### PTB Recipe — Protocol Supply

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::start_supply<T>(access, pm, market, amount)              → (coin_t, ticket)
3. protocol::mint::mint<T>(version, market, coin_t, clock)        → coin_market<T>
4. cdpm::finish_supply<T>(pm, ticket, coin_market)
```

```typescript
async function protocolSupplyToScallop(
  client: SuiGrpcClient,
  signer: any,                 // Must be in AccessList.allow
  accessListId: string,
  pmId: string,
  underlyingCoinType: string,
  amount: bigint,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${SCALLOP_PROTOCOL}::accrue_interest::accrue_interest_for_market`,
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.object('0x6'),
    ],
  });

  const [coinT, ticket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::start_supply`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(accessListId),
      tx.object(pmId),
      tx.object(SCALLOP_MARKET_ID),
      tx.pure.u64(amount),
    ],
  });

  const [coinMarket] = tx.moveCall({
    target: `${SCALLOP_PROTOCOL}::mint::mint`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      coinT,
      tx.object('0x6'),
    ],
  });

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::finish_supply`,
    typeArguments: [underlyingCoinType],
    arguments: [tx.object(pmId), ticket, coinMarket],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

### PTB Recipe — Protocol Redeem (Yield Fee Applies)

`finish_redeem` deducts `floor(max(0, redeemed − principal_portion) × fee_house.fee_rate / 10_000)` from the interest portion before adding the rest to `pm.balance[T]`. Protocol callers pay the same yield fee as owner / agent.

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::start_redeem<T>(access, pm, market, scoin_amount)            → (coin_market, ticket)
3. protocol::redeem::redeem<T>(version, market, coin_market, clock)   → coin_t
4. cdpm::finish_redeem<T>(pm, fee_house, ticket, coin_t)
```

```typescript
async function protocolRedeemFromScallop(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  feeHouseId: string,
  pmId: string,
  underlyingCoinType: string,
  scoinAmount: bigint,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${SCALLOP_PROTOCOL}::accrue_interest::accrue_interest_for_market`,
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.object('0x6'),
    ],
  });

  const [coinMarket, ticket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::start_redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(accessListId),
      tx.object(pmId),
      tx.object(SCALLOP_MARKET_ID),
      tx.pure.u64(scoinAmount),
    ],
  });

  const [coinT] = tx.moveCall({
    target: `${SCALLOP_PROTOCOL}::redeem::redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      coinMarket,
      tx.object('0x6'),
    ],
  });

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::finish_redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(pmId),
      tx.object(feeHouseId),
      ticket,
      coinT,
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

### Protocol Cannot Call `user_extract_market_coin`

`user_extract_market_coin<T>` aborts with `ENotOwner (1001)` for anyone other than `pm.owner`. Protocol bots cannot use the escape hatch — they must always go through the full Scallop redeem path.
