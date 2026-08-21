# Constants

## CDPM Package

```typescript
const CDPM_PACKAGE = '0x612dfd45a2e350995d492a59b595e64ec07a2253912f9eb22c2fd5947c6135d6';
const FEE_DENOMINATOR = 10000;
const DEFAULT_FEE_RATE = 2000; // 20%
const MAX_FEE_RATE = 5000;     // 50% — enforced cap in admin_set_fee
```

Deployment references:

- publish tx digest: `7EEna8x2u9HtcRXg66P2neDgwpugYEpGrykGHAgfVE92`
- OnlyDep tx digest: `DUxRzUA7g5c8ahixdgXMhb3kSHfwvkUSZU8h7wcSAPUu`
- upgrade policy: `OnlyDep` (policy `192`)

The publish transaction created the following top-level objects:

| Object | ID | Ownership |
|---|---|---|
| Package | `0x612dfd45a2e350995d492a59b595e64ec07a2253912f9eb22c2fd5947c6135d6` | Immutable |
| UpgradeCap | `0x1911fd176418f917d5f052f04e3dc5c8f4bca9aa8da60fe52001c8e4bb44b6b0` | Address-owned; OnlyDep policy `192` |
| AdminCap | `0xbd562a1faf253105f57fee2248c41c7117691b73e9be93c0fe7fc2b5be13d484` | Address-owned |
| FeeHouse | `0x6b0eee9fd3cc4ffbc9aaab3cbac7e0613314b13e3ca0aad20db90f61d157d43e` | Shared; initial shared version `970148035` |
| AccessList | `0x07e2be66038a86dde7430e22f57c6d1e34ba3badd9323bd4bbec568554eb4fe0` | Shared; initial shared version `970148035` |
| GlobalRecord | `0xd084326ff85a03dac0de7316f7e4b56c26e80694a1908ed43336a19802681059` | Shared; initial shared version `970148035` |

The transaction also created embedded `Bag` UIDs `0x517bb6a3f7cc9012d0ace21208086dd98c34acbdf4275062837a3698c5c50a38` (`FeeHouse.fee`) and `0xefad90a9675745d1cb4426a52dd126d4e1d7cd26ec592b5bffbe06480bc92142` (`GlobalRecord.record`). They are child UIDs, not standalone object arguments.

## CDPM Object IDs (Mainnet)

```typescript
const CDPM_MAINNET = {
  PACKAGE_ID:        '0x612dfd45a2e350995d492a59b595e64ec07a2253912f9eb22c2fd5947c6135d6',
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
