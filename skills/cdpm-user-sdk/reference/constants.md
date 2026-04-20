# Constants

## CDPM Package

```typescript
const CDPM_PACKAGE = '0xbb15c25329fbc85b9cc9cc1d37ee2f913696a7c688d0552ca4dc7e3557598541';
const FEE_DENOMINATOR = 10000;
const DEFAULT_FEE_RATE = 2000; // 20%
const MAX_FEE_RATE = 3000;     // 30% — enforced cap in admin_set_fee
```

## CDPM Object IDs (Mainnet)

```typescript
const CDPM_MAINNET = {
  PACKAGE_ID: '0xbb15c25329fbc85b9cc9cc1d37ee2f913696a7c688d0552ca4dc7e3557598541',
  FEE_HOUSE_ID: '0x1aff1e2564259f93513cda1744a77ed04dbb128c5541780f566d96efaf863eb2',
  ACCESS_LIST_ID: '0xa7956e83ae89693bb848a0f51685f03ca93e4c7c5f11e4b8d6e4e9159761c8e4',
  ADMIN_CAP_ID: '0xb88669db23ef4468b46508fa644079ebc1880f4d6335782e54c0ab65e5e7abec',
  GLOBAL_RECORD_ID: '0x69769bd87a47c5bad509972598d2cf86a1970dcdea68b31bd56fcf44dd40ed2e',
  RECORD_TYPE: '0xbb15c25329fbc85b9cc9cc1d37ee2f913696a7c688d0552ca4dc7e3557598541::cdpm::Record',
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
