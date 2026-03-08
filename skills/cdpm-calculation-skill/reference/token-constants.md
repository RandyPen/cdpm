# Token Constants

## Common Token Addresses (Mainnet)

```typescript
const TOKENS = {
  // Stablecoins (high priority as quote)
  USDC: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
  USDT: '0x375f70cf2ae4c00bf37117d0c85a2c71545e6ee05c4a5c7d282cd66a4504b068::usdt::USDT',
  
  // Native token
  SUI: '0x2::sui::SUI',
};

// Quote token priority for price display
// Higher in list = higher priority as quote
const QUOTE_PRIORITY = ['USDT', 'USDC', 'SUI'];
```
