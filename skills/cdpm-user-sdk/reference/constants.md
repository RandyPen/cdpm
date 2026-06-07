# Constants

## CDPM Package

```typescript
const CDPM_PACKAGE = '0x573584cc4698e82fd85f2b54e64ad4cd901c42b768f7628ec167bf2d24aa2aa7';
const FEE_DENOMINATOR = 10000;
const DEFAULT_FEE_RATE = 2000; // 20%
const MAX_FEE_RATE = 5000;     // 50% — enforced cap in admin_set_fee
```

Publish references:
- publish tx digest: `Cmq21bu5KUV95xM7VSczUwHRNEXyhbb8PSVBL4KZ3PVF`
- only-dep-upgrades tx digest: `F5kVa3YDSHoBvJvYJFH9y5dANCJScEdyZoxZLLy6qd15` (`cdpm.move` bytecode is locked; only dependency-version upgrades are allowed)

## CDPM Object IDs (Mainnet)

```typescript
const CDPM_MAINNET = {
  PACKAGE_ID:        '0x573584cc4698e82fd85f2b54e64ad4cd901c42b768f7628ec167bf2d24aa2aa7',
  FEE_HOUSE_ID:      '0x44cc921bdabdd4d868b32ba7081b71707b685eecc6b6034668281088bea0b5d8',
  ACCESS_LIST_ID:    '0xdca06884b21a23d04f2664835c0c965dc80a5c40294b90d9d000c7b05707f803',
  ADMIN_CAP_ID:      '0x91940a5f725a9359d9778501fb6b9e2eff45e629127d612e8ce9d0cdc1102463',
  GLOBAL_RECORD_ID:  '0xee3b816d68c8d84fe90a2d0ad1861a6fb455d053f8edf6512a8953f7d3e77b95',
  RECORD_TYPE:       '0x573584cc4698e82fd85f2b54e64ad4cd901c42b768f7628ec167bf2d24aa2aa7::cdpm::Record',
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
