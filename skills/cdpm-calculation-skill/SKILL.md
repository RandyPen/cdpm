---
name: cdpm-calculation-skill
description: CDPM calculation utilities using Cetus DLMM SDK. Provides liquidity calculation, bin price math, position management, and fee calculations. Use when performing mathematical operations for CDPM positions.
---

# CDPM Calculation Guide

## Overview

This skill provides calculation utilities for CDPM (Cetus DLMM Position Manager) using the **Cetus DLMM SDK**. All calculations should use the SDK for accuracy and to handle edge cases properly.

## Installation

```bash
npm install @cetusprotocol/dlmm-sdk
```

## SDK Imports

```typescript
import { BinUtils, FeeUtils } from '@cetusprotocol/dlmm-sdk/utils'
```

---

## Topics

### Core Calculations
- **[Liquidity Calculation](reference/liquidity-calculation.md)** - Constant sum formula, calculate liquidity, get amounts
- **[Bin Price Calculations](reference/bin-price-calculations.md)** - Bin ID from price, price from bin ID, Q64x64 price
- **[Position Management](reference/position-management.md)** - Position count, split bins into positions
- **[Fee Calculations](reference/fee-calculations.md)** - Variable fee, protocol fee, composition fee

### Advanced Topics
- **[Price Conversion](reference/price-conversion.md)** - Compare CDPM prices with external exchanges

### Reference
- **[Token Constants](reference/token-constants.md)** - Common token addresses
- **[SDK Constants](reference/sdk-constants.md)** - SDK configuration constants
- **[Error Reference](reference/error-reference.md)** - Common errors and solutions

---

## Complete Examples

### Example 1: Create Position Calculation

```typescript
import { BinUtils } from '@cetusprotocol/dlmm-sdk/utils'

async function calculatePosition(
  poolInfo: { bin_step: number; active_bin_id: number },
  tokenADecimals: number,
  tokenBDecimals: number,
  depositA: string,
  depositB: string,
  slippagePercent: number
) {
  const { bin_step, active_bin_id } = poolInfo
  
  // 1. Get current price
  const currentPrice = BinUtils.getPriceFromBinId(
    active_bin_id,
    bin_step,
    tokenADecimals,
    tokenBDecimals
  )
  
  // 2. Calculate price range with slippage
  const minPrice = (parseFloat(currentPrice) * (1 - slippagePercent / 100)).toString()
  const maxPrice = (parseFloat(currentPrice) * (1 + slippagePercent / 100)).toString()
  
  // 3. Get bin IDs
  const lowerBinId = BinUtils.getBinIdFromPrice(
    minPrice, bin_step, true, tokenADecimals, tokenBDecimals
  )
  const upperBinId = BinUtils.getBinIdFromPrice(
    maxPrice, bin_step, false, tokenADecimals, tokenBDecimals
  )
  
  // 4. Calculate position count
  const positionCount = BinUtils.getPositionCount(lowerBinId, upperBinId)
  
  // 5. Distribute liquidity
  const binCount = upperBinId - lowerBinId + 1
  const amountAPerBin = (BigInt(depositA) / BigInt(binCount)).toString()
  const amountBPerBin = (BigInt(depositB) / BigInt(binCount)).toString()
  
  // 6. Calculate total liquidity
  const activeQPrice = BinUtils.getQPriceFromId(active_bin_id, bin_step)
  const totalLiquidity = BinUtils.getLiquidity(depositA, depositB, activeQPrice)
  
  return {
    lowerBinId,
    upperBinId,
    positionCount,
    totalLiquidity,
    bins: Array.from({ length: binCount }, (_, i) => ({
      binId: lowerBinId + i,
      amountA: amountAPerBin,
      amountB: amountBPerBin
    }))
  }
}
```

### Example 2: Remove Liquidity Calculation

