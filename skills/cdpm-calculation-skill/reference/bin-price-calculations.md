# Bin Price Calculations

## Get Bin ID from Price

```typescript
const price = '1.05'      // Price
const binStep = 10        // Bin step in basis points
const decimalA = 9        // Token A decimals
const decimalB = 6        // Token B decimals
const useFloor = true     // true = floor, false = ceil

const binId = BinUtils.getBinIdFromPrice(
  price,
  binStep,
  useFloor,
  decimalA,
  decimalB
)
console.log(`Bin ID for price ${price}: ${binId}`)
```

## Get Price from Bin ID

```typescript
const calculatedPrice = BinUtils.getPriceFromBinId(
  binId,
  binStep,
  decimalA,
  decimalB
)
console.log(`Price for Bin ID ${binId}: ${calculatedPrice}`)
```

## Get Q64x64 Price

```typescript
// Get on-chain Q64x64 price format
const qPrice = BinUtils.getQPriceFromId(binId, binStep)
console.log(`Q64x64 price: ${qPrice}`)
```

## Calculate Bin Shift

For slippage protection:

```typescript
const activeId = 10000
const binStep = 10
const maxPriceSlippage = 0.01  // 1%

const binShift = BinUtils.getBinShift(activeId, binStep, maxPriceSlippage)
console.log(`Allowed bin shift: ${binShift}`)
```

## Find Min/Max Bin IDs

```typescript
const { minBinId, maxBinId } = BinUtils.findMinMaxBinId(binStep)
console.log(`Valid bin range: ${minBinId} to ${maxBinId}`)
```
