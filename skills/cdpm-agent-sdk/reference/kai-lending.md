# Kai SAV Lending — Agent Operations

cdpm exposes a second hot-potato lending integration alongside Scallop: **Kai SAV** (Strategy-Aggregating Vault). Agents authorized in `pm.agents` can drive supply / redeem against a Kai `Vault<T, YT>` exactly like they can against Scallop, paying the same yield fee on interest. The same `assert_caller_authorized` gate inside `kai_start_supply` / `kai_start_redeem` admits **owner**, **agent**, or **whitelisted protocol bot in agents-empty mode**. `kai_finish_*` only check `ticket.pm_id == object::id(pm)`.

This page is the agent-flavored counterpart to [`cdpm-user-sdk/reference/kai-lending.md`](../../cdpm-user-sdk/reference/kai-lending.md). It re-emphasizes:

- **Yield fee applies to agents.** `kai_finish_redeem` computes `fee_amount = floor(max(0, redeemed − principal_portion) × fee_house.fee_rate / 10_000)` regardless of caller, so agent-driven Kai redeems pay the same fee as owner / protocol redeems.
- **No escape hatch for lending.** cdpm does **not** expose a `user_extract_kai_yt`-style wrapper-extraction function for anyone — neither agents nor the owner. If Kai is unreachable (Version bump, withdrawals disabled, etc.) the abort happens inside the inner `vault::withdraw` / `redeem_withdraw_ticket` call before any cdpm `*_finish_*` command runs, so the hot-potato ticket is never consumed and `pm.lending` stays intact. Recovery is to retry the normal `kai_start_redeem` → `vault::withdraw` → `kai_finish_redeem` flow once Kunalabs ships an SDK update against the new Version; cdpm itself stays operational throughout.
- **Agents cannot short-change the vault.** `kai_finish_supply` requires `Coin<YT>` and asserts `actual >= ticket.expected_yt`. `YT`'s `TreasuryCap` is private to `kai_sav::vault::Vault<T, YT>`, so external code cannot mint a fake `Coin<YT>`. The same defence applies on redeem (`Coin<T>` only comes out of `vault::redeem_withdraw_ticket` after the strategy walk).
- **No pre-call accrual.** Unlike Scallop, Kai's vault auto-accounts time-locked profit via `tlb::max_withdrawable` inside `total_available_balance`, so the PTB does **not** need to start with an accrual command. cdpm's `compute_expected_yt` / `compute_expected_underlying_kai` read the same auto-accruing function the live `vault::deposit` / `vault::withdraw` use.
- **Canonical Vault binding (F-03 hardening).** `kai_start_*` records `vault_id = object::id(vault)` on the ticket; `kai_finish_*` re-takes `&kai_vault::Vault<T,YT>` and asserts the id matches, aborting with `EWrongVault (1013)`. Reuse the same `tx.object(vaultObjectId)` handle across `start_*` and `finish_*`.

---

## Agent PTB Recipe: Supply

Authoritative signatures:

```move
public fun kai_start_supply<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<T>, KaiSupplyTicket<T, YT>);

public fun kai_finish_supply<T, YT>(
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    ticket: KaiSupplyTicket<T, YT>,
    yt: Coin<YT>,
);
```

3 commands, no accrual prefix:

