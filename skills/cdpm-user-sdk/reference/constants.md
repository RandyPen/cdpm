# Constants

## CDPM Package

```typescript
const CDPM_PACKAGE = '0xc280a6679edf7d38b1741c8752fefa22d6aa50510856c63aeeb7d918665d9b85';
const FEE_DENOMINATOR = 10000;
const DEFAULT_FEE_RATE = 2000; // 20%
```

## CDPM Object IDs (Mainnet)

```typescript
const CDPM_MAINNET = {
  PACKAGE_ID: '0xc280a6679edf7d38b1741c8752fefa22d6aa50510856c63aeeb7d918665d9b85',
  FEE_HOUSE_ID: '0xd5536c970738c10cd9169ea90e3f151883d0092c74827e280b9ee159e08a4dc4',
  ACCESS_LIST_ID: '0xa47e7a2a390d2f7c2f72dc9dbbdfed3b91dbe2dc65796d69798bc90259fa7677',
  ADMIN_CAP_ID: '0xe51db9ef2f515fb2634a870ba463c4c2128a554f1d1cf98651531520223bf052',
  GLOBAL_RECORD_ID: '0x3cd067f75e21e0b2b19d6814c4af98c6032f32d34d06ddc29acfa26864f02f6b',
  RECORD_TYPE: '0xc280a6679edf7d38b1741c8752fefa22d6aa50510856c63aeeb7d918665d9b85::cdpm::Record',
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
