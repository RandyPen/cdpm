# Price Conversion for External Comparison

## Understanding CDPM Price Format

CDPM/Cetus DLMM calculates prices as **coinA / coinB**:

```
price = coinA_amount / coinB_amount
```

However, when comparing with external exchanges (like Binance, Coinbase), you need to consider the **quote/base** convention.

## Quote Token Priority

The quote token is determined by this priority:

1. **USDT** (highest priority)
2. **USDC** 
3. **SUI** (lowest priority)

```typescript
const QUOTE_PRIORITY = ['USDT', 'USDC', 'SUI']

function determineQuoteToken(coinA: string, coinB: string): string {
  const tokenA = coinA.split('::').pop()?.toUpperCase() || ''
  const tokenB = coinB.split('::').pop()?.toUpperCase() || ''
  
  for (const quote of QUOTE_PRIORITY) {
    if (tokenA === quote) return coinA  // coinA is quote
    if (tokenB === quote) return coinB  // coinB is quote
  }
  
  // Default: coinB is quote if neither is in priority list
  return coinB
}

// Examples:
// ETH/USDC -> USDC is quote (priority: USDC > ETH)
// BTC/USDT -> USDT is quote (priority: USDT > BTC)
// SUI/ETH -> SUI is quote (priority: SUI > ETH, even though ETH has higher market cap)
```

## Price Conversion Logic

When comparing CDPM price with external exchange price:

```typescript
/**
 * Convert CDPM price to exchange-comparable format
 * 
 * CDPM price format: coinA / coinB
 * Exchange price format: base / quote
 */
function convertPriceForComparison(
  cdpmPrice: string,      // Price from CDPM (coinA/coinB)
  coinA: string,          // Token A type
  coinB: string,          // Token B type
  targetQuote: string     // Desired quote token for comparison
): string {
  const quoteToken = determineQuoteToken(coinA, coinB)
  
  // If CDPM's coinA is the quote token, we need to invert
  // because exchanges show base/quote, not quote/base
  if (quoteToken === coinA) {
    // CDPM: coinA(quote) / coinB(base) = USDC/SUI
    // Exchange: SUI/USDC
    // Conversion: 1 / CDPM_price
    return (1 / parseFloat(cdpmPrice)).toString()
  }
  
  // If CDPM's coinB is the quote token, no conversion needed
  // CDPM: coinA(base) / coinB(quote) = SUI/USDC
  // Exchange: SUI/USDC
  return cdpmPrice
}

// Example: Compare CDPM price with Binance
function compareWithExchange(
  cdpmBinId: number,
  binStep: number,
  coinA: string,
  coinB: string,
  exchangePrice: string,  // External exchange price
  exchangeQuote: string   // Quote token used by exchange
): { cdpmPrice: string; exchangePrice: string; difference: string } {
  // Get CDPM price (coinA/coinB)
  const cdpmPricePerLamport = BinUtils.getPricePerLamportFromBinId(cdpmBinId, binStep)
  
  // Convert to comparable format
  const cdpmComparablePrice = convertPriceForComparison(
    cdpmPricePerLamport.toString(),
    coinA,
    coinB,
    exchangeQuote
  )
  
  // Calculate difference
  const cdpm = parseFloat(cdpmComparablePrice)
  const exchange = parseFloat(exchangePrice)
  const difference = ((cdpm - exchange) / exchange * 100).toFixed(2)
  
  return {
    cdpmPrice: cdpmComparablePrice,
    exchangePrice,
    difference: `${difference}%`
  }
}
```

## Practical Example

```typescript
// Pair: SUI/USDC
const coinA = '0x2::sui::SUI'
const coinB = '0xdba...::usdc::USDC'
const binStep = 10
const binId = 10000

// 1. Get CDPM price (coinA/coinB = SUI/USDC)
const cdpmPrice = BinUtils.getPriceFromBinId(binId, binStep, 9, 6)
console.log(`CDPM price (SUI/USDC): ${cdpmPrice}`)

// 2. Determine quote token
const quoteToken = determineQuoteToken(coinA, coinB)
console.log(`Quote token: ${quoteToken}`)  // USDC

// 3. Compare with exchange (Binance shows SUI/USDC)
// Since coinB (USDC) is quote, no conversion needed
const binancePrice = '0.85'  // Example Binance price

// 4. If pair was USDC/SUI (rare)
// CDPM would show USDC/SUI price
// Binance shows SUI/USDC
// We need to invert: 1 / CDPM_price

const comparison = compareWithExchange(
  binId,
  binStep,
  coinA,
  coinB,
  binancePrice,
  'USDC'
)

console.log('Price comparison:', comparison)
// Output: { cdpmPrice: '0.845', exchangePrice: '0.85', difference: '-0.59%' }
```

## Price Display Helper

```typescript
class PriceDisplayHelper {
  static readonly QUOTE_PRIORITY = ['USDT', 'USDC', 'SUI']
  
  /**
   * Get display format for a pair
   */
  static getDisplayFormat(coinA: string, coinB: string): { base: string; quote: string } {
    const tokenA = this.extractSymbol(coinA)
    const tokenB = this.extractSymbol(coinB)
    
    const quoteA = this.QUOTE_PRIORITY.indexOf(tokenA)
    const quoteB = this.QUOTE_PRIORITY.indexOf(tokenB)
    
    // Higher priority index = lower priority as quote
    if (quoteA !== -1 && (quoteB === -1 || quoteA < quoteB)) {
      return { base: tokenB, quote: tokenA }  // coinA is quote
    }
    
    return { base: tokenA, quote: tokenB }  // coinB is quote (default)
  }
  
  /**
   * Format price for display
   */
  static formatPrice(
    cdpmPrice: string,
    coinA: string,
    coinB: string
  ): { price: string; pair: string; direction: string } {
    const { base, quote } = this.getDisplayFormat(coinA, coinB)
    const tokenA = this.extractSymbol(coinA)
    
    if (quote === tokenA) {
      // coinA is quote, invert price
      return {
        price: (1 / parseFloat(cdpmPrice)).toFixed(6),
        pair: `${base}/${quote}`,
        direction: 'inverted'
      }
    }
    
    return {
      price: parseFloat(cdpmPrice).toFixed(6),
      pair: `${base}/${quote}`,
      direction: 'direct'
    }
  }
  
  private static extractSymbol(coinType: string): string {
    return coinType.split('::').pop()?.toUpperCase() || ''
  }
}

// Usage
const display = PriceDisplayHelper.formatPrice('1.176', coinA, coinB)
console.log(`${display.pair}: ${display.price}`)  // SUI/USDC: 0.850340
```
