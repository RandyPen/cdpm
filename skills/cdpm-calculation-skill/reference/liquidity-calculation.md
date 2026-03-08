# Liquidity Calculation

## Constant Sum Formula

DLMM uses the constant sum formula for liquidity:

```
L = price * amount_a + amount_b
```

Where:
- **L**: Total liquidity value
- **price**: Bin price in Q64x64 format
- **amount_a**: Amount of token A
- **amount_b**: Amount of token B

## Calculate Liquidity

```typescript
import { BinUtils } from '@cetusprotocol/dlmm-sdk/utils'

// Get QPrice (Q64x64 format) for a bin
const binId = 12345
const binStep = 10
const qPrice = BinUtils.getQPriceFromId(binId, binStep)

// Calculate liquidity
const amountA = '1000000'  // Token A amount (string)
const amountB = '1200000'  // Token B amount (string)
const liquidity = BinUtils.getLiquidity(amountA, amountB, qPrice)

console.log(`Calculated liquidity: ${liquidity}`)
```

## Get Amounts from Liquidity

When removing liquidity, calculate token amounts:

```typescript
const [amountAOut, amountBOut] = BinUtils.getAmountsFromLiquidity(
  '1000000',    // Current amount A in bin
  '1200000',    // Current amount B in bin
  '500000',     // Liquidity to remove
  '10000000'    // Total liquidity in bin
)

console.log(`Amount A: ${amountAOut}, Amount B: ${amountBOut}`)
```

## Calculate by Share

```typescript
const bin = {
  amount_a: '1000000',
  amount_b: '1200000',
  liquidity: '5000000'
}
const removeLiquidity = '1000000'

const { amount_a, amount_b } = BinUtils.calculateOutByShare(bin, removeLiquidity)
console.log(`Remove ${removeLiquidity} liquidity → A: ${amount_a}, B: ${amount_b}`)
```
