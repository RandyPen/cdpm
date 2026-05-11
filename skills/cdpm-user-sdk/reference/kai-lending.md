# Kai SAV Lending (Idle Funds)

`PositionManager` exposes a second hot-potato lending integration alongside Scallop: **Kai SAV** (Strategy-Aggregating Vault). It lets the **owner** (and authorized agents / whitelisted protocol bots under the same `assert_caller_authorized` rules as Scallop) park idle balance into a Kai vault and earn yield while the position sits idle.

The on-chain shape:

```move
use kai_sav::vault as kai_vault;

public struct PositionManager has key {
    id: UID,
    owner: address,
    agents: VecSet<address>,
    position: Option<Position>,
    balance: Bag,
    fee: Bag,
    lending: Bag,                   // shared with Scallop; key disambiguates
}

public struct KaiVault<phantom T, phantom YT> has store {
    yt_balance: Balance<YT>,        // yield token issued by Kai's Vault<T, YT>
    principal: u64,                 // original underlying for yield accounting
}
```

Kai uses a **two-parameter** generic — `T` for the underlying coin (e.g. `USDC`) and `YT` for the per-vault yield token (e.g. `YUSDC`). `YT`'s `TreasuryCap` is held privately by `Vault<T, YT>`, so external packages cannot mint a forged `Coin<YT>`. `kai_sav::vault::new` is `public(package)` — only Kai's own modules can create a `Vault<T, YT>`, so a fake `Vault<T, EvilYT>` cannot be passed to `kai_start_supply`.

The `lending: Bag` is the **same bag** Scallop uses, but the bag key is `type_name<YT>` (Scallop uses `type_name<T>`). A single PositionManager can therefore hold both a `ScallopVault<USDC>` and a `KaiVault<USDC, YUSDC>` at the same time without collision.

---

## Hot-Potato API Overview

Same shape as Scallop — start/finish ticket pairs glued together inside one PTB:

| Phase    | cdpm function | Returns / consumes |
|----------|----------------------------|------------------------------------------------------|
| Supply   | `kai_start_supply<T, YT>`  | `(Coin<T>, KaiSupplyTicket<T, YT>)`                  |
| Supply   | `kai_finish_supply<T, YT>` | consumes `KaiSupplyTicket<T, YT>` + `Coin<YT>`       |
| Redeem   | `kai_start_redeem<T, YT>`  | `(Coin<YT>, KaiRedeemTicket<T, YT>)`                 |
| Redeem   | `kai_finish_redeem<T, YT>` | consumes `KaiRedeemTicket<T, YT>` + `Coin<T>`        |

`KaiSupplyTicket<T, YT>` and `KaiRedeemTicket<T, YT>` have **no `drop` ability**. Forgetting `kai_finish_*` aborts the PTB.

Authorization on `kai_start_*` is the same `assert_caller_authorized`: caller must be **owner**, **an authorized agent**, or **a whitelisted protocol bot AND the PM has no agents**. `kai_finish_*` only checks `ticket.pm_id == object::id(pm)`.

### Differences vs Scallop at a glance

| Aspect | Scallop | Kai SAV |
|---|---|---|
| Generic | `<T>` | `<T, YT>` |
| Pre-call accrual | **Required** (`accrue_interest_for_market`) | **Not needed** — `total_available_balance` auto-accounts time-locked profit via `tlb::max_withdrawable` |
| Deposit shape | 1-call: `protocol::mint::mint<T>` | 1-call: `vault::deposit<T, YT>` |
| Redeem shape | 1-call: `protocol::redeem::redeem<T>` | **2 + N call**: `vault::withdraw` → strategy walks → `vault::redeem_withdraw_ticket` |
| Yield-fee path | Identical (lives in `kai_finish_redeem`) | Identical |
| Permissionless | YES (Scallop allow-all) | YES at the SAV layer — `vault::deposit` / `vault::withdraw` take no `ActionRequest`. Inner strategies (e.g. `kai_leverage::supply_pool::supply`) need `ActionRequest` but discharge it inside their own modules. |

