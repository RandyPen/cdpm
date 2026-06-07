# Kai SAV Lending — Agent Operations

## Contents

- [Agent Move Call: Supply](#agent-move-call-supply)
- [Agent Move Call: Redeem](#agent-move-call-redeem)
- [Sizing Redemptions](#sizing-redemptions)
- [What Agents CANNOT Do With Kai](#what-agents-cannot-do-with-kai)
- [Event Subscription](#event-subscription)
- [Error Cheat Sheet](#error-cheat-sheet)

## Agent Move Call: Supply

Authoritative signature:

```move
public fun kai_supply<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &mut kai_vault::Vault<T, YT>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);
```

One `tx.moveCall`:

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function agentSupplyToKai(
  client: SuiGrpcClient,
  agentSigner: any,
  pmId: string,
  underlyingCoinType: string,
  ytCoinType: string,
  vaultObjectId: string,
  amount: bigint,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_supply`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(vaultObjectId),
      tx.pure.u64(amount),
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer: agentSigner, transaction: tx });
}
```

`kai_supply` decreases `pm.balance[T]` by `amount`, calls `kai_vault::deposit<T, YT>` internally, and stores the resulting `Balance<YT>` plus the principal under the bag key `type_name<YT>`. The first supply for a given `(T, YT)` creates a fresh `KaiVault<T, YT>` entry; subsequent supplies of the same pair add to it.

**`MAX_U64` is a "drain whatever's there" sentinel.** `kai_supply` pulls the underlying via the internal `withdraw_from_balance<T>` helper, which clamps `amount >= balance_amount` and removes the bag entry. Passing `tx.pure.u64(MAX_U64)` consumes the entire `pm.balance[T]` entry. Use an explicit sized `amount` only when you intentionally want to leave a residual in `pm.balance[T]`.

**Don't accidentally re-supply your own redeem proceeds.** A common agent bug: redeem from Kai, then immediately re-supply the post-fee underlying back into the same vault. Each round trip pays a yield fee on the interest portion, so churn is expensive. Track time-since-last-redeem and amortize.

---

## Agent Move Call: Redeem

`kai_redeem` is a single `tx.moveCall` that walks the Kai withdrawal chain internally:

```
vault::withdraw → klsp::withdraw → vault::redeem_withdraw_ticket
```

The yield fee is deducted from the **interest portion only** (never from principal):

```
principal_portion = floor(vault.principal × yt_amount / total_share)
interest          = max(0, redeemed_amount − principal_portion)
fee_amount        = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance     = redeemed_amount − fee_amount
```

The function is generic over the kai_leverage_supply_pool strategy `<T, ST, YT>` since every production Kai vault uses that strategy.

Authoritative signature:

```move
public fun kai_redeem<T, ST, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    vault: &mut kai_vault::Vault<T, YT>,
    strategy: &mut klsp::Strategy<T, ST>,
    supply_pool: &mut SupplyPool<T, ST>,
    yt_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);
```

One `tx.moveCall`:

```typescript
async function agentRedeemFromKai(
  client: SuiGrpcClient,
  agentSigner: any,
  pmId: string,
  underlyingCoinType: string,
  shareCoinType: string,     // ST — the supply-pool share type
  ytCoinType: string,
  vaultObjectId: string,
  strategyObjectId: string,
  supplyPoolObjectId: string,
  ytAmount: bigint,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_redeem`,
    typeArguments: [underlyingCoinType, shareCoinType, ytCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
      tx.object(vaultObjectId),
      tx.object(strategyObjectId),
      tx.object(supplyPoolObjectId),
      tx.pure.u64(ytAmount),
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer: agentSigner, transaction: tx });
}
```

**`yt_amount = MAX_U64` drains the full vault entry.** When `want_amount >= total_yt`, `pull_from_kai_lending` removes the `KaiVault<T, YT>` entry from `pm.lending` and returns the entire stored `Balance<YT>` plus all stored principal. Use this sentinel when closing out a position entirely; use an explicit sized amount for partial redeems.

---

## Sizing Redemptions

Agent bots typically know "I need `K` underlying to fund a rebalance" and must compute `yt_amount` from that. `kai_redeem` takes YT, not underlying, so the bot inverts Kai's withdrawal formula and the yield-fee deduction before signing.

- **Pre-fee target** — at least `K` underlying out of Kai, ignoring fee:

  ```
  yt_to_burn = ceil(K × yt_supply / total_available_balance)
  ```

- **Post-fee target** — at least `K` net underlying credited to `pm.balance[T]` after the yield fee (interest-exists branch):

  ```
  yt_to_burn ≈ ceil(K × 10000 × yt_supply × YT_in_pm
                    / ((10000 − r_bp) × total_available × YT_in_pm + r_bp × yt_supply × P_in_pm))
  ```

Both use **ceiling division**. The full derivation, edge cases, and an iterative refinement helper (`ytToBurnForTargetNet`) live in [`cdpm-calculation-skill/reference/kai-lending-math.md`](../../cdpm-calculation-skill/reference/kai-lending-math.md) section 7.

```typescript
import { ytToBurnForTargetNet } from './kai-lending-math';

async function agentRedeemForTargetNet(
  client: SuiGrpcClient,
  agentSigner: any,
  pmId: string,
  underlyingCoinType: string,
  shareCoinType: string,
  ytCoinType: string,
  vaultObjectId: string,
  strategyObjectId: string,
  supplyPoolObjectId: string,
  desiredNet: bigint,
  feeRateBp: bigint,
  vaultSnapshot: KaiVaultSnapshot,
  pmKaiVault: KaiPmVaultSnapshot,
) {
  const ytAmount = ytToBurnForTargetNet(
    vaultSnapshot, pmKaiVault, desiredNet, feeRateBp,
  );

  return agentRedeemFromKai(
    client, agentSigner, pmId,
    underlyingCoinType, shareCoinType, ytCoinType,
    vaultObjectId, strategyObjectId, supplyPoolObjectId,
    ytAmount,
  );
}
```

Re-snapshot the vault state just before signing — Kai's `total_available_balance` ticks every block as time-locked profit unlocks, and stale snapshots can leave the bot 1-2 underlying short.

---

## What Agents CANNOT Do With Kai

| Operation | Reason |
|-----------|--------|
| Pull raw `Coin<YT>` out of `pm.lending` | cdpm exposes no function that hands `Balance<YT>` out of `pm.lending`. The only exit path is `kai_redeem`. |
| Construct a fake `Vault<T, EvilYT>` | `kai_sav::vault::new` is `public(package)` — only Kai's modules can mint a `Vault`. |
| Mint `Coin<YT>` outside the vault | `YT`'s `TreasuryCap` is owned by `Vault<T, YT>`. cdpm holds `Balance<YT>` directly inside `pm.lending`; no caller-supplied YT enters the redeem path. |
| Skip the strategy walk | The strategy walk runs inside `kai_redeem`. Callers cannot bypass it. |

**Trust boundary.** Kai's UpgradeCap is held by Kai's admin. A malicious Kai upgrade could in principle reduce yield or break the redeem path, but cannot withdraw cdpm-held `Balance<YT>` because cdpm pins the YT type structurally. If Kai is unreachable (paused vault, withdrawals disabled), `kai_redeem` aborts atomically inside the inner Kai move call and `pm.lending` stays intact. Recovery is to retry once Kai ships an SDK update against the new Version.

---

## Event Subscription

Agents should subscribe to the Kai-lending events alongside Scallop's:

```typescript
interface KaiSupplied {
  pm_id: string;
  coin_type: string;
  yt_type: string;
  deposit_amount: string;
  yt_minted: string;
}

interface KaiRedeemed {
  pm_id: string;
  coin_type: string;
  yt_type: string;
  yt_burned: string;
  redeemed_amount: string;
  principal_portion: string;
  interest: string;
  fee_amount: string;
}
```

The only exit-related event on the Kai side is `KaiRedeemed`, emitted by `kai_redeem` once the underlying lands in `pm.balance`. cdpm emits no separate extraction event — there is no extraction function.

---

## Error Cheat Sheet

| Code | Constant | Most likely cause for an agent |
|------|----------|---------------------------------|
| 1001 | `ENotOwner` | Agent attempted an owner-only function (e.g. `user_close_pm`). Escalate to owner. |
| 1002 | `ENotAllow` | Agent address not in `pm.agents`. Re-check `pm.agents` before retry. |
| 1005 | `ENoSuchVault` | `kai_redeem` for a `(T, YT)` pair that has no entry in `pm.lending`. Snapshot `pm.lending` before sizing. |
| 1006 | `ENoSuchBalance` | `kai_supply` for a `T` that has no entry in `pm.balance`. Verify `pm.balance` has the underlying before signing. |
