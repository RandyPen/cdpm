# Permission System

## Permission Matrix

| Operation | Owner | Agent | Protocol | Admin |
|-----------|-------|-------|----------|-------|
| Create Position | yes | no | no | no |
| Add/Remove Liquidity | yes | yes | yes* | no |
| Collect Fees/Rewards | yes | yes (to fee bag) | yes* | no |
| Withdraw Funds | yes | no | no | no |
| Manage Agents | yes | no | no | no |
| Scallop `scallop_start_supply` / `scallop_start_redeem` | yes | yes | yes* | no |
| Scallop `scallop_finish_supply` / `scallop_finish_redeem` | yes | yes | yes* | no |
| `user_extract_scallop_market_coin<T>` | yes | no | no | no |
| Kai `kai_start_supply` / `kai_start_redeem` | yes | yes | yes* | no |
| Kai `kai_finish_supply` / `kai_finish_redeem` | yes | yes | yes* | no |
| `user_extract_kai_yt<T, YT>` | yes | no | no | no |
| `user_close_pm` (requires `pm.lending` empty — Scallop AND Kai entries) | yes | no | no | no |
| Set Fee Rate (cap 30%) | no | no | no | yes |
| Collect Protocol Fees | no | no | no | yes |
| Manage AccessList | no | no | no | yes |

\* Protocol-tier callers (whitelisted in `AccessList.allow`) additionally require `pm.agents` to be empty. Agents and protocol bots share the Scallop AND Kai hot-potato APIs with the owner — `start_*` runs `assert_caller_authorized`, `finish_*` only checks ticket integrity.

## Protocol Access Requirements

Protocol-tier operations require:
1. Caller in `AccessList.allow`
2. `PositionManager.agents` is empty (no active agents)

This is enforced two different ways depending on the function:

- `protocol_*` Cetus operations (`protocol_add_liquidity`, `protocol_remove_liquidity`, `protocol_collect_fee`, `protocol_collect_reward`, `protocol_transfer_fee_to_balance`) check both conditions explicitly with `assert!(vec_set::contains(...) && vec_set::is_empty(&pm.agents))`.
- The Scallop and Kai hot-potato entry points (`scallop_start_supply`, `scallop_start_redeem`, `kai_start_supply`, `kai_start_redeem`) call `assert_caller_authorized(access, pm, ctx)`, which folds the protocol path into the same union: `is_owner || is_agent || (is_in_access_list && pm.agents.is_empty())`. The four `*_finish_*` functions only verify `ticket.pm_id == object::id(pm)`; they do not re-check authorization.

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

#### Lending Yield Fee — Scallop AND Kai (any caller)

`scallop_finish_redeem` and `kai_finish_redeem` use the **same** fee path — the protocol cut comes from the **interest portion only** and never from principal:

```
interest         = max(0, redeemed_amount − principal_portion)
fee_amount       = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance    = redeemed_amount − fee_amount
```

This applies regardless of who initiated the redeem (owner / agent / protocol) and regardless of which lending integration (Scallop or Kai). `principal_portion` is computed in `pull_from_scallop_lending` as `floor(P_total × scoin_burned / S_total)` and analogously in `pull_from_kai_lending` as `floor(P_total × yt_burned / YT_total)`. The single `fee_house.fee_rate` is shared across both integrations — there is no separate Kai fee rate.
