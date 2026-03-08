# Permission System

## Permission Matrix

| Operation | Owner | Agent | Protocol | Admin |
|-----------|-------|-------|----------|-------|
| Create Position | ✓ | ✗ | ✗ | ✗ |
| Add/Remove Liquidity | ✓ | ✓ | ✓* | ✗ |
| Collect Fees/Rewards | ✓ | ✓† | ✓* | ✗ |
| Withdraw Funds | ✓ | ✗ | ✗ | ✗ |
| Manage Agents | ✓ | ✗ | ✗ | ✗ |
| Set Fee Rate | ✗ | ✗ | ✗ | ✓ |
| Collect Protocol Fees | ✗ | ✗ | ✗ | ✓ |
| Manage AccessList | ✗ | ✗ | ✗ | ✓ |

\* With protocol fee deduction
† To fee bag only

## Protocol Access Requirements

Protocol operations require:
1. Caller in `AccessList.allow`
2. `PositionManager.agents` is empty (no active agents)

```typescript
function canProtocolOperate(
  accessList: AccessList,
  pm: PositionManager,
  caller: string
): boolean {
  return accessList.allow.includes(caller) && 
         pm.agents.length === 0;
}
```

## Fee Mechanics

### Fee Calculation

```typescript
const FEE_DENOMINATOR = 10000;

function calculateProtocolFee(
  amount: bigint,
  feeRate: number
): bigint {
  return (amount * BigInt(feeRate)) / BigInt(FEE_DENOMINATOR);
}

// Example: 100 USDC with 20% fee rate
const amount = 100000000n;  // 100 USDC (6 decimals)
const feeRate = 2000;        // 20%
const protocolFee = calculateProtocolFee(amount, feeRate);
// Result: 20000000n (20 USDC)
const userAmount = amount - protocolFee;
// Result: 80000000n (80 USDC)
```

### Fee Distribution Scenarios

#### User Self-Management

```
User collects 100 USDC
→ User receives: 100 USDC (no fee)
→ Protocol receives: 0 USDC
```

#### Protocol Management

```
Protocol collects 100 USDC (20% fee rate)
→ User receives: 80 USDC (to fee bag)
→ Protocol receives: 20 USDC (to protocol fee bag)
```

#### Agent Management

```
Agent collects 100 USDC
→ User receives: 100 USDC (to fee bag)
→ Protocol receives: 0 USDC
```
