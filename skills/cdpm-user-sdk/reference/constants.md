# Constants

## CDPM Package

```typescript
const CDPM_PACKAGE = '0x07e37c7e54cc8c8a00d2db99070a49eb681dd4ae38b084d91a126903a645acb4';
const FEE_DENOMINATOR = 10000;
const DEFAULT_FEE_RATE = 2000; // 20%
const MAX_FEE_RATE = 5000;     // 50% — enforced cap in admin_set_fee
```

Deployment references:

- publish tx digest: `7cw9wjCDhFPgtSDBt5HSXiNUEzQpwsz8mpC7JbAis2sZ`
- OnlyDep policy tx digest: `HTCg6aiPebA1ifCVo7KYcxHvGWK7a4nuCpfBvLX8bRo7` (`cdpm.move` bytecode is locked; only dependency-version upgrades are allowed)

The publish transaction created the following top-level objects:

| Object | ID | Ownership |
|---|---|---|
| Package | `0x07e37c7e54cc8c8a00d2db99070a49eb681dd4ae38b084d91a126903a645acb4` | Immutable |
| UpgradeCap | `0x0d18b2ff581183e64d18277c71ca8e0d914e3c32895053418d9724b0c2fc1e64` | Address-owned; OnlyDep policy `192` |
| AdminCap | `0x69c336f364e0261f60727c3b932bed7a40e2061fcf891b3b96c3bd9d9e2b1384` | Address-owned |
| FeeHouse | `0x6a12b98759f487dd276013afbd402924768f8537eadfd7882c70152abb2d1668` | Shared; initial shared version `966838623` |
| AccessList | `0xd0853b5193964b76df670938f14e23095fe4fedd3096cd762b933cadc4b71968` | Shared; initial shared version `966838623` |
| GlobalRecord | `0x761ca7d22fa3b55d92b1b8792a8c4ba108402c0096097e59bb1267d8742c5d49` | Shared; initial shared version `966838623` |

The transaction also created embedded `Bag` UIDs `0x852fc5ecf3ab1e78d5e36b43e60412ffe0eb4bd07d3b0261417862ef8491e1c4` (`FeeHouse.fee`) and `0x8711a608907d09b5f751cc7edbc9bf7bc20fd898760e12a749f3059d7d735d34` (`GlobalRecord.record`). They are child UIDs, not standalone object arguments.

## CDPM Object IDs (Mainnet)

```typescript
const CDPM_MAINNET = {
  PACKAGE_ID:        '0x07e37c7e54cc8c8a00d2db99070a49eb681dd4ae38b084d91a126903a645acb4',
  UPGRADE_CAP_ID:    '0x0d18b2ff581183e64d18277c71ca8e0d914e3c32895053418d9724b0c2fc1e64',
  FEE_HOUSE_ID:      '0x6a12b98759f487dd276013afbd402924768f8537eadfd7882c70152abb2d1668',
  ACCESS_LIST_ID:    '0xd0853b5193964b76df670938f14e23095fe4fedd3096cd762b933cadc4b71968',
  ADMIN_CAP_ID:      '0x69c336f364e0261f60727c3b932bed7a40e2061fcf891b3b96c3bd9d9e2b1384',
  GLOBAL_RECORD_ID:  '0x761ca7d22fa3b55d92b1b8792a8c4ba108402c0096097e59bb1267d8742c5d49',
  RECORD_TYPE:       '0x07e37c7e54cc8c8a00d2db99070a49eb681dd4ae38b084d91a126903a645acb4::cdpm::Record',
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
