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

## Scallop Lending (Supply / Redeem Idle Balance)

cdpm exposes a hot-potato lending API shared by owner / agent / whitelisted protocol bots. Authorization is decided in `assert_caller_authorized` inside `start_supply` and `start_redeem`: agents pass when their address is in `pm.agents`. `finish_supply` / `finish_redeem` only check `ticket.pm_id == object::id(pm)`.

### Constraints Agents Should Know

- **(T, S) is one-to-one**: `pm.lending` keys on the underlying `T` only. If a vault `<T, S1>` already exists, calling `start_supply<T, S2>` aborts at `dynamic_field::EFieldTypeMismatch`. Switching `S` requires draining the existing vault first — and only the **owner** can drain via the `user_extract_market_coin` escape hatch, so agents that need to switch should redeem fully first.
- **Yield fee applies to agents**: `finish_redeem` computes `fee_amount = floor(max(0, redeemed − principal_portion) × fee_house.fee_rate / 10_000)` regardless of caller, so agent redeems pay the same yield fee as owner / protocol redeems.
- **Owner-only**: `user_extract_market_coin<T, S>` aborts with `ENotOwner (1001)` for agents. If Scallop is unreachable, only the owner can rescue raw sCoin.

### PTB Recipe — Agent Supply

The first command of any supply PTB **MUST** be `protocol::accrue_interest::accrue_interest_for_market`. cdpm reads `balance_sheet` view-only; without a fresh accrual the predicted `expected_scoin` exceeds what Scallop actually mints, and `finish_supply` aborts with `EAmountShortfall (1009)`.

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::start_supply<T, S>(access, pm, market, amount)        → (coin_t, ticket)
3. protocol::mint::mint<T>(version, market, coin_t, clock)     → coin_s
4. cdpm::finish_supply<T, S>(pm, ticket, coin_s)
```

```typescript
async function agentSupplyToScallop(
  client: SuiGrpcClient,
  signer: any,           // Agent keypair
  pmId: string,
  underlyingCoinType: string,
  scoinType: string,
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
    typeArguments: [underlyingCoinType, scoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(SCALLOP_MARKET_ID),
      tx.pure.u64(amount),
    ],
  });

  const [coinS] = tx.moveCall({
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
    typeArguments: [underlyingCoinType, scoinType],
    arguments: [tx.object(pmId), ticket, coinS],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

### PTB Recipe — Agent Redeem

Same accrual-first rule. Net underlying (after yield fee) lands back in `pm.balance[T]`.

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::start_redeem<T, S>(access, pm, market, scoin_amount)         → (coin_s, ticket)
3. protocol::redeem::redeem<T>(version, market, coin_s, clock)        → coin_t
4. cdpm::finish_redeem<T, S>(pm, fee_house, ticket, coin_t)
```

```typescript
async function agentRedeemFromScallop(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  underlyingCoinType: string,
  scoinType: string,
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

  const [coinS, ticket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::start_redeem`,
    typeArguments: [underlyingCoinType, scoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
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
      coinS,
      tx.object('0x6'),
    ],
  });

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::finish_redeem`,
    typeArguments: [underlyingCoinType, scoinType],
    arguments: [
      tx.object(pmId),
      tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
      ticket,
      coinT,
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

### Tickets Are Hot Potatoes

`SupplyTicket<T, S>` and `RedeemTicket<T, S>` have **no `drop` ability** — the only way to discharge them is via the matching `finish_*` call inside the same PTB. If your strategy chains conditional commands, never branch the ticket out of the success path.
