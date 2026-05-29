# Constants

```typescript
const CDPM_AGENT_CONSTANTS = {
  PACKAGE_ID: '0x3284fd6e5e5b0ee4db61b67f9cf6e890809e6d45f6b4fc20639ba7a4897a8f7d',
  
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
  PACKAGE_ID:        '0x3284fd6e5e5b0ee4db61b67f9cf6e890809e6d45f6b4fc20639ba7a4897a8f7d',
  FEE_HOUSE_ID:      '0x3b1fab3cb97bac7f3cb761818d8084b1332cad8478224f5498a6ab0f1069f484',
  ACCESS_LIST_ID:    '0xb91e0828f5367a17c27da3bc4f6b19e3d89378b403d9c0c754d8d81c9200ceff',
  ADMIN_CAP_ID:      '0xebdfb970dbfe1d6759b89fdb79dd1da3846cd6530d5d453cdec2f894848e7398',
  GLOBAL_RECORD_ID:  '0x24cccaf55a1182ea441e7cff231357d8d8dc306e13a2ad38cab306a6451bf938',
  RECORD_TYPE:       '0x3284fd6e5e5b0ee4db61b67f9cf6e890809e6d45f6b4fc20639ba7a4897a8f7d::cdpm::Record',
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