```
1. cdpm::kai_start_supply<T, YT>(access, pm, vault, amount, clock)        → (coin_t, ticket)
2. kai_sav::vault::deposit<T, YT>(vault, coin_t.into_balance(), clock)    → balance_yt
3. cdpm::kai_finish_supply<T, YT>(pm, vault, ticket, balance_yt.into_coin())
```

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

  const [coinT, ticket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_start_supply`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(vaultObjectId),
      tx.pure.u64(amount),
      tx.object('0x6'),
    ],
  });

  const balanceT = tx.moveCall({
    target: '0x2::coin::into_balance',
    typeArguments: [underlyingCoinType],
    arguments: [coinT],
  });
  const balanceYT = tx.moveCall({
    target: `${KAI_SAV_PACKAGE}::vault::deposit`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [tx.object(vaultObjectId), balanceT, tx.object('0x6')],
  });
  const coinYT = tx.moveCall({
    target: '0x2::coin::from_balance',
    typeArguments: [ytCoinType],
    arguments: [balanceYT],
  });

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_finish_supply`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [
      tx.object(pmId),
      tx.object(vaultObjectId),
      ticket,
      coinYT,
    ],
  });

  return await client.signAndExecuteTransaction({ signer: agentSigner, transaction: tx });
}
```

`kai_start_supply` decreases `pm.balance[T]` by `amount` and stores `principal` for later yield accounting under the bag key `type_name<YT>`. The first supply for a given `(T, YT)` creates a fresh `KaiVault<T, YT>` entry; subsequent supplies of the same pair add to it.

**`MAX_U64` is a "drain whatever's there" sentinel.** `kai_start_supply` pulls the underlying via the internal `withdraw_from_balance<T>` helper (`cdpm.move:1271-1286`), which clamps `amount >= balance_amount` and removes the bag entry; the post-clamp `coin.value()` is what feeds `compute_expected_yt`. So passing `tx.pure.u64(MAX_U64)` consumes the entire `pm.balance[T]` entry, and the only remaining abort path is `EZeroExpected (1007)` if the entry is empty / dust. This mirrors `protocol_transfer_fee_to_balance`, which uses the same sentinel today (the helper has identical clamp logic in `withdraw_from_fee`, `cdpm.move:1301-1316`). Prefer the sentinel for atomic-rebalance flows where you'd otherwise have to dev-inspect the redeem residual and refeed it as `amount`. Use an explicit sized `amount` only when you intentionally want to leave a residual in `pm.balance[T]`.

**Don't accidentally re-supply your own redeem proceeds.** A common agent bug: redeem from Kai, then immediately re-supply the post-fee underlying back into the same vault. Each round trip pays a yield fee on the interest portion, so churn is expensive. Track time-since-last-redeem and amortize.

---

## Agent PTB Recipe: Redeem (with strategy walk)

Kai's redeem is **multi-step**. `vault::withdraw` returns a `WithdrawTicket` recording how much each strategy must un-allocate. The PTB has to walk every strategy with non-zero `to_withdraw`, then settle with `vault::redeem_withdraw_ticket`. The off-chain SDK is responsible for enumerating the active strategies — cdpm does **not** track them.

Authoritative signatures:

```move
public fun kai_start_redeem<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    yt_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<YT>, KaiRedeemTicket<T, YT>);

public fun kai_finish_redeem<T, YT>(
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    fee_house: &mut FeeHouse,
    ticket: KaiRedeemTicket<T, YT>,
    underlying: Coin<T>,
    ctx: &mut TxContext,
);
```

```
1. cdpm::kai_start_redeem<T, YT>(access, pm, vault, yt_amount, clock)        → (coin_yt, ticket)
2. kai_sav::vault::withdraw<T, YT>(vault, coin_yt.into_balance(), clock)     → withdraw_ticket
3..3+N. for each strategy s with to_withdraw(s) > 0:
        <strategy_module>::strategy_withdraw_for_vault(strategy, vault, withdraw_ticket, ...)
