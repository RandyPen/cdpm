# Constants

## CDPM Package

```typescript
// Latest package: use for every moveCall target.
const CDPM_PACKAGE = '0xfd1832dffed42597f3237df3c43a1c88208ce6a65d8af7fc85c6df69229dcaae';
// Original package: use for StructType, MoveEventType, and type-string matching.
const CDPM_ORIGINAL_PACKAGE = '0x612dfd45a2e350995d492a59b595e64ec07a2253912f9eb22c2fd5947c6135d6';
const CDPM_PACKAGE_VERSION = 3;
const FEE_DENOMINATOR = 10000;
const DEFAULT_FEE_RATE = 2000; // 20%
const MAX_FEE_RATE = 5000;     // 50% — enforced cap in admin_set_fee
```

Deployment references:

- publish tx digest: `7EEna8x2u9HtcRXg66P2neDgwpugYEpGrykGHAgfVE92`
- OnlyDep tx digest: `DUxRzUA7g5c8ahixdgXMhb3kSHfwvkUSZU8h7wcSAPUu`
- v3 upgrade transaction on 2026-11-19 [FsogpYwdxKERXMhF74HMhsGMtujND8PuR1cwza6z69ZA](https://suiscan.xyz/mainnet/tx/FsogpYwdxKERXMhF74HMhsGMtujND8PuR1cwza6z69ZA)
- upgrade policy: `OnlyDep` (policy `192`)

### CDPM v3 dependency linkage

| Dependency | On-chain version | Published package ID |
|---|---:|---|
| Cetus DLMM core (`mainnet-v0.10.1` interface) | 10 | `0x6b989f9b05bd11a00f1c7779443d66802c5e71631f59e87be5d2a616991f151e` |
| Scallop Lending | 20 | `0x560a9732944dbed51a46036558e452431c25392765e7e3da02506bc6a226c825` |
| Kai SAV | 17 | `0xcf5d0f55b02304f03b99a89372567a4072c944ceb718764c502b34c7b8dfd6ae` |
| Kai Leverage | 21 | `0xed2d91715c74fe7ec5a8d063cfe6bc21b90d9451c26eb90c03605b10fadd68dd` |

### CDPM packages and objects

| Object | ID | Ownership |
|---|---|---|
| Original package/type ID | `0x612dfd45a2e350995d492a59b595e64ec07a2253912f9eb22c2fd5947c6135d6` | Immutable; type origin for structs and events |
| Latest package (v3) | `0xfd1832dffed42597f3237df3c43a1c88208ce6a65d8af7fc85c6df69229dcaae` | Immutable; function-call target |
| UpgradeCap | `0x1911fd176418f917d5f052f04e3dc5c8f4bca9aa8da60fe52001c8e4bb44b6b0` | Address-owned; OnlyDep policy `192` |
| AdminCap | `0xbd562a1faf253105f57fee2248c41c7117691b73e9be93c0fe7fc2b5be13d484` | Address-owned |
| FeeHouse | `0x6b0eee9fd3cc4ffbc9aaab3cbac7e0613314b13e3ca0aad20db90f61d157d43e` | Shared; initial shared version `970148035` |
| AccessList | `0x07e2be66038a86dde7430e22f57c6d1e34ba3badd9323bd4bbec568554eb4fe0` | Shared; initial shared version `970148035` |
| GlobalRecord | `0xd084326ff85a03dac0de7316f7e4b56c26e80694a1908ed43336a19802681059` | Shared; initial shared version `970148035` |

The initial publish also created embedded UIDs `0x517bb6a3f7cc9012d0ace21208086dd98c34acbdf4275062837a3698c5c50a38` (`FeeHouse.fee`) and `0xefad90a9675745d1cb4426a52dd126d4e1d7cd26ec592b5bffbe06480bc92142` (`GlobalRecord.record`). Read them through their parent objects.

## CDPM Object IDs (Mainnet)

```typescript
const CDPM_MAINNET = {
  PACKAGE_ID:        '0xfd1832dffed42597f3237df3c43a1c88208ce6a65d8af7fc85c6df69229dcaae',
  ORIGINAL_PACKAGE_ID: '0x612dfd45a2e350995d492a59b595e64ec07a2253912f9eb22c2fd5947c6135d6',
  PACKAGE_VERSION:   3,
  UPGRADE_CAP_ID:    '0x1911fd176418f917d5f052f04e3dc5c8f4bca9aa8da60fe52001c8e4bb44b6b0',
  FEE_HOUSE_ID:      '0x6b0eee9fd3cc4ffbc9aaab3cbac7e0613314b13e3ca0aad20db90f61d157d43e',
  ACCESS_LIST_ID:    '0x07e2be66038a86dde7430e22f57c6d1e34ba3badd9323bd4bbec568554eb4fe0',
  ADMIN_CAP_ID:      '0xbd562a1faf253105f57fee2248c41c7117691b73e9be93c0fe7fc2b5be13d484',
  GLOBAL_RECORD_ID:  '0xd084326ff85a03dac0de7316f7e4b56c26e80694a1908ed43336a19802681059',
  RECORD_TYPE:       '0x612dfd45a2e350995d492a59b595e64ec07a2253912f9eb22c2fd5947c6135d6::cdpm::Record',
};
```

## Cetus DLMM Object IDs

**Mainnet:**
```typescript
const CETUS_MAINNET = {
  PACKAGE_ID: '0x6b989f9b05bd11a00f1c7779443d66802c5e71631f59e87be5d2a616991f151e', // DLMM v10 moveCall target
  ORIGINAL_PACKAGE_ID: '0x5664f9d3fd82c84023870cfbda8ea84e14c8dd56ce557ad2116e0668581a682b',
  GLOBAL_CONFIG_ID: '0xf31b605d117f959b9730e8c07b08b856cb05143c5e81d5751c90d2979e82f599',
  VERSIONED_ID: '0x05370b2d656612dd5759cbe80463de301e3b94a921dfc72dd9daa2ecdeb2d0a8',
  REGISTRY_ID: '0xb1d55e7d895823c65f98d99b81a69436cf7d1638629c9ccb921326039cda1f1b',
};
```

## Sui System Objects

```typescript
const SUI_SYSTEM = {
  CLOCK_ID: '0x6',
};
```

## Common Token Addresses (Mainnet)

```typescript
const TOKENS = {
  // Stablecoins
  USDC: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
  USDT: '0x375f70cf2ae4c00bf37117d0c85a2c71545e6ee05c4a5c7d282cd66a4504b068::usdt::USDT',
  
  // Native
  SUI: '0x2::sui::SUI',
};

// Quote token priority for price display
const QUOTE_PRIORITY = ['USDT', 'USDC', 'SUI'];
```
