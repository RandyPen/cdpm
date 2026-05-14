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

> **IMPORTANT — reward safety**
> `pool::close_position` (used internally by `user_close_pm`) only returns
> underlying tokens and accumulated trading fees. Any **incentive reward
> tokens** still held by the position will be destroyed together with the
> `ClosePositionCert`. Because the contract itself doesn't know which
> `RewardType`s a pool has, you MUST construct a PTB that first calls
> `user_collect_reward<CoinTypeA, CoinTypeB, RewardType>` once for each
> reward token on that pool (typically 1-3 types), then `user_close_pm`
> in the same transaction.

> **IMPORTANT — lending bag must be empty (Scallop AND Kai)**
> `user_close_pm` asserts `bag::is_empty(&pm.lending)` and aborts with
> `ELendingNotEmpty (1004)` otherwise. The same `lending: Bag` holds both
> Scallop `ScallopVault<T>` entries (key = `type_name<T>`) and Kai SAV
> `KaiVault<T, YT>` entries (key = `type_name<YT>`); every entry of either
> flavor must be drained before close. cdpm exposes **no** wrapper-extract
> escape (no `user_extract_scallop_market_coin`, no `user_extract_kai_yt`);
> the only exit path is the full redeem flow. For Scallop, run
> `accrue_interest::accrue_interest_for_market → scallop_start_redeem →
> redeem::redeem → scallop_finish_redeem` followed by
> `user_remove_liquidity_from_balance<T>`. For Kai, run `kai_start_redeem →
> vault::withdraw → strategy walk → redeem_withdraw_ticket →
> kai_finish_redeem` followed by `user_remove_liquidity_from_balance<T>`.
> See `reference/scallop-lending.md` and `reference/kai-lending.md` for
> the full recipes.
>
> **IMPORTANT — full-drain top-up required (Kai; defensive for Scallop)**
> Each `*_finish_redeem` asserts `redeemed_amount >= expected_underlying`.
> For Kai, the upstream redeem chain applies per-strategy floor-div,
> returning ~2-3 raw underlying less than predicted; on a full drain
> (`amount = u64::MAX`) the assert reliably trips with `EAmountShortfall
> (1009)`. Scallop's upstream uses the same single floor-div formula as
> cdpm, so it has no observed dust — but the close-PM PTB shares its
> shape with the Kai branch for uniformity. In both cases the close-PM
> PTB MUST insert `0x2::coin::join(coinT, topup)` between the redeem
> chain and `*_finish_redeem`, where `topup` is a small `Coin<T>`
> (~30 raw underlying, recommended client-side default). **Source the
> topup via a three-tier resolver**: `pm.balance[T]` (via
> `user_remove_liquidity_from_balance<T>`) first, then `pm.fee[T]` (via
> `user_withdraw_fee<T>`), then the user's wallet (`tx.gas` for SUI,
> else `getCoins → mergeCoins → splitCoins`). Only throw a clear error
> when **all three tiers** are empty so the UI can prompt the user to
> acquire a dust amount before retry — in practice rare, since `pm.balance[T]`
> usually carries residual LP fees by the time close-PM runs. See
> `reference/kai-lending.md` § Top-Up Pattern for the `resolveTopup`
> helper and the full MoveCall sequence — that recipe stands on its own;
> no external reference implementation is required to copy.

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

The following variant sweeps every `RewardType` on the pool **before** closing, so no incentive rewards are lost. It also drains every residual `pm.balance[T]` and `pm.fee[T]` (mandatory — `user_close_pm` calls `destroy_empty` on both bags) and emits **one** batched `transferObjects` at the end instead of one call per coin (each `transferObjects` is its own PTB command with its own base cost):

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
  // Off-chain pre-scan of pm.balance and pm.fee dynamic-field keys + values.
  // The same scan feeds resolveTopup (see kai-lending.md § Top-Up Pattern).
  pmSnap: { balance: Map<string, bigint>; fee: Map<string, bigint> },
) {
  const tx = new Transaction();
  const REDEEM_ALL_U64 = 0xffffffffffffffffn;
  const toTransfer: TransactionObjectArgument[] = [];

  // Step 1: collect every reward type BEFORE close
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

  // Step 2: (if any lending entries) run *_finish_redeem flows here.
  // The top-up between each *_start_redeem and *_finish_redeem is sourced
  // through the three-tier resolver (pm.balance[T] → pm.fee[T] → wallet) —
  // see kai-lending.md § Top-Up Pattern. Topup-split handles are consumed
  // by coin::join and MUST NOT enter toTransfer. The post-finish underlying
  // lands back in pm.balance[T] and is drained by Step 3.

  // Step 3: drain every remaining bag key. Use REDEEM_ALL_U64 so the entry
  // is fully removed (amount >= entry_value → bag::remove, leaving an empty
  // bag for user_close_pm's destroy_empty).
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

  // Step 4: close (consumes pm; bag::destroy_empty asserts both bags are empty)
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

  // Step 5: ONE batched transfer for everything destined to the user.
  if (toTransfer.length > 0) {
    tx.transferObjects(toTransfer, signer.toSuiAddress());
  }

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

> The LP underlying (`Coin<CoinTypeA>` / `Coin<CoinTypeB>` from `pool::close_position`) is transferred to the sender **inside** `user_close_pm` via Move-side `transfer::public_transfer` — those two coins do not pass through the client and are not part of `toTransfer`.

## Events

### Monitor User Events

> Event timestamps are available on `SuiEvent.timestampMs`; the on-chain payload no longer includes a `timestamp` field.

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
  by: string;
}

// Liquidity removed
interface LiquidityRemoved {
  pm_id: string;
  pool_id: string;
  bins: number[];
  liquidity_shares: string[];
  amount_a: string;   // Actual token A returned
  amount_b: string;   // Actual token B returned
  by: string;
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
