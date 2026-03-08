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
