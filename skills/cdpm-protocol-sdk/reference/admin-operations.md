# Admin Operations

## Contents

- [Set Fee Rate](#set-fee-rate)
- [Manage AccessList](#manage-accesslist)
- [Collect Protocol Fees](#collect-protocol-fees)
- [Transfer AdminCap](#transfer-admincap)

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