```typescript
function calculateRemoval(
  positionBins: Array<{
    binId: number
    amountA: string
    amountB: string
    liquidity: string
  }>,
  percentage: number  // 0-100
): Array<{ binId: number; amountA: string; amountB: string }> {
  const results = []
  
  for (const bin of positionBins) {
    const removeLiquidity = (BigInt(bin.liquidity) * BigInt(percentage) / 100n).toString()
    
    const { amount_a, amount_b } = BinUtils.calculateOutByShare(
      { amount_a: bin.amountA, amount_b: bin.amountB, liquidity: bin.liquidity },
      removeLiquidity
    )
    
    results.push({
      binId: bin.binId,
      amountA: amount_a,
      amountB: amount_b
    })
  }
  
  return results
}
```

### Example 3: Rebalancing Calculation

```typescript
async function calculateRebalance(
  currentBins: Array<{ binId: number; liquidity: string }>,
  targetActiveBinId: number,
  rangeWidth: number,
  binStep: number
) {
  const lowerBinId = targetActiveBinId - rangeWidth
  const upperBinId = targetActiveBinId + rangeWidth
  
  // 1. Calculate total liquidity
  let totalLiquidity = 0n
  for (const bin of currentBins) {
    totalLiquidity += BigInt(bin.liquidity)
  }
  
  // 2. Calculate new distribution
  const targetBinCount = rangeWidth * 2 + 1
  const liquidityPerBin = (totalLiquidity / BigInt(targetBinCount)).toString()
  
  // 3. Get amounts needed for each bin
  const targetBins = []
  for (let i = 0; i < targetBinCount; i++) {
    const binId = lowerBinId + i
    const qPrice = BinUtils.getQPriceFromId(binId, binStep)
    
    // For equal distribution, amounts depend on price
    // amount_a = liquidity / (2 * price), amount_b = liquidity / 2
    const amountA = (BigInt(liquidityPerBin) / (2n * BigInt(qPrice) >> 64n)).toString()
    const amountB = (BigInt(liquidityPerBin) / 2n).toString()
    
    targetBins.push({ binId, amountA, amountB, liquidity: liquidityPerBin })
  }
  
  // 4. Calculate positions needed
  const positionCount = BinUtils.getPositionCount(lowerBinId, upperBinId)
  
  return { targetBins, positionCount }
}
```

---

## Best Practices

### 1. Always Use SDK Utils

```typescript
// ✅ Good - Use SDK
import { BinUtils } from '@cetusprotocol/dlmm-sdk/utils'
const liquidity = BinUtils.getLiquidity(amountA, amountB, qPrice)

// ❌ Bad - Manual calculation
const liquidity = (BigInt(price) * BigInt(amountA)) + (BigInt(amountB) << 64n)
```

### 2. Pass Amounts as Strings

```typescript
// ✅ Good - String format
const liquidity = BinUtils.getLiquidity('1000000', '1200000', qPrice)

// ❌ Bad - Number format (precision loss)
const liquidity = BinUtils.getLiquidity(1000000, 1200000, qPrice)
```

### 3. Cache QPrice

```typescript
// ✅ Good - Cache QPrice
const qPriceCache = new Map()
function getCachedQPrice(binId: number, binStep: number) {
  const key = `${binId}-${binStep}`
  if (!qPriceCache.has(key)) {
    qPriceCache.set(key, BinUtils.getQPriceFromId(binId, binStep))
  }
  return qPriceCache.get(key)
}
```

### 4. Validate Inputs

```typescript
function validateBinRange(lowerBinId: number, upperBinId: number) {
  if (lowerBinId >= upperBinId) {
    throw new Error('Invalid range: lower must be less than upper')
  }
  if (upperBinId - lowerBinId > 1000) {
    throw new Error('Range too large: max 1000 bins')
  }
}
```

### 5. Handle Errors

```typescript
try {
  const binId = BinUtils.getBinIdFromPrice(price, binStep, true, decimalsA, decimalsB)
} catch (error) {
  console.error('Failed to calculate bin ID:', error)
  // Fallback or retry logic
}
```

---

## Related Skills

- `cdpm-user-sdk` - User operations guide
- `cdpm-agent-sdk` - Agent automation strategies
- `cdpm-protocol-sdk` - Protocol integration guide
- `cetus-dlmm-sdk-skill` - Full Cetus DLMM SDK documentation
