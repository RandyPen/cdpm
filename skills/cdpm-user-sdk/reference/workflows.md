# Creating Positions

## Contents

- [1. Create Position (First Time User)](#1-create-position-first-time-user)
- [2. Create Position (Existing User)](#2-create-position-existing-user)
- [3. Check if User Has Record](#3-check-if-user-has-record)
- [Close Position](#close-position)
- [Events](#events)

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

> **IMPORTANT — `user_close_pm` preconditions**
>
> `user_close_pm` is **dual-mode** depending on whether the PM currently holds
> a Cetus position (`position: Option<Position>`):
>
> - **`Some` (position active)** — the underlying Cetus position is closed
>   and the returned `Coin<CoinTypeA>` / `Coin<CoinTypeB>` are transferred to
>   the sender inside the call.
> - **`None` (position already destroyed, e.g. by `agent_destroy_position`)** —
>   no `pool::close_position` is executed; the PM is drained and closed as-is.
>
> In both modes the following preconditions apply (each surfaces as a cdpm
> error code, not a generic framework abort):
>
> - Every reward type on the pool has been collected via
>   `user_collect_reward<CoinTypeA, CoinTypeB, RewardType>` — otherwise
>   `EPositionHasRewards (1007)` fires (only relevant when `position` is
>   `Some`). `pool::close_position` (called internally) destroys any leftover
>   reward balances together with the `ClosePositionCert`, so calling close
>   without collecting first burns the rewards.
> - Every Scallop and Kai vault entry in `pm.lending` has been redeemed
>   — otherwise `ELendingNotEmpty (1004)` fires. The same `lending: Bag`
>   holds both `ScallopVault<T>` (key = `type_name<T>`) and
>   `KaiVault<T, YT>` (key = `type_name<YT>`); empty both flavors.
>   Use `scallop_redeem<T>` with `scoin_amount = u64::MAX` and
>   `kai_redeem<T, ST, YT>` with `yt_amount = u64::MAX` (each is one
>   `tx.moveCall`); see `reference/scallop-lending.md` and
>   `reference/kai-lending.md`.
> - `pm.balance` has been drained — otherwise `EBalanceNotEmpty (1008)`
>   fires. Withdraw every type with
>   `user_remove_liquidity_from_balance<T>(u64::MAX)`.
> - `pm.fee` has been drained — otherwise `EFeeNotEmpty (1009)` fires.
>   Withdraw every type with `user_withdraw_fee<T>(u64::MAX)`.

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

### Close Position Safely (collect rewards first)

The following variant sweeps every `RewardType` on the pool **before** closing, so no incentive rewards are lost. It also redeems every Scallop and Kai lending entry, drains every residual `pm.balance[T]` and `pm.fee[T]` (mandatory — `user_close_pm` asserts both bags empty), and emits **one** batched `transferObjects` at the end instead of one call per coin (each `transferObjects` is its own PTB command with its own base cost):

```typescript
async function closePositionSafe(
  client: SuiGrpcClient,
  signer: any,
  recordId: string,
  pmId: string,
  poolId: string,
  rewardCoinTypes: string[],  // e.g. ["0x2::sui::SUI", "0x...::rewardX::RewardX"]
  coinTypeA: string,
  coinTypeB: string,
  // Off-chain pre-scan of pm.lending, pm.balance, pm.fee dynamic-field keys.
  pmSnap: {
    scallopVaults: Array<{ T: string }>;
    kaiVaults: Array<{ T: string; ST: string; YT: string;
                       vaultId: string; strategyId: string; supplyPoolId: string }>;
    balance: Map<string, bigint>;
    fee: Map<string, bigint>;
  },
) {
  const tx = new Transaction();
  const REDEEM_ALL_U64 = 0xffffffffffffffffn;
  const toTransfer: TransactionObjectArgument[] = [];

  // Step 1: collect every reward type BEFORE close (otherwise EPositionHasRewards=1007).
  for (const rewardType of rewardCoinTypes) {
    const [rewardCoin] = tx.moveCall({
      target: `${CDPM_PACKAGE}::cdpm::user_collect_reward`,
      typeArguments: [coinTypeA, coinTypeB, rewardType],
      arguments: [
        tx.object(pmId),
        tx.object(poolId),
        tx.object(globalConfigId),
        tx.object(versionedId),
      ],
    });
    toTransfer.push(rewardCoin);
  }

  // Step 2: drain every Scallop lending entry (ScallopVault<T>).
  //         Net underlying lands in pm.balance[T] and is drained in Step 4.
  for (const v of pmSnap.scallopVaults) {
    tx.moveCall({
      target: `${CDPM_PACKAGE}::cdpm::scallop_redeem`,
      typeArguments: [v.T],
      arguments: [
        tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
        tx.object(pmId),
        tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
        tx.object(SCALLOP_VERSION_ID),
        tx.object(SCALLOP_MARKET_ID),
        tx.pure.u64(REDEEM_ALL_U64),
        tx.object('0x6'),
      ],
    });
  }

  // Step 3: drain every Kai lending entry (KaiVault<T, YT>).
  //         Net underlying lands in pm.balance[T] and is drained in Step 4.
  for (const v of pmSnap.kaiVaults) {
    tx.moveCall({
      target: `${CDPM_PACKAGE}::cdpm::kai_redeem`,
      typeArguments: [v.T, v.ST, v.YT],
      arguments: [
        tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
        tx.object(pmId),
        tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
        tx.object(v.vaultId),
        tx.object(v.strategyId),
        tx.object(v.supplyPoolId),
        tx.pure.u64(REDEEM_ALL_U64),
        tx.object('0x6'),
      ],
    });
  }

  // Step 4: drain every remaining bag key. Use REDEEM_ALL_U64 so the entry
  // is fully removed (amount >= entry_value → bag::remove, leaving an empty
  // bag — required by user_close_pm's EBalanceNotEmpty / EFeeNotEmpty checks).
  for (const T of pmSnap.balance.keys()) {
    const [coin] = tx.moveCall({
      target: `${CDPM_PACKAGE}::cdpm::user_remove_liquidity_from_balance`,
      typeArguments: [T],
      arguments: [tx.object(pmId), tx.pure.u64(REDEEM_ALL_U64)],
    });
    toTransfer.push(coin);
  }
  for (const T of pmSnap.fee.keys()) {
    const [coin] = tx.moveCall({
      target: `${CDPM_PACKAGE}::cdpm::user_withdraw_fee`,
      typeArguments: [T],
      arguments: [tx.object(pmId), tx.pure.u64(REDEEM_ALL_U64)],
    });
    toTransfer.push(coin);
  }

  // Step 5: close (consumes pm; asserts pm.balance / pm.fee / pm.lending all empty
  // and — when a position is still active — PositionInfo.rewards_owned all zero).
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_close_pm`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(recordId),
      tx.object(pmId),
      tx.object(poolId),
      tx.object(globalConfigId),
      tx.object(versionedId),
      tx.object(clockId),
    ],
  });

  // Step 6: ONE batched transfer for everything destined to the user.
  if (toTransfer.length > 0) {
    tx.transferObjects(toTransfer, signer.toSuiAddress());
  }

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

> The LP underlying (`Coin<CoinTypeA>` / `Coin<CoinTypeB>` from `pool::close_position`) is transferred to the sender **inside** `user_close_pm` via Move-side `transfer::public_transfer` — but only when `pm.position` is `Some`. If the PM's position was already destroyed (e.g. `agent_destroy_position` routed assets back to `pm.balance`, which Step 4 already drained), `user_close_pm` skips the Cetus close entirely. Those two coins therefore pass through `pm.balance` instead and are part of `toTransfer`.

## Return Record to GlobalRecord (`unregister_record`)

After closing every PositionManager owned by the user, the per-user
`Record` table is empty and can be returned to the `GlobalRecord`. This
frees the `address → ID` entry so the user can later `register_and_return_record`
again. The call aborts if `record.record` still tracks any PM.

```move
public fun unregister_record(global_record: &mut GlobalRecord, record: Record, ctx: &TxContext);
```

```typescript
async function unregisterRecord(
  client: SuiGrpcClient,
  signer: any,
  globalRecordId: string,
  recordId: string,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::unregister_record`,
    arguments: [
      tx.object(globalRecordId),  // shared
      tx.object(recordId),        // owned by sender; consumed
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Emits `RecordDeleted { record_id, owner }`.

## Events

### Monitor User Events

> Event timestamps are available on `SuiEvent.timestampMs`; the on-chain payload does not include a `timestamp` field. Sui event envelopes record the transaction sender — reach for `event.sender` if you need to distinguish owner / agent / protocol callers.

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
}

// Liquidity removed
interface LiquidityRemoved {
  pm_id: string;
  pool_id: string;
  bins: number[];
  liquidity_shares: string[];
  amount_a: string;   // Actual token A returned
  amount_b: string;   // Actual token B returned
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
