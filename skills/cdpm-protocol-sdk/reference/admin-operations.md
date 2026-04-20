# Admin Operations

> **Note — FeeHouse lifecycle**
> `FeeHouse` is a single shared object created during `init`; there is no runtime creation function. Admin workflows only read/update the existing `FeeHouse` (e.g. `admin_set_fee`, `admin_collect_fee_return_coin`) — they never construct a new one.

## Set Fee Rate

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function setFeeRate(
  client: SuiGrpcClient,
  signer: any,  // Must hold AdminCap
  feeHouseId: string,
  newFeeRate: number  // 0-10000 (0-100%)
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
