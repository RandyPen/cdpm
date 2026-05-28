# Constants

```typescript
const CDPM_AGENT_CONSTANTS = {
  PACKAGE_ID: '0x64a5ce66d153b46d82a9a7cdb81cddbf6922fdf146fced2d9771c940094546b3',
  
  // Default thresholds
  DEFAULT_AUTO_COMPOUND_THRESHOLD: 1000000n,  // Minimum fees to compound
  DEFAULT_REBALANCE_THRESHOLD: 0.05,           // 5% price deviation
  DEFAULT_GAS_BUFFER: 1.2,                     // 20% gas buffer
  
  // Rate limits
  MAX_OPERATIONS_PER_MINUTE: 10,
  COOLDOWN_PERIOD_MS: 6000,
};

// CDPM Object IDs (Mainnet)
const CDPM_MAINNET = {
  PACKAGE_ID:        '0x64a5ce66d153b46d82a9a7cdb81cddbf6922fdf146fced2d9771c940094546b3',
  FEE_HOUSE_ID:      '0xf2e6c4c5ad2e108d2e1d9c0be628693d5ab129c8f067656ac835a153d962c284',
  ACCESS_LIST_ID:    '0x879596447bc3f136719bb3da479ffe709a09d277fb55b114ff3abba07e9f7fec',
  ADMIN_CAP_ID:      '0x6bd034ecf69e32bdb3242bf4dd2f903e18dce692a9d682e71922789e4268bcbe',
  GLOBAL_RECORD_ID:  '0x0c1359061172789489da16bf77cd045cbaf07e70e5a7597748a9d67a3aff7a85',
  RECORD_TYPE:       '0x64a5ce66d153b46d82a9a7cdb81cddbf6922fdf146fced2d9771c940094546b3::cdpm::Record',
};

// Cetus DLMM Object IDs (Mainnet)
const CETUS_MAINNET = {
  GLOBAL_CONFIG_ID: '0xf31b605d117f959b9730e8c07b08b856cb05143c5e81d5751c90d2979e82f599',
  VERSIONED_ID: '0x05370b2d656612dd5759cbe80463de301e3b94a921dfc72dd9daa2ecdeb2d0a8',
  REGISTRY_ID: '0xb1d55e7d895823c65f98d99b81a69436cf7d1638629c9ccb921326039cda1f1b',
};

// Common Token Addresses (Mainnet)
const TOKENS = {
  USDC: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
  USDT: '0x375f70cf2ae4c00bf37117d0c85a2c71545e6ee05c4a5c7d282cd66a4504b068::usdt::USDT',
  SUI: '0x2::sui::SUI',
};
```
