# Admin Operations

## Contents

- [Set Fee Rate](#set-fee-rate)
- [Manage AccessList](#manage-accesslist)
- [Collect Protocol Fees](#collect-protocol-fees)
- [Transfer AdminCap](#transfer-admincap)
- [Emergency Return (asset evacuation)](#emergency-return-asset-evacuation)

## Set Fee Rate

> `admin_set_fee` aborts with `EInvalidFeeRate (1003)` whenever the supplied rate exceeds `MAX_FEE_RATE = 5000` (50%). The default initialised by `init` is `2000` (20%). The same rate drives three places: Cetus protocol fee splits (`take_fee` inside `protocol_collect_fee` / `protocol_collect_reward`), the Scallop yield fee inside `scallop_redeem`, and the Kai SAV yield fee inside `kai_redeem`. There is no separate Kai or Scallop fee knob.

Signature:

```move
public fun admin_set_fee(
    _: &AdminCap,
    fee_house: &mut FeeHouse,
    fee_rate: u64,
);
```

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function setFeeRate(
  client: SuiGrpcClient,
  signer: any,  // Must hold AdminCap
  feeHouseId: string,
  newFeeRate: number  // 0-5000 (0-50%); contract caps at 5000
) {
  const tx = new Transaction();

  const adminCaps = await client.listOwnedObjects({
    owner: signer.getPublicKey().toSuiAddress(),
    filter: { StructType: `${CDPM_PACKAGE}::cdpm::AdminCap` },
  });
  const adminCapId = adminCaps.data[0].data?.objectId;

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::admin_set_fee`,
    arguments: [
      tx.object(adminCapId),
      tx.object(feeHouseId),
      tx.pure.u64(newFeeRate),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Emits `FeeRateUpdated { fee_house_id, old_fee_rate, new_fee_rate }`.

## Manage AccessList

### Add Protocol Address

Signature:

```move
public fun admin_insert_access_list(
    _: &AdminCap,
    access: &mut AccessList,
    bot: address,
);
```

```typescript
async function addProtocolAddress(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  protocolAddress: string
) {
  const tx = new Transaction();

  const adminCaps = await client.listOwnedObjects({
    owner: signer.getPublicKey().toSuiAddress(),
    filter: { StructType: `${CDPM_PACKAGE}::cdpm::AdminCap` },
  });
  const adminCapId = adminCaps.data[0].data?.objectId;

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::admin_insert_access_list`,
    arguments: [
      tx.object(adminCapId),
      tx.object(accessListId),
      tx.pure.address(protocolAddress),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Emits `AccessGranted { access_list_id, address }`.

### Remove Protocol Address

Signature:

```move
public fun admin_remove_access_list(
    _: &AdminCap,
    access: &mut AccessList,
    bot: address,
);
```

```typescript
async function removeProtocolAddress(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  protocolAddress: string
) {
  const tx = new Transaction();

  const adminCaps = await client.listOwnedObjects({
    owner: signer.getPublicKey().toSuiAddress(),
    filter: { StructType: `${CDPM_PACKAGE}::cdpm::AdminCap` },
  });
  const adminCapId = adminCaps.data[0].data?.objectId;

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::admin_remove_access_list`,
    arguments: [
      tx.object(adminCapId),
      tx.object(accessListId),
      tx.pure.address(protocolAddress),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Emits `AccessRevoked { access_list_id, address }`.

## Collect Protocol Fees

Two variants for one coin type at a time. Both empty the `Balance<T>` entry keyed by `type_name<T>` inside `fee_house.fee` and emit `AdminFeeCollected { fee_house_id, coin_type, amount, admin }`.

### Return the Coin for PTB chaining

```move
public fun admin_collect_fee_return_coin<T>(
    _: &AdminCap,
    fee_house: &mut FeeHouse,
    ctx: &mut TxContext,
): Coin<T>;
```

Use this when the same PTB will spend the collected coin (e.g. forward it to a treasury splitter):

```typescript
async function collectProtocolFeesPTB(
  client: SuiGrpcClient,
  signer: any,
  feeHouseId: string,
  coinType: string,
  destination: string,
) {
  const tx = new Transaction();

  const adminCaps = await client.listOwnedObjects({
    owner: signer.getPublicKey().toSuiAddress(),
    filter: { StructType: `${CDPM_PACKAGE}::cdpm::AdminCap` },
  });
  const adminCapId = adminCaps.data[0].data?.objectId;

  const [coin] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::admin_collect_fee_return_coin`,
    typeArguments: [coinType],
    arguments: [
      tx.object(adminCapId),
      tx.object(feeHouseId),
    ],
  });

  tx.transferObjects([coin], destination);

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

### Transfer Coin to Admin

```move
public fun admin_collect_fee<T>(
    _: &AdminCap,
    fee_house: &mut FeeHouse,
    ctx: &mut TxContext,
);
```

Collects the coin and `transfer::public_transfer`s it to `ctx.sender()` inside the move call:

```typescript
async function collectProtocolFeesToAdmin(
  client: SuiGrpcClient,
  signer: any,
  feeHouseId: string,
  coinType: string,
) {
  const tx = new Transaction();

  const adminCaps = await client.listOwnedObjects({
    owner: signer.getPublicKey().toSuiAddress(),
    filter: { StructType: `${CDPM_PACKAGE}::cdpm::AdminCap` },
  });
  const adminCapId = adminCaps.data[0].data?.objectId;

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::admin_collect_fee`,
    typeArguments: [coinType],
    arguments: [
      tx.object(adminCapId),
      tx.object(feeHouseId),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## Emergency Return (asset evacuation)

Escape hatch for the **"upgrade incompatible"** scenario: when a dependency
(Cetus DLMM / Scallop / Kai) ships a breaking upgrade, the admin can force raw
stored assets out of any `PositionManager` back to `pm.owner`.

> **Trust model.** Every `admin_force_return_*` function hard-codes the
> recipient to `pm.owner` — the admin can only "un-stick" funds, never steal
> them. Gated by `&AdminCap` (structural: only the real `AdminCap` holder can
> pass a reference), so these require the admin multisig.
>
> **Non-iterable bags.** `balance` / `fee` / `lending` are `Bag`s keyed by
> `type_name`, which Move cannot iterate. Each call below drains exactly ONE
> coin type `<T>`. Enumerate the present types off-chain from the PM object's
> dynamic fields (the same pre-scan the user-sdk `closePositionSafe` flow
> uses), then call one function per type, then close.

Signatures:

```move
public fun admin_force_return_balance<T>(
    _: &AdminCap, pm: &mut PositionManager, ctx: &mut TxContext,
); // drains pm.balance[T] -> Coin<T> -> pm.owner

public fun admin_force_return_fee<T>(
    _: &AdminCap, pm: &mut PositionManager, ctx: &mut TxContext,
); // drains pm.fee[T] -> Coin<T> -> pm.owner

public fun admin_force_return_position(
    _: &AdminCap, pm: &mut PositionManager,
); // raw Cetus Position object -> pm.owner (no close, no reward collect)

public fun admin_force_return_scallop<T>(
    _: &AdminCap, pm: &mut PositionManager, fee_house: &mut FeeHouse,
    version: &ScallopVersion, market: &mut Market, clock: &Clock, ctx: &mut TxContext,
); // redeems the Scallop vault to underlying Coin<T> -> pm.owner (protocol fee on interest)

public fun admin_force_return_kai<T, ST, YT>(
    _: &AdminCap, pm: &mut PositionManager, fee_house: &mut FeeHouse,
    vault: &mut kai_vault::Vault<T, YT>, strategy: &mut klsp::Strategy<T, ST>,
    supply_pool: &mut SupplyPool<T, ST>, clock: &Clock, ctx: &mut TxContext,
); // redeems the Kai vault to underlying Coin<T> -> pm.owner (protocol fee on interest)

public fun admin_force_close_pm(
    _: &AdminCap, pm: PositionManager,
); // deletes PM; asserts position None + balance/fee/lending empty

public fun user_remove_record_entry(
    record: &mut Record, pm_id: ID,
); // owner removes a stale index entry pointing at a deleted PM
```

`admin_force_return_scallop<T>` redeems the Scallop vault to the underlying
`Coin<T>` via Scallop's `redeem::redeem` and returns it to `pm.owner`, charging
the same interest-only protocol fee as `scallop_redeem` (`fee_rate` on
`max(0, redeemed - principal)`). This is the useful exit while the raw sCoin is
being deprecated (the sCoin-converter migration path is not yet available).
The `principal` counter feeds the interest/fee carve and is discarded with the
vault.

`admin_force_return_kai<T, ST, YT>` runs the full Kai withdrawal chain
(`vault::withdraw` → `klsp::withdraw` → `vault::redeem_withdraw_ticket`) and
returns the underlying `Coin<T>` to `pm.owner`, charging the same interest-only
protocol fee as `kai_redeem` (`fee_rate` on `max(0, redeemed - principal)`).

`admin_force_close_pm` aborts with:
- `EPositionStillActive (1013)` if `position` is still `Some` — a live
  `Position` must be returned (or the underlying pool closed) first, otherwise
  it would be burned with the PM.
- `EBalanceNotEmpty (1008)` / `EFeeNotEmpty (1009)` /
  `ELendingNotEmpty (1004)` if any bag is non-empty.

**Evacuation PTB order** (single tx or batched; each step is independent and
retry-safe since every asset routes to `pm.owner`):

```
1. admin_force_return_position               (if position present)
2. admin_force_return_scallop<T>             (one per Scallop type; needs fee_house/version/market/clock)
3. admin_force_return_kai<T, ST, YT>         (one per Kai type; needs fee_house/vault/strategy/supply_pool/clock)
4. admin_force_return_balance<T>             (one per balance type)
5. admin_force_return_fee<T>                 (one per fee type)
6. admin_force_close_pm(pm)
```

After close, the owner cleans their own `Record` index with
`user_remove_record_entry` (the admin cannot — `Record` is owner-owned).

Emits `AdminAssetReturned { pm_id, coin_type, amount, to }`,
`AdminPositionReturned { pm_id, to }`, `RecordEntryRemoved { record_id, pm_id }`,
and reuses `PositionManagerClosed { pm_id, owner }` on close.

## Transfer AdminCap

Signature:

```move
public fun admin_transfer(
    admin_cap: AdminCap,
    to: address,
    ctx: &TxContext,
);
```

The `AdminCap` is consumed and transferred to `to`. Emits `AdminTransferred { from, to }` where `from = ctx.sender()`.

```typescript
async function transferAdminCap(
  client: SuiGrpcClient,
  signer: any,
  adminCapId: string,
  newAdminAddress: string
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::admin_transfer`,
    arguments: [
      tx.object(adminCapId),  // AdminCap (consumed)
      tx.pure.address(newAdminAddress),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```