3+N+1. balance_t = kai_sav::vault::redeem_withdraw_ticket<T, YT>(vault, withdraw_ticket)
3+N+2. cdpm::kai_finish_redeem<T, YT>(pm, vault, fee_house, ticket, balance_t.into_coin())
```

```typescript
async function agentRedeemFromKai(
  client: SuiGrpcClient,
  agentSigner: any,
  pmId: string,
  underlyingCoinType: string,
  ytCoinType: string,
  vaultObjectId: string,
  ytAmount: bigint,
  // Off-chain SDK enumerates active strategies attached to the live Vault<T, YT>
  // and returns one move-call descriptor per strategy with to_withdraw > 0.
  strategyWalkers: Array<{
    target: string;
    typeArguments: string[];
    extraArgs: (tx: Transaction, withdrawTicket: any) => any[];
  }>,
) {
  const tx = new Transaction();

  const [coinYT, ticket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_start_redeem`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(vaultObjectId),
      tx.pure.u64(ytAmount),
      tx.object('0x6'),
    ],
  });

  const balanceYT = tx.moveCall({
    target: '0x2::coin::into_balance',
    typeArguments: [ytCoinType],
    arguments: [coinYT],
  });
  const withdrawTicket = tx.moveCall({
    target: `${KAI_SAV_PACKAGE}::vault::withdraw`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [tx.object(vaultObjectId), balanceYT, tx.object('0x6')],
  });

  for (const walker of strategyWalkers) {
    tx.moveCall({
      target: walker.target,
      typeArguments: walker.typeArguments,
      arguments: walker.extraArgs(tx, withdrawTicket),
    });
  }

  const balanceT = tx.moveCall({
    target: `${KAI_SAV_PACKAGE}::vault::redeem_withdraw_ticket`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [tx.object(vaultObjectId), withdrawTicket],
  });
  const coinT = tx.moveCall({
    target: '0x2::coin::from_balance',
    typeArguments: [underlyingCoinType],
    arguments: [balanceT],
  });

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_finish_redeem`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [
      tx.object(pmId),
      tx.object(vaultObjectId),
      tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
      ticket,
      coinT,
    ],
  });

  return await client.signAndExecuteTransaction({ signer: agentSigner, transaction: tx });
}
```

Each `<strategy_module>::strategy_withdraw_for_vault` discharges its own `kai_leverage::access_management::ActionRequest` internally — the agent does **not** need to assemble or co-sign an `ActionRequest`. The strategy walk is just a sequence of move calls that the SDK constructs from the live vault snapshot.

### Sizing Redemptions Before Calling `kai_start_redeem`

Agent bots typically know "I need `K` underlying to fund a rebalance" and must compute `yt_amount` from that. `kai_start_redeem` takes YT, not underlying, so the bot has to invert `compute_expected_underlying_kai` (and the yield-fee deduction) before signing.

- **Pre-fee target** — I need at least `K` underlying out of Kai, ignoring fee:

  ```
  yt_to_burn = ceil(K × yt_supply / total_available_balance)
  ```

- **Post-fee target** — I want `K` net to land in `pm.balance[T]` after the yield fee. Closed-form (interest-exists branch):

  ```
  yt_to_burn ≈ ceil(K × 10000 × yt_supply × YT_in_pm
                    / ((10000 − r_bp) × total_available × YT_in_pm + r_bp × yt_supply × P_in_pm))
  ```

Both use **ceiling division** because cdpm's prediction floors. The full derivation, edge cases, and an iterative refinement helper (`ytToBurnForTargetNet`) live in [`cdpm-calculation-skill/reference/kai-lending-math.md`](../../cdpm-calculation-skill/reference/kai-lending-math.md) section 7.

```typescript
import {
  ytToBurnForTargetUnderlying,
  ytToBurnForTargetNet,
} from './kai-lending-math';

