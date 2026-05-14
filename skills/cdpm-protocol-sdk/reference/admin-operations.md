# Admin Operations

## Contents

- [Set Fee Rate](#set-fee-rate)
- [Manage AccessList](#manage-accesslist)
- [Collect Protocol Fees](#collect-protocol-fees)
- [Transfer AdminCap](#transfer-admincap)

## Set Fee Rate

> The contract enforces `fee_rate <= MAX_FEE_RATE = 3000` (30%) — `admin_set_fee` aborts with `EInvalidFeeRate (1003)` for higher values. The default initialised by `init` is `2000` (20%). The same rate is used for three places: Cetus protocol fee splits (`take_fee` inside `protocol_collect_*`), the Scallop yield fee inside `scallop_finish_redeem`, and the Kai SAV yield fee inside `kai_finish_redeem`. There is no separate Kai or Scallop fee knob.

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function setFeeRate(
  client: SuiGrpcClient,
  signer: any,  // Must hold AdminCap
  feeHouseId: string,
  newFeeRate: number  // 0-3000 (0-30%); contract caps at 3000
) {
  const tx = new Transaction();
  
  // Get AdminCap object
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

## Manage AccessList

### Add Protocol Address

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

### Remove Protocol Address

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

## Collect Protocol Fees

```typescript
async function collectProtocolFees(
  client: SuiGrpcClient,
  signer: any,
  feeHouseId: string,
  coinType: string
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
  
  tx.transferObjects([coin], signer.getPublicKey().toSuiAddress());
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## Transfer AdminCap

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
