# Constants

## CDPM Package

```typescript
const CDPM_PACKAGE = '0x3e926116ec95d753b83b80d768e310ef492d84892dee5cc86b51c1d3a876d5b7';
const FEE_DENOMINATOR = 10000;
const DEFAULT_FEE_RATE = 2000; // 20%
const MAX_FEE_RATE = 3000;     // 30% — enforced cap in admin_set_fee
```

Publish references:
- publish tx digest: `94B1B74XcTt5skPfSBUfsmhctxbuynRoEKKoxDzxUHjR`
- package immutable digest: `HWJKADRhTY2XKoB49UCe3c9pYcRRdVKZfHaJZ8URmS16`

## CDPM Object IDs (Mainnet)

```typescript
const CDPM_MAINNET = {
  PACKAGE_ID:        '0x3e926116ec95d753b83b80d768e310ef492d84892dee5cc86b51c1d3a876d5b7',
  FEE_HOUSE_ID:      '0xa0cc9000a7b06325fd122ce9bf70763fb169e1bae17d0516dba08816b5ce9f18',
  ACCESS_LIST_ID:    '0xa2954f107287f8ca2b42e2da4753d39adee25f461e5a372628e79075fca85816',
  ADMIN_CAP_ID:      '0xd5ba77b9c6df5d85cff535023aae1fff7f3e48b8b6bde4bfa0926e826715d9be',
  GLOBAL_RECORD_ID:  '0xd00df195a18f8d0ff33b784f8ff36d7726b6e36cd8c7dc922ecbd9099c9ca40d',
  RECORD_TYPE:       '0x3e926116ec95d753b83b80d768e310ef492d84892dee5cc86b51c1d3a876d5b7::cdpm::Record',
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
