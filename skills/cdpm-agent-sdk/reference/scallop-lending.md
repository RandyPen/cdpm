# Scallop Lending — Agent Operations

## Contents

- [Agent Move Call: Supply](#agent-move-call-supply)
- [Agent Move Call: Redeem (with yield-fee deduction)](#agent-move-call-redeem-with-yield-fee-deduction)
- [When to Call `scallop_supply` vs Leave Funds Idle](#when-to-call-scallop_supply-vs-leave-funds-idle)
- [Sizing Redemptions](#sizing-redemptions)
- [Failure Modes](#failure-modes)
- [Choosing Between Scallop and Kai for the Same `T`](#choosing-between-scallop-and-kai-for-the-same-t)
- [Event Subscription](#event-subscription)

## Agent Move Call: Supply

Authoritative signature:

```move
public fun scallop_supply<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    version: &ScallopVersion,
    market: &mut Market,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);
```

One `tx.moveCall`:

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function agentSupplyToScallop(
  client: SuiGrpcClient,
  agentSigner: any,
  pmId: string,
  underlyingCoinType: string,
  amount: bigint,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::scallop_supply`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.pure.u64(amount),
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer: agentSigner, transaction: tx });
}
```

`scallop_supply` decreases `pm.balance[T]` by `amount`, calls Scallop's `protocol::mint::mint<T>` internally, and stores the resulting `Balance<MarketCoin<T>>` plus the principal under the bag key `type_name<T>`. The first supply for a given `T` creates a fresh `ScallopVault<T>` entry; subsequent supplies of the same `T` add to it.

Scallop's `mint::mint` calls `accrue_interest_for_market` as its first step, so the balance sheet read by the mint is fresh by construction. The cdpm agent does not need to inject a separate accrual command.

**`MAX_U64` is a "drain whatever's there" sentinel.** `scallop_supply` pulls the underlying via the internal `withdraw_from_balance<T>` helper, which clamps `amount >= balance_amount` and removes the bag entry. Passing `tx.pure.u64(MAX_U64)` consumes the entire `pm.balance[T]` entry. Use an explicit sized `amount` only when you intentionally want to leave a residual in `pm.balance[T]`.

**Don't accidentally re-supply your own redeem proceeds.** A common agent bug: redeem from Scallop, then immediately re-supply the post-fee underlying back into the same market. Each round trip pays a yield fee on the interest portion, so churn is expensive. Track time-since-last-redeem and amortize.

---

## Agent Move Call: Redeem (with yield-fee deduction)

Redeem deducts the protocol yield fee from the **interest portion only**, never from principal:

```
principal_portion = floor(vault.principal × want_amount / total_share)
interest          = max(0, redeemed_amount − principal_portion)
fee_amount        = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance     = redeemed_amount − fee_amount
```

`principal_portion` is the slice of stored principal proportional to the burned sCoin (see `pull_from_scallop_lending`).

Authoritative signature:

```move
public fun scallop_redeem<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    version: &ScallopVersion,
    market: &mut Market,
    scoin_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);
```

One `tx.moveCall`:

```typescript
async function agentRedeemFromScallop(
  client: SuiGrpcClient,
  agentSigner: any,
  pmId: string,
  underlyingCoinType: string,
  scoinAmount: bigint,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::scallop_redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.pure.u64(scoinAmount),
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer: agentSigner, transaction: tx });
}
```

Scallop's `redeem::redeem` calls `accrue_interest_for_market` as its first step, so the balance sheet is fresh at the moment of redemption.

**`scoin_amount = MAX_U64` drains the full vault entry.** When `want_amount >= total_scoin`, `pull_from_scallop_lending` removes the `ScallopVault<T>` entry from `pm.lending` and returns the entire stored `Balance<MarketCoin<T>>` plus all stored principal. Use this sentinel when closing out a position entirely; use an explicit sized amount for partial redeems.

### Sizing Redemptions

Agent bots typically know "I need `K` underlying to fund a rebalance" and must compute `scoin_amount` from that. `scallop_redeem` takes sCoin, not underlying, so the bot inverts Scallop's `redeem` formula and the yield-fee deduction before signing.

- **Pre-fee target** — at least `K` underlying delivered by Scallop, ignoring fee:

  ```
  scoin_to_burn = ceil(K × supply / denom)            // denom = cash + debt − revenue
  ```

- **Post-fee target** — at least `K` net underlying credited to `pm.balance[T]`:

  ```
  Let r = fee_rate / 10000, π = P_vault / S_vault, p = denom / supply
  scoin_to_burn ≈ ceil(K / (p × (1 − r) + r × π))     when p >  π   (interest exists)
  scoin_to_burn  = ceil(K × supply / denom)           when p <= π   (no interest, no fee)
  ```

Both use **ceiling division** because Scallop's redeem floors the underlying output. The full derivation and an iterative refinement helper live in [`cdpm-calculation-skill/reference/scallop-lending-math.md`](../../cdpm-calculation-skill/reference/scallop-lending-math.md) section 7.

```typescript
import { scoinToBurnForTargetNet } from './scallop-lending-math';

async function agentRedeemForTargetNet(
  client: SuiGrpcClient,
  agentSigner: any,
  pmId: string,
  underlyingCoinType: string,
  desiredNet: bigint,
  feeRateBp: bigint,
  reserveSnapshot: ScallopReserveSnapshot,
  pmScallopVault: ScallopPmVaultSnapshot,
) {
  const scoinAmount = scoinToBurnForTargetNet(
    reserveSnapshot, pmScallopVault, desiredNet, feeRateBp,
  );

  return agentRedeemFromScallop(
    client, agentSigner, pmId,
    underlyingCoinType, scoinAmount,
  );
}
```

Re-snapshot the reserve and vault state just before signing — utilization-driven `denom` shifts every block, and stale snapshots can leave the bot 1-2 underlying short.

---

## When to Call `scallop_supply` vs Leave Funds Idle

Yield-vs-gas tradeoff:

- **Supply when** the idle balance is large enough that the projected interest over the expected idle window exceeds the round-trip gas (one `tx.moveCall` per direction). For Sui mainnet this is usually a few hundred USDC at 5%+ supply APY held for >12 hours.
- **Stay idle when** the position is about to be rebalanced (next add/remove liquidity is queued in <1 hour) — the round-trip yield will not cover the supply+redeem gas.
- **Always supply** when `pm.balance[T]` accumulates from `agent_transfer_fee_to_balance` and is not earmarked for an immediate use; even a few hours of yield are pure upside vs holding.

---

## Constraints

- **One vault per underlying T**: `pm.lending` keys on `type_name<T>`. The sCoin type is structurally pinned to `MarketCoin<T>` by the type system, so a fake-sCoin variant cannot be supplied.
- **Yield fee applies to agents**: `scallop_redeem` computes `fee_amount = floor(max(0, redeemed − principal_portion) × fee_house.fee_rate / 10_000)` regardless of caller. Agent redeems pay the same yield fee as owner / protocol redeems.
- **No wrapper-extract escape**: cdpm exposes no function that hands raw `Coin<MarketCoin<T>>` out of `pm.lending`. The only exit path is `scallop_redeem`. If Scallop's `mint::mint` or `redeem::redeem` aborts (paused market, Version mismatch), the cdpm move call aborts atomically and `pm.lending` stays intact. Recovery is to retry once Scallop ships an SDK update against the new Version.
- **Trust boundary**: Scallop's UpgradeCap is held by Scallop's admin. A malicious Scallop upgrade could in principle reduce yield or break the redeem path, but cannot withdraw cdpm-held `Balance<MarketCoin<T>>` because cdpm pins the sCoin type structurally.

---

## Failure Modes

| Code | Constant | Trigger | Recovery |
|------|----------|---------|----------|
| 1001 | `ENotOwner` | Agent attempted an owner-only function (e.g. `user_close_pm`). | Escalate to owner. |
| 1002 | `ENotAllow` | Agent address not in `pm.agents`. | Re-check `pm.agents` before retry. |
| 1005 | `ENoSuchVault` | `scallop_redeem` for a `T` that has never been supplied (or was fully drained). | Snapshot `pm.lending` before sizing. |
| 1006 | `ENoSuchBalance` | `scallop_supply` for a `T` that has no entry in `pm.balance`. | Verify `pm.balance` has the underlying before signing. |

External aborts (from Scallop itself, not cdpm): `protocol::version` mismatch after a Scallop upgrade, or a `protocol::market` pause. Because `scallop_supply` / `scallop_redeem` are atomic single `tx.moveCall`s, any internal abort rolls back the whole transaction and `pm.lending` plus `pm.balance` stay intact. Pause Scallop ops on this market until upstream is healthy; once Scallop ships an SDK update against the new Version, retry the normal flow.

---

## Choosing Between Scallop and Kai for the Same `T`

Both integrations can hold the same underlying `T` simultaneously (the bag keys differ — `type_name<T>` for Scallop, `type_name<YT>` for Kai). When an agent has a free choice of where to park USDC:

| Factor | Prefer Scallop | Prefer Kai |
|--------|----------------|------------|
| Move call shape | One `tx.moveCall` per direction | One `tx.moveCall` per direction |
| Yield curve | Money-market APY (utilization-driven) | Aggregated strategies (often higher net of fees) |
| Withdrawal liquidity | Limited by `cash` (instant if available) | Limited by `total_available_balance` minus locked strategy capital |
| Failure surface | Scallop pause / version bump | Kai admin disabling withdrawals, strategy losses, rate limits |

Default heuristic: if Kai has a `Vault<T, YT>` available for the underlying, prefer Kai for **long-idle balance** (>1 day expected hold) because the strategy diversification usually pays off. Prefer Scallop for **short-idle balance** (<1 day). For mid-sized rebalances, split 50/50 across both — the bag-key disambiguation makes coexistence cost nothing.

The yield-fee deduction is identical across both; the same `fee_house.fee_rate` knob covers both integrations. Cross-reference: the agent-flavored Kai page is [`kai-lending.md`](./kai-lending.md).

---

## Event Subscription

Agents should subscribe to the Scallop-lending events alongside Kai's:

```typescript
interface ScallopSupplied {
  pm_id: string;
  coin_type: string;
  deposit_amount: string;
  market_coin_minted: string;
}

interface ScallopRedeemed {
  pm_id: string;
  coin_type: string;
  market_coin_redeemed: string;
  redeemed_amount: string;
  principal_portion: string;
  interest: string;
  fee_amount: string;
}
```

The only exit-related event on the Scallop side is `ScallopRedeemed`, emitted by `scallop_redeem` once the underlying lands in `pm.balance`. cdpm emits no separate extraction event — there is no extraction function.
