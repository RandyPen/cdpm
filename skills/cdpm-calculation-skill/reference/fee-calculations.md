# Fee Calculations

## Import Fee Utils

```typescript
import { FeeUtils } from '@cetusprotocol/dlmm-sdk/utils'
```

## Calculate Variable Fee

```typescript
const variableFee = FeeUtils.getVariableFee({
  volatility_accumulator: '1000000',
  bin_step_config: {
    variable_fee_control: '500000',
    bin_step: 10
  }
})
console.log(`Variable fee: ${variableFee}`)
```

## Calculate Protocol Fee

```typescript
const protocolFee = FeeUtils.calculateProtocolFee('1000000', '100')  // 1%
console.log(`Protocol fee: ${protocolFee}`)
```

## Calculate Two-Token Protocol Fees

```typescript
const { protocol_fee_a, protocol_fee_b } = FeeUtils.getProtocolFees(
  '500000',   // Fee A
  '600000',   // Fee B
  '100'       // Protocol fee rate (1%)
)

console.log(`Protocol fees - A: ${protocol_fee_a}, B: ${protocol_fee_b}`)
```

## Calculate Composition Fee

```typescript
const compositionFee = FeeUtils.calculateCompositionFee(
  '1000000',  // Amount
  '3000'      // Total fee rate (0.3%)
)
```

## cdpm Protocol Fee (Cetus + Scallop)

cdpm uses a single `FeeHouse.fee_rate` (basis points, capped at 3000 = 30%) for two distinct paths:

1. **Cetus protocol-tier fee split** — `take_fee` inside `protocol_collect_fee` / `protocol_collect_reward` shaves the protocol cut off the gross collected balance:

   ```typescript
   const FEE_DENOMINATOR = 10_000n;
   const protocolCut = (grossAmount * BigInt(feeRateBp)) / FEE_DENOMINATOR;
   const userPortion = grossAmount - protocolCut;
   ```

2. **Scallop yield fee** — `scallop_finish_redeem` deducts only from the interest portion:

   ```typescript
   const interest   = redeemedAmount > principalPortion ? redeemedAmount - principalPortion : 0n;
   const yieldFee   = (interest * BigInt(feeRateBp)) / FEE_DENOMINATOR;
   const toBalance  = redeemedAmount - yieldFee;
   ```

Both formulas floor and share the same `feeRateBp`. See `reference/scallop-lending-math.md` for the full Scallop redeem prediction (principal amortization, `compute_expected_underlying_scallop`, end-to-end helper).
