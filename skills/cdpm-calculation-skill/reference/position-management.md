# Position Management

## Calculate Position Count

```typescript
const lowerBinId = 9950
const upperBinId = 10050

// Calculate how many positions needed (max 70 bins per position)
const positionCount = BinUtils.getPositionCount(lowerBinId, upperBinId)
console.log(`Need ${positionCount} positions for this range`)
```

## Split Bins into Positions

```typescript
const liquidityBins = {
  bins: [
    { bin_id: 9950, amount_a: '10000', amount_b: '12000', liquidity: '50000' },
    { bin_id: 9951, amount_a: '10000', amount_b: '12000', liquidity: '50000' },
    // ... more bins
  ],
  amount_a: '100000',
  amount_b: '120000'
}

const splitPositions = BinUtils.splitBinLiquidityInfo(
  liquidityBins,
  lowerBinId,
  upperBinId
)

console.log(`Split into ${splitPositions.length} positions`)
```

## Manual Position Splitting

```typescript
function splitIntoPositions(
  bins: Array<{ binId: number; amountA: string; amountB: string }>,
  lowerBinId: number,
  upperBinId: number,
  maxBinsPerPosition: number = 70
): Array<Array<typeof bins[0]>> {
  const positions: Array<Array<typeof bins[0]>> = []
  let currentLower = lowerBinId
  
  while (currentLower <= upperBinId) {
    const currentUpper = Math.min(
      currentLower + maxBinsPerPosition - 1,
      upperBinId
    )
    
    const positionBins = bins.filter(
      b => b.binId >= currentLower && b.binId <= currentUpper
    )
    
    positions.push(positionBins)
    currentLower = currentUpper + 1
  }
  
  return positions
}
```
