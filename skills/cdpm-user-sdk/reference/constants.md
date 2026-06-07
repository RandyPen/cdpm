# Constants

## CDPM Package

```typescript
const CDPM_PACKAGE = '0x3ad00d82541cfd1fd13568f24b43bf9e36718611533a4853e722438b90ea61f3';
const FEE_DENOMINATOR = 10000;
const DEFAULT_FEE_RATE = 2000; // 20%
const MAX_FEE_RATE = 5000;     // 50% — enforced cap in admin_set_fee
```

Publish references:
- publish tx digest: `Dd8mZN94kHNcV6uEcW2tzVa8DvsB6h9dfMEccpAwF2Rb`
- only-dep-upgrades tx digest: `CmP8QVdyQta1EAQiNpjn9mwkvM56WhzVKjnCVaBh5mWU` (`cdpm.move` bytecode is locked; only dependency-version upgrades are allowed)

## CDPM Object IDs (Mainnet)

```typescript
const CDPM_MAINNET = {
  PACKAGE_ID:        '0x3ad00d82541cfd1fd13568f24b43bf9e36718611533a4853e722438b90ea61f3',
  FEE_HOUSE_ID:      '0x97a23b119f8fdecd52a4ad0623f744a34f4ae15ce484a3af727f1c693d4b90be',
  ACCESS_LIST_ID:    '0xea634e81f8958105e760cdd9f9692803976b5aeedf5b27b8e70207dea2842ea4',
  ADMIN_CAP_ID:      '0xe92e093469cf1554c89cfb3ff2b98449dc8dfab16a388f7486d16b21edea4606',
  GLOBAL_RECORD_ID:  '0x14aaff55028348d9ba256f440229331e80ba53e155a5b6dfaa7fcd18a09a6b42',
  RECORD_TYPE:       '0x3ad00d82541cfd1fd13568f24b43bf9e36718611533a4853e722438b90ea61f3::cdpm::Record',
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
