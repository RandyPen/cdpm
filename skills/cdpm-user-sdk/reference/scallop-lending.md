# Scallop Lending (Idle Funds)

> **REQUIRED — every Scallop PTB starts with `accrue_interest_for_market`.**
> Any PTB that calls `scallop_start_supply` or `scallop_start_redeem` MUST have
> `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)`
> as **command 0**. cdpm enforces this on-chain: omitting the pre-step aborts at
> the cdpm boundary with `EStaleScallopState (1011)` before any balance is touched.
> The Scallop TS SDK helpers `scallopTx.deposit` / `depositQuick`
> (`sui-scallop-sdk/src/builders/coreBuilder.ts:139-148, 335-358`) do **NOT**
> inject this call — you must add it explicitly. There is no SDK shortcut and no
> optional path.

`PositionManager` exposes a hot-potato lending API that lets the **owner** (and authorized agents / whitelisted protocol bots) park unused balance into Scallop and earn yield while the position is idle. Scallop is **one of two yield destinations** — the other is Kai SAV, documented in [`kai-lending.md`](./kai-lending.md). Both share the same `pm.lending: Bag`, ticket-shape, and yield-fee math; the disambiguation lives in the function-name prefix (`scallop_*` vs `kai_*`) and the bag key (`type_name<T>` for Scallop, `type_name<YT>` for Kai).

The on-chain shape:

```move
use protocol::reserve::MarketCoin;

public struct PositionManager has key {
    id: UID,
    owner: address,
    agents: VecSet<address>,
    position: Option<Position>,
    balance: Bag,
    fee: Bag,
    lending: Bag,                 // shared with Kai; Scallop entries keyed by `type_name<T>`, value = ScallopVault<T>
}

public struct ScallopVault<phantom T> has store {
    scoin: Balance<MarketCoin<T>>, // Scallop sCoin (yield-bearing market coin)
    principal: u64,                // Original underlying deposited (for yield accounting)
}
```

There is **at most one Scallop vault per underlying type T** (Kai entries for the same `T` live under a different key, `type_name<YT>`, so they cannot collide). The sCoin type is structurally pinned to `MarketCoin<T>` by the type system — there is no separate `S` generic, so a fake-sCoin variant simply cannot be passed in.

---

## Hot-Potato API Overview

The four entry points come in two pairs that must be glued together inside one PTB:

| Phase    | cdpm function | Returns / consumes                                          |
|----------|------------------------|----------------------------------------------------|
| Supply   | `scallop_start_supply<T>`      | `(Coin<T>, ScallopSupplyTicket<T>)`                       |
| Supply   | `scallop_finish_supply<T>`     | consumes `ScallopSupplyTicket<T>` + `Coin<MarketCoin<T>>` |
| Redeem   | `scallop_start_redeem<T>`      | `(Coin<MarketCoin<T>>, ScallopRedeemTicket<T>)`           |
| Redeem   | `scallop_finish_redeem<T>`     | consumes `ScallopRedeemTicket<T>` + `Coin<T>`             |

`ScallopSupplyTicket<T>` and `ScallopRedeemTicket<T>` have **no `drop` ability**. The only way to discharge them is by calling the matching `finish_*`. If you forget, the PTB aborts.

Authorization for `scallop_start_supply` / `scallop_start_redeem` is checked by `assert_caller_authorized`: caller must be **owner**, **an authorized agent**, or **a whitelisted protocol bot AND the PM has no agents**.

`scallop_finish_supply` / `scallop_finish_redeem` only verify that `ticket.pm_id == object::id(pm)`; the auth check happens on the start side.

---

## PTB Recipe: Supply

The first command of any supply PTB **MUST** be `protocol::accrue_interest::accrue_interest_for_market`. cdpm enforces this: `scallop_start_supply` reads Scallop's per-asset `last_updated_by_type(market.borrow_dynamics(), type<T>)` and asserts equality with `clock::timestamp_ms(clock) / 1000`. Omitting the pre-step aborts at the cdpm boundary with `EStaleScallopState (1011)` before any balance is touched.

`scallop_start_supply` also records `market_id = object::id(market)` on the ticket, and `scallop_finish_supply` re-takes `&Market` and asserts the id matches, aborting with `EWrongMarket (1012)` on mismatch. Use the same `tx.object(SCALLOP_MARKET_ID)` handle across both calls.

Authoritative signatures:

```move
public fun scallop_start_supply<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    market: &Market,
    clock: &Clock,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<T>, ScallopSupplyTicket<T>);

public fun scallop_finish_supply<T>(
    pm: &mut PositionManager,
    market: &Market,
    ticket: ScallopSupplyTicket<T>,
    scoin: Coin<MarketCoin<T>>,
);
```