---

## PTB Recipe: Supply

No accrual command is required up front. Kai's `vault::deposit` reads `total_available_balance(vault, clock)` internally, which already folds in time-locked profit; cdpm's `compute_expected_yt` reads the same pair (`total_available_balance` and `total_yt_supply`) view-only.

`kai_start_supply` records `vault_id = object::id(vault)` on the ticket; `kai_finish_supply` re-takes `&Vault<T,YT>` and asserts the id matches, aborting with `EWrongVault (1013)` on mismatch. Use the same `tx.object(vaultObjectId)` handle across both calls.

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

Required PTB order (3 commands):

```
1. cdpm::kai_start_supply<T, YT>(access, pm, vault, amount, clock)   → (coin_t, ticket)
2. kai_sav::vault::deposit<T, YT>(vault, coin_t.into_balance(), clock) → balance_yt
3. cdpm::kai_finish_supply<T, YT>(pm, vault, ticket, balance_yt.into_coin())
```

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function userSupplyToKai(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  underlyingCoinType: string,    // e.g. '0x...::usdc::USDC'
  ytCoinType: string,            // e.g. '0x...::yusdc::YUSDC'
  vaultObjectId: string,         // shared Vault<T, YT> object
  amount: bigint,
) {
  const tx = new Transaction();

  // 1. Withdraw underlying from pm.balance and emit a KaiSupplyTicket.
  //    The vault is read-only (& reference) — does not need to be a sharedObjectRef
  //    with mutable=true here, but it WILL need mutable=true in step 2.
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

  // 2. Deposit underlying balance into the Kai vault, receive Balance<YT>.
  //    `vault::deposit` returns a Balance<YT>, not a Coin<YT>; wrap it.
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

  // 3. Burn the KaiSupplyTicket by depositing the YT coin into pm.lending.
  //    finish_* asserts object::id(vault) == ticket.vault_id (EWrongVault=1013).
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

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Important properties:

- `kai_start_supply` decreases `pm.balance[T]` by `amount` and stores `principal` for later yield accounting (same path as `scallop_start_supply`, just under a different bag key).
- `kai_finish_supply` requires `coin_yt.value() >= ticket.expected_yt`; otherwise it aborts with `EAmountShortfall (1009)`. Because `Coin<YT>` cannot be forged outside Kai's `Vault<T, YT>`, an agent cannot short-change the vault.
- The first supply for a given `(T, YT)` creates a fresh `KaiVault<T, YT>`; subsequent supplies of the same `(T, YT)` pair add to it.
- **Bootstrap caveat.** If `total_available_balance == 0` Kai treats deposits as 1:1 (cdpm's `compute_expected_yt` matches). The degenerate state `total > 0 && yt_supply == 0` cannot occur on a healthy Kai vault — when it appears, cdpm conservatively predicts `0` and `kai_start_supply` aborts with `EZeroExpected (1007)`.

---

## PTB Recipe: Redeem (with strategy walk)

Kai's redeem path is **multi-step** because the vault delegates capital to N strategies (e.g. `kai_leverage::supply_pool`, Scallop SAV strategies). `vault::withdraw` returns a `WithdrawTicket` that records how much each strategy must un-allocate; the caller PTB has to walk each strategy module that has a non-zero `to_withdraw` slot, then call `redeem_withdraw_ticket` to settle the final `Balance<T>`.

`kai_start_redeem` records `vault_id`; `kai_finish_redeem` re-takes `&Vault<T,YT>` and asserts the id matches (`EWrongVault = 1013`).

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

Required PTB order (variable length — 4 + N commands):

```
1. cdpm::kai_start_redeem<T, YT>(access, pm, vault, yt_amount, clock)        → (coin_yt, ticket)
2. kai_sav::vault::withdraw<T, YT>(vault, coin_yt.into_balance(), clock)     → withdraw_ticket
3..3+N. for each strategy s with to_withdraw(s) > 0:
        <strategy_module>::strategy_withdraw_for_vault(strategy, vault, withdraw_ticket, ...)
        // strategy module discharges its own access-management ActionRequest internally
3+N+1. balance_t = kai_sav::vault::redeem_withdraw_ticket<T, YT>(vault, withdraw_ticket)
3+N+2. cdpm::kai_finish_redeem<T, YT>(pm, vault, fee_house, ticket, balance_t.into_coin())
```

`yt_amount = u64::MAX` is a sentinel meaning *drain the entire `KaiVault<T, YT>` entry from `pm.lending`* — `pull_from_kai_lending` clamps to the stored YT balance and removes the bag entry.

```typescript
async function userRedeemFromKai(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  underlyingCoinType: string,
  ytCoinType: string,
  vaultObjectId: string,
  ytAmount: bigint,
  // Off-chain SDK enumerates the active strategies attached to this Vault and
  // returns a list of move-call descriptors for the PTB to walk.
  strategyWalkers: Array<{
    target: string;
    typeArguments: string[];
    extraArgs: (tx: Transaction, withdrawTicket: any) => any[];
  }>,
) {
  const tx = new Transaction();

  // 1. Pull YT out of pm.lending and emit a KaiRedeemTicket.
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

  // 2. Hand the YT to Kai's vault, receive a WithdrawTicket.
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

  // 3..3+N. Walk each strategy that has to_withdraw > 0. The off-chain SDK is
  //         responsible for enumerating active strategies — cdpm does NOT track
  //         them, and Kai's vault leaves the walk to the caller.
  for (const walker of strategyWalkers) {
    tx.moveCall({
      target: walker.target,
      typeArguments: walker.typeArguments,
      arguments: walker.extraArgs(tx, withdrawTicket),
    });
  }

  // 3+N+1. Settle the WithdrawTicket — returns Balance<T>.
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

  // 3+N+2. Burn the KaiRedeemTicket — yield fee deducted from interest.
  //         finish_* asserts object::id(vault) == ticket.vault_id (EWrongVault=1013).
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

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

The yield-fee math inside `kai_finish_redeem` is identical to Scallop's `scallop_finish_redeem`:

```
interest      = max(0, redeemed_amount − principal_portion)
fee_amount    = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance = redeemed_amount − fee_amount
```

`principal_portion` is the slice of stored principal proportional to the burned YT: `principal_portion = floor(P_total × yt_burned / YT_total)` (see `pull_from_kai_lending`).

### Strategy walk responsibility

cdpm does not track which strategies a Kai vault has attached — that state lives entirely on the on-chain `Vault<T, YT>`. The off-chain SDK **must**:

1. Read the live `Vault<T, YT>` object before signing.
2. Enumerate `vault.strategies` (or equivalent — see the live Kai SAV ABI).
3. For each strategy with non-zero `to_withdraw` after `vault::withdraw`, append the matching `<strategy_module>::strategy_withdraw_for_vault` PTB command. Each strategy module discharges its own `ActionRequest` against `kai_leverage::access_management` internally; the caller does **not** need to construct an `ActionRequest` manually.
4. Always finish with `vault::redeem_withdraw_ticket` followed by `cdpm::kai_finish_redeem`.

If any strategy in the walk emits a `StrategyLossEvent` it does **not** abort the vault — Kai socializes the loss across YT holders. cdpm will still see `redeemed_amount >= expected_underlying` for the same `yt_burned`, because cdpm derives `expected_underlying` from `total_available_balance` (which already reflects the loss). If the on-chain redeemed underlying is somehow lower than the off-chain prediction (e.g. between snapshot and signing the vault loses value), `kai_finish_redeem` aborts with `EAmountShortfall (1009)`.

### Sizing Redemptions

`kai_start_redeem` takes a `yt_amount` (yield tokens), but most callers think in terms of *underlying they need*. Two inverses cover the realistic cases:

- **Pre-fee target.** I want at least `K` underlying out of Kai, fee aside. `yt_to_burn = ceil(K × yt_supply / total_available_balance)`.
- **Post-fee target.** I want at least `K` net underlying credited to `pm.balance[T]` after the yield fee. The closed form is `N ≈ ceil(K / (p × (1 − r) + r × π))` when there is interest (the typical case `p > π`), where `p = total_available_balance / yt_supply`, `π = principal / yt_total_in_vault`, `r = fee_rate / 10000`.

Both formulas use **ceiling** division — Kai's `vault::withdraw` itself uses `muldiv_round_up` for fairness to remaining YT holders, but the cdpm prediction `compute_expected_underlying_kai` floors. To guarantee the on-chain output is `>= K` after both rounds, ceiling is correct. Cross-link: the full derivation, edge cases (bootstrap, vault drain, socialized loss), and an iterative refinement helper live in [`cdpm-calculation-skill/reference/kai-lending-math.md`](../../cdpm-calculation-skill/reference/kai-lending-math.md) section 7.

```typescript
import {
  ytToBurnForTargetUnderlying,
  ytToBurnForTargetNet,
} from './kai-lending-math'; // your local copy

// "Give me 100 underlying out of Kai, fee aside."
const nPreFee = ytToBurnForTargetUnderlying(
  vaultSnapshot,
  100_000_000n,             // K, in underlying base units
  pmKaiVaultSnapshot.ytTotal,
);

// "Credit at least 100 underlying to pm.balance after the yield fee."
const nPostFee = ytToBurnForTargetNet(
  vaultSnapshot,
  pmKaiVaultSnapshot,
  100_000_000n,             // K
  2_000n,                   // 2000 bp = 20%
);

// Feed it straight into kai_start_redeem.
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_start_redeem`,
  typeArguments: [underlyingCoinType, ytCoinType],
  arguments: [
    tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
    tx.object(pmId),
    tx.object(vaultObjectId),
    tx.pure.u64(nPostFee),  // sentinel MAX_U64 drains the whole KaiVault entry
    tx.object('0x6'),
  ],
});
```

If the helper returns `MAX_U64` it means the `KaiVault<T, YT>` entry cannot satisfy the target; passing `MAX_U64` to `kai_start_redeem` drains the entry entirely and returns whatever Kai pays out after the strategy walk.

---

## No Wrapper-Extract Escape

cdpm does **not** expose a `user_extract_kai_yt`-style function for anyone — not for owner, not for agents, not for protocol bots. The lending wrapper has no off-protocol utility: a raw `Coin<YT>` outside cdpm is only useful for redemption back through the same `vault::withdraw` path, and handing it out would only delete the principal-counter accounting that protocol-fee math depends on. Lending exit is constrained to the full redeem flow:

```
kai_start_redeem → vault::withdraw → strategy walk → redeem_withdraw_ticket → kai_finish_redeem → pm.balance → user_remove_liquidity_from_balance<T>
```

If Kai is unreachable (Version bump, withdrawals disabled, paused vault, etc.) the abort happens inside the inner `vault::withdraw` / `redeem_withdraw_ticket` call before any cdpm `*_finish_*` runs, so the hot-potato ticket is never consumed and `pm.lending` stays intact. The position remains intact in `pm.lending`; retry the normal flow once Kunalabs lifts the disable flag or issues a new SDK version against the new Vault Version. cdpm itself stays operational throughout.

The Cetus DLMM `Position` is the only object cdpm cannot recover from upstream breakage in-band, and that one case is handled by the unrelated owner-only `user_get_position` / `user_get_and_return_position` extraction documented in [`position-management.md`](./position-management.md).

---

## Closing a PositionManager With Active Vaults

`user_close_pm` asserts `bag::is_empty(&pm.lending)` (`ELendingNotEmpty = 1004`). Before calling it you must drain every `(T, YT)` Kai vault entry through the full redeem flow above (`kai_start_redeem` → strategy walk → `kai_finish_redeem`); the post-fee underlying lands in `pm.balance[T]` and can then be withdrawn with `user_remove_liquidity_from_balance<T>`. The same `ELendingNotEmpty` covers both Scallop and Kai entries.

---

## Events

```typescript
interface KaiSupplied {
  pm_id: string;
  coin_type: string;          // type_name<T>
  yt_type: string;            // type_name<YT>
  deposit_amount: u64;        // underlying transferred to Kai
  yt_minted: u64;             // YT received (Coin<YT>)
}

interface KaiRedeemed {
  pm_id: string;
  coin_type: string;
  yt_type: string;
  yt_burned: u64;
  redeemed_amount: u64;       // underlying received from Kai (pre-fee)
  principal_portion: u64;     // principal slice consumed by this redeem
  interest: u64;              // redeemed_amount − principal_portion
  fee_amount: u64;            // protocol fee taken from interest
}
```

cdpm does not emit an extraction event for Kai lending — there is no wrapper-extract function.

> Events carry **both** `coin_type` (T) and `yt_type` (YT). The bag key is `yt_type`, but `coin_type` is needed for human-readable reporting and to disambiguate from a hypothetical second yield token over the same underlying. Sui event envelopes already record the transaction sender, so events do not carry a `by` field — reach for `event.sender` if you need to distinguish owner / agent / protocol callers.

---

## Error Cheat Sheet

| Code | Constant | When |
|------|----------|------|
| 1001 | `ENotOwner` | Non-owner called an owner-only entry (e.g. `user_get_position` — note Kai lending exposes no owner-only entry) |
| 1002 | `ENotAllow` | `kai_start_supply` / `kai_start_redeem` failed `assert_caller_authorized` |
| 1004 | `ELendingNotEmpty` | `user_close_pm` while `pm.lending` is non-empty (any Scallop or Kai entry) |
| 1005 | `ENoSuchVault` | `kai_start_redeem` for an absent `(T, YT)` entry |
| 1006 | `EReserveEmpty` | Kai vault has zero `total_yt_supply` (degenerate; cdpm asserts `yt_supply > 0` in `compute_expected_underlying_kai`) |
| 1007 | `EZeroExpected` | `kai_start_supply` / `kai_start_redeem` would yield 0 — amount too small, or vault state degenerate |
| 1008 | `EWrongPm` | `kai_finish_*` ticket consumed against a different PositionManager |
| 1009 | `EAmountShortfall` | `kai_finish_*` Coin value `<` ticket.expected (vault lost value between snapshot and signing, or strategy loss occurred mid-PTB) |
| 1013 | `EWrongVault` | `kai_finish_*` received a `&Vault<T,YT>` whose id ≠ ticket.vault_id. Reuse the same `tx.object(vaultObjectId)` across `start_*` and `finish_*`. |

External aborts you may hit (these come from Kai itself, not cdpm):

- `vault::EWithdrawalsDisabled` — admin called `set_withdrawals_disabled`. The position remains intact in `pm.lending`; retry once Kunalabs lifts the disable flag or issues a new SDK version. cdpm offers no in-protocol escape.
- `vault::ETvlCapExceeded` — admin set a `tvl_cap` that your deposit would breach. Lower `amount` or wait.
- `vault::ERateLimit` — admin-configured rate limiter rejected the deposit/withdraw. Retry later.

The cdpm functions themselves never construct these aborts; they bubble up from the inner `vault::deposit` / `vault::withdraw` move-calls in your PTB and abort the whole transaction before `kai_finish_*` runs (which is correct — the hot-potato ticket is then never consumed and you cannot lose funds).
