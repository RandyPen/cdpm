# Constants

## CDPM Package

```typescript
const CDPM_PACKAGE = '0xcfae3228852e1d6c5596b8765397dc4bc9dcb98279281e0241020ca296436a6b';
const FEE_DENOMINATOR = 10000;
const DEFAULT_FEE_RATE = 2000; // 20%
```

## CDPM Object IDs (Mainnet)

```typescript
const CDPM_MAINNET = {
  PACKAGE_ID: '0xcfae3228852e1d6c5596b8765397dc4bc9dcb98279281e0241020ca296436a6b',
  FEE_HOUSE_ID: '0xada496428e99d350b1610de1705fae81e3dd294859711a92341eadb83e42b075',
  ACCESS_LIST_ID: '0x1a9fcba70510331483284db0e97c85e80477fd4023919d95a8b941a12e8b23eb',
  ADMIN_CAP_ID: '0x3014bfd285b46e8054c834db04af9d4874eb6c8b45af19db8c951ecfda57564c',
  GLOBAL_RECORD_ID: '0x98d1ca5acde1bc09e1fcd72d8411ae3451770fc45d479efeb5a0c31815b8c102',
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