Required PTB order (4 steps):

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::scallop_start_supply<T>(access, pm, market, clock, amount)       → (coin_t, ticket)
3. protocol::mint::mint<T>(version, market, coin_t, clock)                → coin_market<T>
4. cdpm::scallop_finish_supply<T>(pm, market, ticket, coin_market)
```

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function userSupplyToScallop(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  underlyingCoinType: string,    // e.g. '0x...::usdc::USDC'
  amount: bigint,
) {
  const tx = new Transaction();

  // 1. REQUIRED PTB[0] — cdpm asserts EStaleScallopState (1011) without this.
  //    NOT injected by scallopTx.deposit / depositQuick.
  tx.moveCall({
    target: `${SCALLOP_PROTOCOL}::accrue_interest::accrue_interest_for_market`,
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.object('0x6'),
    ],
  });

  // 2. Withdraw underlying from pm.balance and emit a ScallopSupplyTicket.
  //    scallop_start_supply asserts last_updated == now (EStaleScallopState=1011).
  const [coinT, ticket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::scallop_start_supply`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(SCALLOP_MARKET_ID),
      tx.object('0x6'),
      tx.pure.u64(amount),
    ],
  });

  // 3. Hand the underlying to Scallop, receive Coin<MarketCoin<T>>.
  const [coinMarket] = tx.moveCall({
    target: `${SCALLOP_PROTOCOL}::mint::mint`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      coinT,
      tx.object('0x6'),
    ],
  });

  // 4. Burn the ScallopSupplyTicket by depositing the sCoin into pm.lending.
  //    finish_* asserts object::id(market) == ticket.market_id (EWrongMarket=1012).
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::scallop_finish_supply`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(pmId),
      tx.object(SCALLOP_MARKET_ID),
      ticket,
      coinMarket,
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Important properties:

- `scallop_start_supply` decreases `pm.balance[T]` by `amount` and stores `principal` for later yield accounting.
- `scallop_finish_supply` requires `coinMarket.value() >= ticket.expected_scoin`; otherwise it aborts with `EAmountShortfall (1009)`. Combined with the `Coin<MarketCoin<T>>` type pin (the only way to obtain a non-zero `Coin<MarketCoin<T>>` is through Scallop's `mint`, since `MarketCoin` has only `drop` and no public constructor), an agent cannot short-change the vault with a fake sCoin or a smaller real one.
- The first supply for a given `T` creates a fresh `ScallopVault<T>`; subsequent supplies of the same `T` add to it.

---

## PTB Recipe: Redeem (with yield-fee deduction)

Same freshness rule applies: `scallop_start_redeem` asserts `last_updated == now` and aborts with `EStaleScallopState (1011)` otherwise. `scallop_finish_redeem` re-takes `&Market` and asserts canonical-id match (`EWrongMarket = 1012`).

Authoritative signatures:

```move
public fun scallop_start_redeem<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    market: &Market,
    clock: &Clock,
    market_coin_amount: u64,
    ctx: &mut TxContext,
): (Coin<MarketCoin<T>>, ScallopRedeemTicket<T>);

public fun scallop_finish_redeem<T>(
    pm: &mut PositionManager,
    market: &Market,
    fee_house: &mut FeeHouse,
    ticket: ScallopRedeemTicket<T>,
    underlying: Coin<T>,
    ctx: &mut TxContext,
);
```

Redeem deducts the protocol yield fee from the **interest portion only**, never from principal. The fee math lives entirely in `scallop_finish_redeem`:

```
interest         = max(0, redeemed_amount − principal_portion)
fee_amount       = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance    = redeemed_amount − fee_amount
```

`principal_portion` is the slice of stored principal proportional to the burned scoin: `principal_portion = floor(P_total × scoin_burned / S_total)` (see `pull_from_scallop_lending`).

Required PTB order (4 steps):

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::scallop_start_redeem<T>(access, pm, market, clock, scoin_amount)     → (coin_market, ticket)
3. protocol::redeem::redeem<T>(version, market, coin_market, clock)           → coin_t
4. cdpm::scallop_finish_redeem<T>(pm, market, fee_house, ticket, coin_t)
```

