# Kai SAV Lending (Idle Funds)

## Contents

- [API Overview](#api-overview)
- [PTB Recipe: Supply](#ptb-recipe-supply)
- [PTB Recipe: Redeem](#ptb-recipe-redeem)
- [Exit Path](#exit-path)
- [Closing a PositionManager With Active Vaults](#closing-a-positionmanager-with-active-vaults)
- [Events](#events)
- [Error Cheat Sheet](#error-cheat-sheet)

## API Overview

Two single-MoveCall entry points, one per direction. Kai SAV is two-generic (`<T, YT>`) on supply; redeem additionally carries the supply-pool strategy generic `ST`:

| Phase  | cdpm function              | Effect |
|--------|----------------------------|--------|
| Supply | `kai_supply<T, YT>`        | Splits `amount` `Coin<T>` out of `pm.balance[T]`, calls `kai_sav::vault::deposit<T, YT>`, stores the resulting `Balance<YT>` and principal into `pm.lending` under key `type_name<YT>`. |
| Redeem | `kai_redeem<T, ST, YT>`    | Pulls (a slice of) `Balance<YT>` from `pm.lending`, runs the full Kai withdraw chain (`vault::withdraw` → `kai_leverage_supply_pool::withdraw` → `vault::redeem_withdraw_ticket`), splits the protocol yield-fee off the interest portion into `FeeHouse`, deposits the net underlying back into `pm.balance[T]`. |

Authorization on both is `assert_caller_authorized`: caller must be **owner**, **an authorized agent**, or **a whitelisted protocol bot AND the PM has no agents**.

Each function is one `tx.moveCall`. Kai's `vault::deposit` reads `total_available_balance(vault, clock)` internally (which already folds in time-locked profit), so no external accrual call is needed.

The bag key for Kai entries is `type_name<YT>`, so a single underlying `T` can simultaneously have a `ScallopVault<T>` (key = `type_name<T>`) and a `KaiVault<T, YT>` (key = `type_name<YT>`) without collision.

---

## PTB Recipe: Supply

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

PTB shape (1 command):

```
cdpm::kai_supply<T, YT>(access, pm, vault, amount, clock)
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

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_supply`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(vaultObjectId),
      tx.pure.u64(amount),
      tx.object('0x6'),                  // Clock
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Important properties:

- `kai_supply` decreases `pm.balance[T]` by `amount` (via `withdraw_from_balance<T>`; the resulting `Coin<T>` value is recorded as `principal`).
- The first supply for a given `(T, YT)` creates a fresh `KaiVault<T, YT>` under bag key `type_name<YT>`; subsequent supplies of the same `(T, YT)` pair join the new `Balance<YT>` and add to `principal`.
- The `Balance<YT>` returned by `vault::deposit` never leaves the contract. External code cannot forge `Coin<YT>` because Kai's vault module owns the `TreasuryCap<YT>`.
- If the vault is in the degenerate bootstrap state `total_available_balance == 0`, Kai mints YT 1:1.

---

## PTB Recipe: Redeem

`kai_redeem` covers the full Kai withdrawal flow in one call:

1. `kai_vault::withdraw<T, YT>` produces a `WithdrawTicket`.
2. `kai_leverage_supply_pool::withdraw<T, ST, YT>` walks the supply-pool strategy.
3. `kai_vault::redeem_withdraw_ticket<T, YT>` settles to `Balance<T>`.

All three steps execute inside `kai_redeem`. The function is generic over the kai-leverage supply-pool strategy `<T, ST, YT>` since every production Kai SAV vault uses that strategy.

Yield-fee math (identical to Scallop):

```
interest      = max(0, redeemed_amount − principal_portion)
fee_amount    = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance = redeemed_amount − fee_amount
```

`principal_portion` is the slice of stored principal proportional to the burned YT: `principal_portion = floor(P_total × yt_burned / YT_total)` (see `pull_from_kai_lending`).

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

PTB shape (1 command):

```
cdpm::kai_redeem<T, ST, YT>(access, pm, fee_house, vault, strategy, supply_pool, yt_amount, clock)
```

`yt_amount = u64::MAX` is a sentinel meaning *drain the entire `KaiVault<T, YT>` entry from `pm.lending`* — `pull_from_kai_lending` clamps `want_amount` to the stored YT balance and removes the bag entry.

```typescript
async function userRedeemFromKai(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  underlyingCoinType: string,    // T
  stCoinType: string,            // ST — kai_leverage_supply_pool strategy share token
  ytCoinType: string,            // YT
  vaultObjectId: string,         // Vault<T, YT>
  strategyObjectId: string,      // klsp::Strategy<T, ST>
  supplyPoolObjectId: string,    // SupplyPool<T, ST>
  ytAmount: bigint,              // u64::MAX (0xffffffffffffffffn) to drain
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_redeem`,
    typeArguments: [underlyingCoinType, stCoinType, ytCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
      tx.object(vaultObjectId),
      tx.object(strategyObjectId),
      tx.object(supplyPoolObjectId),
      tx.pure.u64(ytAmount),
      tx.object('0x6'),                  // Clock
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

The off-chain SDK supplies the three Kai object IDs (vault, strategy, supply pool). For a given `(T, YT)`, those are fixed per-vault and can be cached.

### Sizing Redemptions

`kai_redeem` takes a `yt_amount` (yield tokens), but most callers think in terms of *underlying they need*. Two inverses cover the realistic cases:

- **Pre-fee target.** I want at least `K` underlying out of Kai, fee aside. `yt_to_burn = ceil(K × yt_supply / total_available_balance)`.
- **Post-fee target.** I want at least `K` net underlying credited to `pm.balance[T]` after the yield fee. The closed form is `N ≈ ceil(K / (p × (1 − r) + r × π))` when there is interest (the typical case `p > π`), where `p = total_available_balance / yt_supply`, `π = principal / yt_total_in_vault`, `r = fee_rate / 10000`.

Both formulas use **ceiling** division — Kai's `vault::withdraw` uses `muldiv_round_up` for fairness to remaining YT holders. To guarantee the on-chain output is `>= K`, ceiling is correct. Cross-link: the full derivation, edge cases (bootstrap, vault drain, socialized loss), and an iterative refinement helper live in [`cdpm-calculation-skill/reference/kai-lending-math.md`](../../cdpm-calculation-skill/reference/kai-lending-math.md) section 7.

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

// Feed it straight into kai_redeem.
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_redeem`,
  typeArguments: [underlyingCoinType, stCoinType, ytCoinType],
  arguments: [
    tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
    tx.object(pmId),
    tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
    tx.object(vaultObjectId),
    tx.object(strategyObjectId),
    tx.object(supplyPoolObjectId),
    tx.pure.u64(nPostFee),               // sentinel MAX_U64 drains the entry
    tx.object('0x6'),
  ],
});
```

If the helper returns `MAX_U64` it means the `KaiVault<T, YT>` entry cannot satisfy the target; passing `MAX_U64` drains the entry entirely and returns whatever Kai pays out.

---

## Exit Path

cdpm exposes no function that hands `YT` out to the caller. The only exit is:

```
kai_redeem<T, ST, YT> → pm.balance[T] → user_remove_liquidity_from_balance<T>
```

If Kai is unreachable (Version bump, withdrawals disabled, paused vault, etc.) the abort happens inside the inner `vault::withdraw` / `redeem_withdraw_ticket` calls and `pm.lending` stays intact. Retry once Kunalabs lifts the disable flag or ships an SDK update against the new Vault Version; cdpm itself stays operational throughout.

The Cetus DLMM `Position` is the only object cdpm cannot recover from upstream breakage in-band, and that one case is handled by the owner-only `user_get_position` / `user_get_and_return_position` extraction documented in [`position-management.md`](./position-management.md).

---

## Closing a PositionManager With Active Vaults

`user_close_pm` asserts `bag::is_empty(&pm.lending)` (`ELendingNotEmpty = 1004`). Before calling it, redeem every `(T, YT)` Kai vault entry with `kai_redeem<T, ST, YT>` (use `yt_amount = u64::MAX` to drain); the post-fee underlying lands in `pm.balance[T]` and is then withdrawn with `user_remove_liquidity_from_balance<T>(u64::MAX)`. The same `ELendingNotEmpty` covers both Scallop and Kai entries.

`user_close_pm` also asserts:
- `bag::is_empty(&pm.balance)` (`EBalanceNotEmpty = 1008`) — drain every `pm.balance[T]` first.
- `bag::is_empty(&pm.fee)` (`EFeeNotEmpty = 1009`) — drain every `pm.fee[T]` first.
- Every `PositionInfo.rewards_owned[i] == 0` (`EPositionHasRewards = 1007`) — call `user_collect_reward<A, B, R>` for every reward type on the pool first.

See [`workflows.md`](./workflows.md) § Close Position Safely for the full template.

---

## Events

```typescript
interface KaiSupplied {
  pm_id: string;
  coin_type: string;          // type_name<T>
  yt_type: string;            // type_name<YT>
  deposit_amount: u64;        // underlying transferred to Kai
  yt_minted: u64;             // YT received
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

> Events carry **both** `coin_type` (T) and `yt_type` (YT). The bag key is `yt_type`, but `coin_type` is needed for human-readable reporting and to disambiguate from a hypothetical second yield token over the same underlying. Sui event envelopes already record the transaction sender, so events do not carry a sender field — reach for `event.sender` if you need to distinguish owner / agent / protocol callers.

---

## Error Cheat Sheet

| Code | Constant | When |
|------|----------|------|
| 1001 | `ENotOwner` | Non-owner called an owner-only entry (Kai lending itself exposes no owner-only entry; this code does not surface from `kai_supply` / `kai_redeem`). |
| 1002 | `ENotAllow` | `kai_supply` / `kai_redeem` failed `assert_caller_authorized` (caller is not owner, not in `pm.agents`, and either not in `access.allow` or `pm.agents` is non-empty). |
| 1004 | `ELendingNotEmpty` | `user_close_pm` while `pm.lending` is non-empty (any Scallop or Kai entry). |
| 1005 | `ENoSuchVault` | `kai_redeem` for an absent `(T, YT)` entry (bag key `type_name<YT>` not present in `pm.lending`). |
| 1006 | `ENoSuchBalance` | `kai_supply` ran with `amount > 0` but `pm.balance` has no `Balance<T>` entry to draw from. Deposit `Coin<T>` into the PM with `user_add_liquidity_to_balance<T>` first. |

External aborts you may hit (these come from Kai itself, not cdpm):

- `vault::EWithdrawalsDisabled` — admin called `set_withdrawals_disabled`. The position remains intact in `pm.lending`; retry once Kunalabs lifts the disable flag. cdpm offers no in-protocol escape.
- `vault::ETvlCapExceeded` — admin set a `tvl_cap` that your deposit would breach. Lower `amount` or wait.
- `vault::ERateLimit` — admin-configured rate limiter rejected the deposit/withdraw. Retry later.

The cdpm functions themselves never construct these aborts; they bubble up from the inner `vault::deposit` / `vault::withdraw` calls and abort the whole `kai_supply` / `kai_redeem` move-call before cdpm's bookkeeping mutates state.
