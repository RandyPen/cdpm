# Protocol Operations

## Contents

- [Helper: Get Pool ID from PositionManager](#helper-get-pool-id-from-positionmanager)
- [Add Liquidity (Protocol)](#add-liquidity-protocol)
- [Remove Liquidity (Protocol)](#remove-liquidity-protocol)
- [Collect Fees (Protocol)](#collect-fees-protocol)
- [Collect Reward (Protocol)](#collect-reward-protocol)
- [Transfer Fee to Balance (Protocol)](#transfer-fee-to-balance-protocol)
- [Scallop Lending (Supply / Redeem)](#scallop-lending-supply--redeem)
- [Kai SAV Lending (Supply / Redeem)](#kai-sav-lending-supply--redeem)

## Helper: Get Pool ID from PositionManager

`pool_id` is a top-level field on `PositionManager` (binds the PM to its Cetus pool; no longer nested in `position`):

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

## Add Liquidity (Protocol)

Pulls `amount_a` of `CoinTypeA` and `amount_b` of `CoinTypeB` from `pm.balance`, calls `pool::add_liquidity` plus `pool::repay_add_liquidity`, and returns the unused remainder to `pm.balance`. Caller must be in `AccessList.allow` and `pm.agents` must be empty.

Signature:

```move
public fun protocol_add_liquidity<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    amount_a: u64,
    amount_b: u64,
    bins: vector<u32>,
    amounts_a: vector<u64>,
    amounts_b: vector<u64>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
);
```

```typescript
async function protocolAddLiquidity(
  client: SuiGrpcClient,
  signer: any,            // Must be in AccessList.allow
  accessListId: string,
  pmId: string,
  poolId: string,
  coinTypeA: string,
  coinTypeB: string,
  amountA: bigint,
  amountB: bigint,
  bins: number[],
  amountsA: bigint[],
  amountsB: bigint[],
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
      tx.object(CETUS_GLOBAL_CONFIG_ID),
      tx.object(CETUS_VERSIONED_ID),
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Emits `ProtocolLiquidityAdded { pm_id, pool_id, bins, amount_a, amount_b }` where the amounts are the values actually consumed by the pool (post-clamp).

## Remove Liquidity (Protocol)

Removes liquidity from the underlying Cetus position and routes the resulting `Coin<A>` / `Coin<B>` to `pm.balance`. Use `protocol_transfer_fee_to_balance` afterwards to surface accumulated fees, or pair with `protocol_collect_fee` first.

Signature:

```move
public fun protocol_remove_liquidity<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    bins: vector<u32>,
    liquidity_shares: vector<u128>,
    config: &GlobalConfig,
    versioned: &Versioned,
    clk: &Clock,
    ctx: &mut TxContext,
);
```

```typescript
async function protocolRemoveLiquidity(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  pmId: string,
  poolId: string,
  coinTypeA: string,
  coinTypeB: string,
  bins: number[],
  liquidityShares: bigint[],
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
      tx.object(CETUS_GLOBAL_CONFIG_ID),
      tx.object(CETUS_VERSIONED_ID),
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Emits `ProtocolLiquidityRemoved { pm_id, pool_id, bins, liquidity_shares, amount_a, amount_b }`.

## Collect Fees (Protocol)

Calls `pool::collect_position_fee`, splits each side via `take_fee` — `fee_a = floor(gross_a × fee_house.fee_rate / 10_000)` to `fee_house.fee[CoinTypeA]`, remainder to `pm.fee[CoinTypeA]`; same for `CoinTypeB`.

Signature:

```move
public fun protocol_collect_fee<CoinTypeA, CoinTypeB>(
    access: &AccessList,
    fee_house: &mut FeeHouse,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
);
```

```typescript
async function protocolCollectFees(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  feeHouseId: string,
  pmId: string,
  poolId: string,
  coinTypeA: string,
  coinTypeB: string,
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
      tx.object(CETUS_GLOBAL_CONFIG_ID),
      tx.object(CETUS_VERSIONED_ID),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Emits `ProtocolFeeCollected { pm_id, pool_id, coin_type_a, coin_type_b, amount_a, amount_b, fee_a, fee_b }`.

## Collect Reward (Protocol)

Calls `pool::collect_position_reward<CoinTypeA, CoinTypeB, RewardType>`, applies the same `take_fee` split — `fee_amount = floor(gross × fee_house.fee_rate / 10_000)` to `fee_house.fee[RewardType]`, remainder to `pm.fee[RewardType]`.

Signature:

```move
public fun protocol_collect_reward<CoinTypeA, CoinTypeB, RewardType>(
    access: &AccessList,
    fee_house: &mut FeeHouse,
    pm: &mut PositionManager,
    pool: &mut Pool<CoinTypeA, CoinTypeB>,
    config: &GlobalConfig,
    versioned: &Versioned,
    ctx: &mut TxContext,
);
```

```typescript
async function protocolCollectReward(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  feeHouseId: string,
  pmId: string,
  poolId: string,
  coinTypeA: string,
  coinTypeB: string,
  rewardType: string,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::protocol_collect_reward`,
    typeArguments: [coinTypeA, coinTypeB, rewardType],
    arguments: [
      tx.object(accessListId),
      tx.object(feeHouseId),
      tx.object(pmId),
      tx.object(poolId),
      tx.object(CETUS_GLOBAL_CONFIG_ID),
      tx.object(CETUS_VERSIONED_ID),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Emits `ProtocolRewardCollected { pm_id, pool_id, coin_type, amount, fee_amount }` where `coin_type = type_name<RewardType>`.

## Transfer Fee to Balance (Protocol)

Move accumulated `pm.fee[T]` funds into `pm.balance[T]` so they can be consumed by subsequent protocol operations (e.g. compounding into Scallop / Kai).

Signature:

```move
public fun protocol_transfer_fee_to_balance<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    amount: u64,
    ctx: &mut TxContext,
);
```

The internal `withdraw_from_fee<T>` clamps `amount` to the live `pm.fee[T]` value, so passing `u64::MAX` drains the entire entry. The emitted `FeeTransferredToBalance.amount` reflects the post-clamp value actually moved.

```typescript
async function protocolTransferFeeToBalance(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  pmId: string,
  coinType: string,
  amount: bigint,
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

Emits `FeeTransferredToBalance { pm_id, coin_type, amount }`.

## Scallop Lending (Supply / Redeem)

`scallop_supply<T>` and `scallop_redeem<T>` are each one `tx.moveCall`. cdpm runs `protocol::mint::mint` / `protocol::redeem::redeem` internally, then re-deposits the result back into the PM. Caller authorization is the union `owner || agent || (in AccessList AND pm.agents.is_empty())`. See [`scallop-lending.md`](./scallop-lending.md) for the full Scallop reference (sizing helpers, snapshot reads, error handling).

Signatures:

```move
public fun scallop_supply<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    version: &ScallopVersion,
    market: &mut Market,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun scallop_redeem<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    version: &ScallopVersion,
    market: &mut Market,
    scoin_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);
```

`scoin_amount = u64::MAX` drains the `ScallopVault<T>` entry from `pm.lending`.

```typescript
async function protocolSupplyToScallop(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  pmId: string,
  underlyingCoinType: string,
  amount: bigint,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::scallop_supply`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(accessListId),
      tx.object(pmId),
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.pure.u64(amount),
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}

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
    target: `${CDPM_PACKAGE}::cdpm::scallop_redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(accessListId),
      tx.object(pmId),
      tx.object(feeHouseId),
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.pure.u64(scoinAmount),
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

`scallop_supply` emits `ScallopSupplied`. `scallop_redeem` emits `ScallopRedeemed` and routes `fee_amount = floor(interest × fee_house.fee_rate / 10_000)` into `fee_house.fee[T]`.

## Kai SAV Lending (Supply / Redeem)

`kai_supply<T, YT>` and `kai_redeem<T, ST, YT>` are each one `tx.moveCall`. `kai_redeem` is generic over the supply-pool strategy `<T, ST>` because cdpm walks `kai_vault::withdraw → klsp::withdraw → kai_vault::redeem_withdraw_ticket` internally. See [`kai-lending.md`](./kai-lending.md) for the full Kai reference.

Signatures:

```move
public fun kai_supply<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &mut kai_vault::Vault<T, YT>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun kai_redeem<T, ST, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    vault: &mut kai_vault::Vault<T, YT>,
    strategy: &mut klsp::Strategy<T, ST>,
    supply_pool: &mut SupplyPool<T, ST>,
    yt_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);
```

`yt_amount = u64::MAX` drains the `KaiVault<T, YT>` entry from `pm.lending`.

```typescript
async function protocolSupplyToKai(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  pmId: string,
  underlyingCoinType: string,
  ytCoinType: string,
  vaultObjectId: string,
  amount: bigint,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_supply`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [
      tx.object(accessListId),
      tx.object(pmId),
      tx.object(vaultObjectId),
      tx.pure.u64(amount),
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}

async function protocolRedeemFromKai(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  feeHouseId: string,
  pmId: string,
  underlyingCoinType: string,
  stCoinType: string,
  ytCoinType: string,
  vaultObjectId: string,
  strategyObjectId: string,
  supplyPoolObjectId: string,
  ytAmount: bigint,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_redeem`,
    typeArguments: [underlyingCoinType, stCoinType, ytCoinType],
    arguments: [
      tx.object(accessListId),
      tx.object(pmId),
      tx.object(feeHouseId),
      tx.object(vaultObjectId),
      tx.object(strategyObjectId),
      tx.object(supplyPoolObjectId),
      tx.pure.u64(ytAmount),
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

`kai_supply` emits `KaiSupplied`. `kai_redeem` emits `KaiRedeemed` and routes `fee_amount = floor(interest × fee_house.fee_rate / 10_000)` into `fee_house.fee[T]`.
