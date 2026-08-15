# Permission System

## Contents

- [Permission Matrix](#permission-matrix)
- [Protocol Access Requirements](#protocol-access-requirements)
- [Fee Mechanics](#fee-mechanics)

## Permission Matrix

| Operation | Owner | Agent | Protocol | Admin |
|-----------|-------|-------|----------|-------|
| Create PositionManager (`user_deposit_liquidity` / `user_deposit_position`) | yes | no | no | no |
| `user_add_liquidity_to_position` / `user_add_liquidity_to_balance` | yes | no | no | no |
| `user_remove_liquidity_from_position` / `user_remove_liquidity_from_balance` | yes | no | no | no |
| `user_collect_fee` / `user_collect_reward` (returns coin directly) | yes | no | no | no |
| `user_withdraw_fee` | yes | no | no | no |
| `user_insert_agent` / `user_remove_agent` | yes | no | no | no |
| `user_close_pm` (requires `pm.balance`, `pm.fee`, `pm.lending` empty and no Cetus rewards owed) | yes | no | no | no |
| `agent_add_liquidity` / `agent_remove_liquidity` | no | yes | no | no |
| `agent_create_position` / `agent_destroy_position` | no | yes | no | no |
| `agent_collect_fee` / `agent_collect_reward` (routes coin into `pm.fee`) | no | yes | no | no |
| `agent_transfer_fee_to_balance` | no | yes | no | no |
| `protocol_add_liquidity` / `protocol_remove_liquidity` | no | no | yes\* | no |
| `protocol_collect_fee` / `protocol_collect_reward` | no | no | yes\* | no |
| `protocol_transfer_fee_to_balance` | no | no | yes\* | no |
| `scallop_supply<T>` / `scallop_redeem<T>` | yes | yes | yes\* | no |
| `kai_supply<T, YT>` / `kai_redeem<T, ST, YT>` | yes | yes | yes\* | no |
| `admin_set_fee` (cap 50%) | no | no | no | yes |
| `admin_collect_fee` / `admin_collect_fee_return_coin` | no | no | no | yes |
| `admin_insert_access_list` / `admin_remove_access_list` | no | no | no | yes |
| `admin_transfer` (consumes the `AdminCap`) | no | no | no | yes |

\* Protocol-tier callers (whitelisted in `AccessList.allow`) additionally require `pm.agents` to be empty. The Scallop and Kai lending entries share the same gate via the `assert_caller_authorized` union.

## Protocol Access Requirements

Protocol-tier operations require:

1. Caller in `AccessList.allow`
2. `PositionManager.agents` is empty (no active agents)

This is enforced two different ways depending on the function:

- `protocol_*` functions (`protocol_add_liquidity`, `protocol_remove_liquidity`, `protocol_collect_fee`, `protocol_collect_reward`, `protocol_transfer_fee_to_balance`) check both conditions explicitly:
  ```move
  assert!(vec_set::contains(&access.allow, &ctx.sender()), ENotAllow);
  assert!(vec_set::is_empty(&pm.agents), ENotAllow);
  ```
- The Scallop and Kai lending entries (`scallop_supply`, `scallop_redeem`, `kai_supply`, `kai_redeem`) call `assert_caller_authorized(access, pm, ctx)`, which folds the protocol path into the union:
  ```
  is_owner || is_agent || (is_in_access_list && pm.agents.is_empty())
  ```

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

### Agent Position Lifecycle Gating

`agent_create_position` / `agent_destroy_position` are **agent-role-only**
(owner and protocol cannot call them). Both assert the caller is in
`pm.agents` (`ENotAllow`, 1002) plus a lifecycle-specific precondition:

- `agent_create_position` — `pm.position` must be `None`
  (`EPositionAlreadyExists`, 1010) and the passed pool must equal
  `pm.pool_id` (`EWrongPool`, 1012).
- `agent_destroy_position` — `pm.position` must be `Some`
  (`ENoPosition`, 1011) and all Cetus rewards must be collected first
  (`EPositionHasRewards`, 1007).

The protocol tier operates on PMs whose `position` is managed by the agent;
protocol liquidity operations assert `ENoPosition` if the position was
destroyed.

## Fee Mechanics

### Fee Calculation

```typescript
const FEE_DENOMINATOR = 10000;  // matches cdpm::FEE_DENOMINATOR
const MAX_FEE_RATE    = 5000;   // matches cdpm::MAX_FEE_RATE (50%)

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
User collects 100 USDC via user_collect_fee
→ Coin<T> is returned to the caller (no fee deducted)
→ Protocol receives: 0 USDC
```

#### Protocol Management — `protocol_collect_fee` / `protocol_collect_reward`

`take_fee` deducts `floor(gross × fee_house.fee_rate / 10_000)` from the gross collection and routes it to `fee_house.fee[T]`; the remainder is added to `pm.fee[T]`.

```
Protocol collects 100 USDC (20% fee rate)
→ pm.fee[USDC] += 80 USDC
→ fee_house.fee[USDC] += 20 USDC
```

#### Agent Management — `agent_collect_fee` / `agent_collect_reward`

The full gross collection lands in `pm.fee[T]`; no protocol fee is taken.

```
Agent collects 100 USDC
→ pm.fee[USDC] += 100 USDC
→ Protocol receives: 0 USDC
```

#### Lending Yield Fee — Scallop and Kai (any caller)

`scallop_redeem` and `kai_redeem` apply the **same** yield-fee model. The protocol cut is taken from the interest portion only and never from principal:

```
principal_portion = floor(vault.principal × want_amount / total_share)
interest          = max(0, redeemed_amount − principal_portion)
fee_amount        = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance     = redeemed_amount − fee_amount
```

`total_share` is `S_total` (sCoin) on Scallop and `YT_total` on Kai. The single `fee_house.fee_rate` is shared across both integrations.