```typescript
async function userRedeemFromScallop(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  underlyingCoinType: string,
  scoinAmount: bigint,
) {
  const tx = new Transaction();

  // REQUIRED PTB[0] — cdpm asserts EStaleScallopState (1011) without this.
  // NOT injected by scallopTx.deposit / depositQuick.
  tx.moveCall({
    target: `${SCALLOP_PROTOCOL}::accrue_interest::accrue_interest_for_market`,
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.object('0x6'),
    ],
  });

  const [coinMarket, ticket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::scallop_start_redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(SCALLOP_MARKET_ID),
      tx.object('0x6'),
      tx.pure.u64(scoinAmount),
    ],
  });

  const [coinT] = tx.moveCall({
    target: `${SCALLOP_PROTOCOL}::redeem::redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      coinMarket,
      tx.object('0x6'),
    ],
  });

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::scallop_finish_redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(pmId),
      tx.object(SCALLOP_MARKET_ID),
      tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
      ticket,
      coinT,
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

The post-fee underlying lands back in `pm.balance[T]`; you can withdraw it later with `user_remove_liquidity_from_balance`.

### Sizing Redemptions

`scallop_start_redeem` takes a `market_coin_amount` (sCoin), but most callers think in terms of *underlying they need*. Two inverses cover the realistic cases:

- **Pre-fee target.** I want at least `K` underlying out of Scallop, fee aside. `scoin_to_burn = ceil(K × supply / denom)` where `denom = cash + debt − revenue`.
- **Post-fee target.** I want at least `K` net underlying credited to `pm.balance[T]` after the yield fee. The closed form is `N ≈ ceil(K / (p × (1 − r) + r × π))` when there is interest (the typical case `p > π`), where `p = denom / supply`, `π = principal / scoinTotal`, `r = fee_rate / 10000`.

Both formulas use **ceiling** division — Scallop floors the actual underlying delivered, so flooring `N` would risk receiving 1 unit fewer than `K`. Cross-link: the full derivation, edge cases (no-interest branch, vault drain, socialized loss), and an iterative refinement helper live in [`cdpm-calculation-skill/reference/scallop-lending-math.md`](../../cdpm-calculation-skill/reference/scallop-lending-math.md) section 7.

```typescript
import {
  scoinToBurnForTargetUnderlying,
  scoinToBurnForTargetNet,
} from './scallop-lending-math'; // your local copy

// "Give me 100 underlying out of Scallop, fee aside."
const nPreFee = scoinToBurnForTargetUnderlying(
  reserveSnapshot,
  100_000_000n,             // K, in underlying base units
  vaultSnapshot.scoinTotal,
);

// "Credit at least 100 underlying to pm.balance after the yield fee."
const nPostFee = scoinToBurnForTargetNet(
  reserveSnapshot,
  vaultSnapshot,
  100_000_000n,             // K
  2_000n,                   // 2000 bp = 20%
);

// Feed it straight into scallop_start_redeem.
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_start_redeem`,
  typeArguments: [underlyingCoinType],
  arguments: [
    tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
    tx.object(pmId),
    tx.object(SCALLOP_MARKET_ID),
    tx.object('0x6'),
    tx.pure.u64(nPostFee),  // sentinel MAX_U64 drains the whole vault
  ],
});
```

If the helper returns `MAX_U64` it means the vault cannot satisfy your target; passing `MAX_U64` to `scallop_start_redeem` drains the entire vault and returns whatever Scallop pays out.

---

## No Wrapper-Extract Escape

cdpm does **not** expose a `user_extract_scallop_market_coin`-style function for anyone — not for owner, not for agents, not for protocol bots. The lending wrapper has no off-protocol utility: a raw `Coin<MarketCoin<T>>` outside cdpm is only redeemable back through Scallop's `redeem`, and handing it out would only break cdpm's principal-counter accounting that protocol-fee math depends on. Lending exit is constrained to the full redeem flow:

```
accrue_interest_for_market → scallop_start_redeem → redeem::redeem → scallop_finish_redeem → pm.balance → user_remove_liquidity_from_balance<T>
```

If Scallop is unreachable (Version bump, paused market, etc.), the abort happens inside the inner `mint::mint` / `redeem::redeem` call before any cdpm `*_finish_*` runs, so the hot-potato ticket is never consumed and `pm.lending` stays intact. Recovery is to retry the normal flow once Scallop ships an SDK update against the new Version; cdpm itself stays operational throughout.

The Cetus DLMM `Position` is the only object cdpm cannot recover from upstream breakage in-band, and that one case is handled by the unrelated owner-only `user_get_position` / `user_get_and_return_position` extraction documented in [`position-management.md`](./position-management.md).

---

## Closing a PositionManager With Active Vaults

`user_close_pm` asserts `bag::is_empty(&pm.lending)` (`ELendingNotEmpty = 1004`). The same assertion covers both Scallop and Kai entries — drain every entry of either flavor before close. For every Scallop `T` vault, run the full redeem flow above; the post-fee underlying lands in `pm.balance[T]` and can then be withdrawn with `user_remove_liquidity_from_balance<T>`. For every Kai `(T, YT)` entry, run the matching `kai_finish_redeem` flow — see [`kai-lending.md`](./kai-lending.md). After every entry is drained `user_close_pm` succeeds.

### Top-Up Pattern (Defensive — Same Shape as Kai)

Same PTB shape as the Kai counterpart — see [`kai-lending.md` § Top-Up Pattern](./kai-lending.md#top-up-pattern-required-for-full-drain) for the full recipe. The only structural difference: the redeem chain's intermediate Move-call is `protocol::redeem::redeem` (yielding `coinT`), and `coin::join(coinT, topup)` sits immediately after it, before `scallop_finish_redeem`.

Scallop's math is friendlier than Kai's: `protocol::redeem::redeem` and cdpm's `compute_expected_underlying_scallop` evaluate the same single floor-div on the same balance-sheet snapshot within the PTB, so `redeemed_amount == expected_underlying` exactly — no observed dust. The top-up is therefore **defensive, not strictly required** today; close-PM keeps it in place for uniform code paths with Kai (where it *is* required) and as a forward-compatibility hedge against Scallop changing its rounding. Same `FINISH_REDEEM_TOPUP_DEFAULT_RAW = 30n` recommended default applies. See [`cdpm-calculation-skill/reference/scallop-lending-math.md` §9.1](../../cdpm-calculation-skill/reference/scallop-lending-math.md#91-full-drain-dust-and-the-lending_safe_margin_wrapper_raw-floor) for the math.

---

## Events

```typescript
interface ScallopSupplied {
  pm_id: string;
  coin_type: string;          // type_name<T>
  deposit_amount: u64;        // underlying transferred to Scallop
  market_coin_minted: u64;    // sCoin received (Coin<MarketCoin<T>>)
}

