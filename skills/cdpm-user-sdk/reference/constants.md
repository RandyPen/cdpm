# Constants

## CDPM Package

```typescript
const CDPM_PACKAGE = '0x73459993897586a961ab95e9b4833bca5ab8a25eaf39155470db9cfb1809467b';
const FEE_DENOMINATOR = 10000;
const DEFAULT_FEE_RATE = 2000; // 20%
```

## CDPM Object IDs (Mainnet)

```typescript
const CDPM_MAINNET = {
  PACKAGE_ID: '0x73459993897586a961ab95e9b4833bca5ab8a25eaf39155470db9cfb1809467b',
  FEE_HOUSE_ID: '0xab202afd3830899327664bd65171d3dfcf6c4fad0eeea3cc50ab9d612c7b44eb',
  ACCESS_LIST_ID: '0xe8ce164433c30f369165db4ee6487dae7fb595c956989b99012274ade2e587ff',
  ADMIN_CAP_ID: '0x6490e3c6113faf5a2668c53a699061f6f9590e9ea7211bbb9827e6b6313a7333',
  GLOBAL_RECORD_ID: '0xbf873526a8bbf76d7eabf4b8435463d1380485bbe4b7eb12aeceb4749f294b8f',
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
