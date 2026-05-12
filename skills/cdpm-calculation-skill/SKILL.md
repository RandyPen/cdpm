---
name: cdpm-calculation-skill
description: CDPM calculation utilities using Cetus DLMM SDK plus the Scallop and Kai SAV lending math used by scallop_start_supply / scallop_start_redeem / scallop_finish_redeem and their Kai counterparts. Provides liquidity calculation, bin price math, position management, fee calculations, and yield-fee accounting for both lending integrations. Use when performing mathematical operations for CDPM positions.
---

# CDPM Calculation Guide

## Overview

This skill provides calculation utilities for CDPM (Cetus DLMM Position Manager) using the **Cetus DLMM SDK**, plus off-chain twins of **both** lending integrations' math the cdpm contract performs on-chain — Scallop (`scallop_*`) and Kai SAV (`kai_*`). All Cetus calculations should use the SDK for accuracy and to handle edge cases properly; the Scallop and Kai formulas mirror the on-chain implementations in `sources/cdpm.move`. The two integrations share `pm.lending: Bag`, the hot-potato ticket pattern, and a single `fee_house.fee_rate` knob, so the principal-amortization and yield-fee math is structurally identical — only the `compute_expected_*` predictors differ (Scallop reads `balance_sheet`, Kai reads `total_available_balance` + `total_yt_supply`).

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
- **[Strategy Distributions](reference/strategy-distributions.md)** - `Spot` / `Curve` / `BidAsk` weight formulas (`MAX=2000`, `MIN=200`), per-bin shape (flat / bell / U), bid-vs-ask side coin assignment, single-sided fallback when `active_id` is outside the range, raw-weight inspection via `WeightUtils.toWeight*`, full `BinLiquidityInfo` via `StrategyUtils.toAmountsBothSideByStrategy` / `autoFillCoinByStrategy`, and the `use_bin_infos` flag trade-off
- **[Bin Price Calculations](reference/bin-price-calculations.md)** - Bin ID from price, price from bin ID, Q64x64 price
- **[Position Management](reference/position-management.md)** - Position count, split bins into positions
- **[Fee Calculations](reference/fee-calculations.md)** - Variable fee, protocol fee, composition fee
- **[Position Query](reference/position-query.md)** - Query PositionManager assets, fees, and rewards
- **[Scallop Lending Math](reference/scallop-lending-math.md)** - Expected sCoin / underlying, principal amortization, yield-fee deduction, **redemption sizing** (inverse formulas: sCoin to burn for target underlying / target net-after-fee, with worked example), **live supply APY query** via `@scallop-io/sui-scallop-sdk` (`getMarketPool` returning `MarketPool | undefined`, supply-only field subset with raw-vs-decimaled split clarified), **canonical Scallop-vs-Kai supply picker** that returns `{ venue: 'scallop' | 'kai' | 'idle', apy, detail }`, and **granular PTB-builder hooks** (`txBlock.deposit` / `txBlock.withdraw` accept tx-result coins and slot inside cdpm's hot-potato; mint/redeem auto-accrue interest internally)
- **[Kai SAV Lending Math](reference/kai-lending-math.md)** - Expected YT / underlying for Kai's `<T, YT>` vault, principal amortization, yield-fee deduction, **redemption sizing** (inverse formulas: YT to burn for target underlying / target net-after-fee, with worked example, plus `vault.withdrawTAmt` as an on-chain inverse-sizing alternative for full-drain flows), **live vault APY query** via `@kunalabs-io/kai` (`VAULTS` mainnet-only map with `paused_*` warning, `getVaultStats` returning `{ tvl, apr, apy }` with `apy = exp(apr) − 1`), supply-side half of the cross-protocol picker; plus the SDK's `vault.deposit` / `vault.withdraw` (auto-walks all registered strategies — `getStrategies` returns a static descriptor list) that composes into cdpm's hot-potato PTB
- **[Cross-Protocol PTB (cdpm + Scallop + Kai)](reference/cross-protocol-ptb.md)** - **Canonical Mysten-rooted shared-`Transaction` pattern** for composing cdpm hot-potato calls with Scallop SDK builders and Kai SDK builders into a single atomic PTB. Multi-approach comparison (raw `tx.moveCall` vs Mysten-rooted vs Scallop-rooted vs separate-PTB vs pure-SDK) with viability and trade-off table; worked single-protocol supply examples for both venues; **atomic Scallop ↔ Kai rebalance** in one PTB (both directions, with code); five integration caveats (sign with `tx` not `scallopTx`; `setSender` before `*Quick`; pin `@mysten/sui` to one major so `instanceof Transaction` adoption works; never feed `*Quick` outputs into cdpm finishes; re-snapshot inputs before signing); SDK file:line reference appendix

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