interface ScallopRedeemed {
  pm_id: string;
  coin_type: string;
  market_coin_redeemed: u64;  // sCoin burned
  redeemed_amount: u64;       // underlying received from Scallop (pre-fee)
  principal_portion: u64;     // principal slice consumed by this redeem
  interest: u64;              // redeemed_amount − principal_portion
  fee_amount: u64;            // protocol fee taken from interest
}
```

cdpm does not emit an extraction event for Scallop lending — there is no wrapper-extract function.

> Events no longer carry a separate `scoin_type` field — the sCoin type is always `MarketCoin<T>`, fully determined by `coin_type`. The events also do **not** carry a `by` field; Sui event envelopes already record the transaction sender, reach for `event.sender` if you need to distinguish owner / agent / protocol callers.

---

## Error Cheat Sheet

| Code | Constant | When |
|------|----------|------|
| 1001 | `ENotOwner` | Non-owner called an owner-only entry (e.g. `user_get_position` — note Scallop lending exposes no owner-only entry) |
| 1002 | `ENotAllow` | `scallop_start_supply` / `scallop_start_redeem` failed `assert_caller_authorized` |
| 1004 | `ELendingNotEmpty` | `user_close_pm` while `pm.lending` is non-empty (any Scallop or Kai entry) |
| 1005 | `ENoSuchVault` | `scallop_start_redeem` for an absent Scallop (T) entry (the Kai counterparts share this code for absent `(T, YT)` entries — see `kai-lending.md`) |
| 1006 | `EReserveEmpty` | Scallop reserve has zero supply or zero `(cash+debt−revenue)` |
| 1007 | `EZeroExpected` | `scallop_start_supply` / `scallop_start_redeem` would yield 0 — amount too small |
| 1008 | `EWrongPm` | `finish_*` ticket consumed against a different PositionManager |
| 1009 | `EAmountShortfall` | `finish_*` Coin value `<` ticket.expected. Scallop's upstream `protocol::redeem::redeem` uses the same single floor-div as cdpm in the same PTB snapshot, so dust is 0 in the common case — but if you see this on a close-PM, it almost always means stale accrual (missing `accrue_interest_for_market` as PTB command 0) or reserve state moving between snapshot and signing. Re-snapshot just after accrue. The defensive close-PM top-up pattern above (`coin::join` before `scallop_finish_redeem`) prevents this entirely. |
| 1011 | `EStaleScallopState` | `scallop_start_*` reached cdpm without `accrue_interest::accrue_interest_for_market(version, market, clock)` earlier in the same PTB. Make it command 0 of every Scallop batch. |
| 1012 | `EWrongMarket` | `scallop_finish_*` received a `&Market` whose id ≠ ticket.market_id. Reuse the same `tx.object(SCALLOP_MARKET_ID)` across `start_*` and `finish_*`. |
