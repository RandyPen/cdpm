# Constants

## CDPM Package

```typescript
const CDPM_PACKAGE = '0xb77692e0e6bc5f0ac5239cf2e11efccc4bcbcf7129f972f661a63f4afffb8faa';
const FEE_DENOMINATOR = 10000;
const DEFAULT_FEE_RATE = 2000; // 20%
```

## CDPM Object IDs (Mainnet)

```typescript
const CDPM_MAINNET = {
  PACKAGE_ID: '0xb77692e0e6bc5f0ac5239cf2e11efccc4bcbcf7129f972f661a63f4afffb8faa',
  FEE_HOUSE_ID: '0x38013060cbac12a9bc03765e5879316fdac17f0e6e9e74d8afc132359e2bbece',
  ACCESS_LIST_ID: '0x03fa7b821749b7cddb3a4fd118cf50f67b93c2162f9da3903b2dcf58fb16c1bf',
  ADMIN_CAP_ID: '0x47c2ac3f93475826934d4ece1bf6d4ead29a7b6932dffad48f76736f2975dca8',
  GLOBAL_RECORD_ID: '0x98135c9891aa8b6eea06b2eef479032fce34e4abdf87cf72512fc160a2c502cf',
  RECORD_TYPE: '0xb77692e0e6bc5f0ac5239cf2e11efccc4bcbcf7129f972f661a63f4afffb8faa::cdpm::Record',
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