async function agentRedeemForTargetNet(
  client: SuiGrpcClient,
  agentSigner: any,
  pmId: string,
  underlyingCoinType: string,
  ytCoinType: string,
  vaultObjectId: string,
  desiredNet: bigint,
  feeRateBp: bigint,
  vaultSnapshot: KaiVaultSnapshot,
  pmKaiVault: KaiPmVaultSnapshot,
  strategyWalkers: any[],
) {
  const ytAmount = ytToBurnForTargetNet(
    vaultSnapshot, pmKaiVault, desiredNet, feeRateBp,
  );

  return agentRedeemFromKai(
    client, agentSigner, pmId,
    underlyingCoinType, ytCoinType, vaultObjectId,
    ytAmount,
    strategyWalkers,
  );
}
```

The closed-form approximation is occasionally off-by-one due to per-step floors inside `kai_finish_redeem`; the iterative helper bumps `N` upward by 1 YT until forward simulation confirms `>= desiredNet`. Re-snapshot the vault state *just before* signing — Kai's `total_available_balance` ticks every block as time-locked profit unlocks, and stale snapshots can leave the bot 1-2 underlying short.

---

## What Agents CANNOT Do With Kai

| Operation | Reason |
|-----------|--------|
| Pull raw `Coin<YT>` out of `pm.lending` | cdpm exposes **no** `user_extract_kai_yt`-style wrapper-extraction function for anyone (neither agent nor owner). The only exit path is the full redeem flow: `kai_start_redeem` → `vault::withdraw` → strategy walk → `redeem_withdraw_ticket` → `kai_finish_redeem` → `user_remove_liquidity_from_balance<T>`. |
| Construct a fake `Vault<T, EvilYT>` | `kai_sav::vault::new` is `public(package)` — only Kai's modules can mint a `Vault`. |
| Mint `Coin<YT>` outside the vault | `YT`'s `TreasuryCap` is owned by `Vault<T, YT>` — `kai_finish_supply` fails `EAmountShortfall (1009)` if the agent tries to substitute a forged or smaller `Coin<YT>`. |
| Skip the strategy walk | `vault::redeem_withdraw_ticket` aborts internally if any strategy slot is unsettled. Forgetting a walker step makes the whole PTB abort before `kai_finish_redeem` runs (so the hot-potato ticket is never consumed and funds are safe). |

---

## Event Subscription

Agents should subscribe to the Kai-lending events alongside Scallop's:

```typescript
interface KaiSupplied {
  pm_id: string;
  coin_type: string;
  yt_type: string;
  deposit_amount: u64;
  yt_minted: u64;
}

interface KaiRedeemed {
  pm_id: string;
  coin_type: string;
  yt_type: string;
  yt_burned: u64;
  redeemed_amount: u64;
  principal_portion: u64;
  interest: u64;
  fee_amount: u64;
}
```

cdpm emits no extraction event for Kai lending — there is no wrapper-extract function. The only exit-related event on the Kai side is `KaiRedeemed`, emitted by `kai_finish_redeem` once the underlying lands in `pm.balance`.

---

## Error Cheat Sheet

| Code | Constant | Most likely cause for an agent |
|------|----------|---------------------------------|
| 1001 | `ENotOwner` | Agent attempted an owner-only function (e.g. `user_get_position` / `user_get_and_return_position`). Escalate to owner. |
| 1002 | `ENotAllow` | Agent address removed from `pm.agents` between scheduling and signing. Re-check `pm.agents` before retry. |
| 1005 | `ENoSuchVault` | `kai_start_redeem` for a `(T, YT)` pair that has never been supplied (or was fully drained). Snapshot `pm.lending` before sizing. |
| 1006 | `EReserveEmpty` | Kai vault `total_yt_supply == 0`. Bootstrap state — supply first. |
| 1007 | `EZeroExpected` | Amount too small — `coin_amount × yt_supply < total_available_balance` (supply) or `yt_amount × total_available_balance < yt_supply` (redeem). Increase amount or wait for higher TVL. |
| 1008 | `EWrongPm` | Hot-potato ticket consumed against a different PM. Re-check the `pmId` you signed against. |
| 1009 | `EAmountShortfall` | Vault state moved between snapshot and signing (profit unlocked, strategy loss, etc.) and `total_available_balance` shrank. Re-snapshot and retry, or accept the slippage by sizing with `ytToBurnForTargetNet` plus a small margin. |
| 1013 | `EWrongVault` | `kai_finish_*` received a `&Vault<T,YT>` whose id ≠ ticket.vault_id. Reuse the same `tx.object(vaultObjectId)` handle across `start_*` and `finish_*`. |
