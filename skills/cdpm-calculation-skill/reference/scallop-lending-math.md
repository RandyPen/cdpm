# Scallop Lending Math

This page documents the off-chain twins of every numeric formula the cdpm contract uses for Scallop supply / redeem. Use them to predict outputs **before** broadcasting, to validate dry-run results, and to size deposits so that `EZeroExpected (1007)` and `EAmountShortfall (1009)` never trip in production.

All formulas mirror `sources/cdpm.move` exactly. The contract widens to `u128` before arithmetic and narrows back to `u64`, so every off-chain implementation should do the same.

---

## 1. Reserve Snapshot

cdpm reads four `u64` values from Scallop's `protocol::reserve::balance_sheet` for the underlying type `T`:

| Symbol | Source | Meaning |
|--------|--------|---------|
| `cash`    | `balance_sheet.cash`    | Underlying held by the reserve |
| `debt`    | `balance_sheet.debt`    | Outstanding borrows |
| `revenue` | `balance_sheet.revenue` | Protocol-skimmed reserve cut |
| `supply`  | `balance_sheet.supply`  | sCoin supply (`Balance<MarketCoin<T>>` total) |

The "lendable underlying" denominator that defines the sCoin↔underlying ratio is:

```
denom_underlying = cash + debt − revenue
```

cdpm asserts `cash + debt >= revenue` and `denom_underlying > 0`, otherwise it aborts with `EReserveEmpty (1006)`.

> **Pre-flight requirement.** Before reading these values for prediction, the live PTB **must** run `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)` as its first command. Off-chain dry runs and gRPC reads that do not include this command will see a stale `balance_sheet` whose `denom_underlying` is smaller than reality, so they will *over-predict* the sCoin mint and *over-predict* the underlying redeem — exactly the conditions that trip `EAmountShortfall (1009)` on chain.

---

## 2. `compute_expected_scoin` (used by `start_supply`)

```move
fun compute_expected_scoin<T>(market: &Market, coin_amount: u64): u64 {
    if (supply == 0) {
        coin_amount
    } else {
        floor(coin_amount × supply / (cash + debt − revenue))
    }
}
```

TypeScript twin:

```typescript
function computeExpectedScoin(
  cash: bigint,
  debt: bigint,
  revenue: bigint,
  supply: bigint,
  coinAmount: bigint,
): bigint {
  if (supply === 0n) {
    return coinAmount; // bootstrap: 1:1 sCoin per underlying
  }
  const denom = cash + debt - revenue;
  if (denom === 0n) throw new Error('EReserveEmpty (1006)');
  if (cash + debt < revenue) throw new Error('EReserveEmpty (1006)');
  return (coinAmount * supply) / denom; // floor division
}
```

Edge cases:

- `EReserveEmpty (1006)` when `cash + debt < revenue` (impossible-but-asserted) or `denom == 0`.
- `EZeroExpected (1007)` when the result is `0` and the contract checks `expected_scoin > 0` after computing — happens when `coin_amount × supply < denom`.

---

## 3. `compute_expected_underlying` (used by `start_redeem`)

```move
fun compute_expected_underlying<T>(market: &Market, scoin_amount: u64): u64 {
    floor(scoin_amount × (cash + debt − revenue) / supply)
}
```

This is the inverse of `compute_expected_scoin` and shares the same `EReserveEmpty (1006)` guards plus `assert!(supply > 0, ...)`.

```typescript
function computeExpectedUnderlying(
  cash: bigint,
  debt: bigint,
  revenue: bigint,
  supply: bigint,
  scoinAmount: bigint,
): bigint {
  if (supply === 0n) throw new Error('EReserveEmpty (1006)');
  if (cash + debt < revenue) throw new Error('EReserveEmpty (1006)');
  const numer_extra = cash + debt - revenue;
  return (scoinAmount * numer_extra) / supply; // floor division
}
```

`EZeroExpected (1007)` when the result is `0` (the asserted-positive check happens inside `start_redeem`).

---

## 4. Principal Amortization (`pull_from_lending`)

When the caller wants to redeem `want_amount` sCoin out of a vault that currently holds `S_total` sCoin and `P_total` principal, cdpm splits the principal proportionally:

```
if want_amount >= S_total:
    pulled_scoin     = S_total
    principal_portion = P_total
    (vault is removed from pm.lending)
else:
    principal_portion = floor(P_total × want_amount / S_total)
    pulled_scoin      = want_amount
    vault.principal  -= principal_portion
    vault.scoin      -= want_amount
```

TypeScript twin (matches `test_only_principal_portion`):

```typescript
function principalPortion(
  pTotal: bigint,    // current vault.principal
  sTotal: bigint,    // current balance::value(&vault.scoin)
  wantAmount: bigint // sCoin caller wants to burn
): bigint {
  if (wantAmount >= sTotal) return pTotal; // full drain
  return (pTotal * wantAmount) / sTotal;   // floor
}
```

Properties worth noting:

- Floor-division can leave 1 unit of principal "stuck" in the vault after a partial redeem; this is benign — it gets swept on a later full drain.
- `principal_portion ≤ pTotal` always.
- The function is monotonically non-decreasing in `wantAmount` (random-tested in `tests/`).

---

## 5. Yield Fee Inside `finish_redeem`

The interest portion is whatever Scallop returned beyond the principal slice; the yield fee is taken from the interest only:

```
redeemed_amount  = underlying.value()                  // input Coin<T>
interest         = max(0, redeemed_amount − principal_portion)
fee_amount       = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance    = redeemed_amount − fee_amount
```

`fee_house.fee_rate` is in basis points (`FEE_DENOMINATOR = 10_000`) and capped at `MAX_FEE_RATE = 3000` (30%) by `admin_set_fee`. The default is `2000` (20%).

TypeScript twin:

```typescript
const FEE_DENOMINATOR = 10_000n;
const MAX_FEE_RATE = 3_000n;

function applyYieldFee(
  redeemedAmount: bigint,
  principalPortion: bigint,
  feeRateBp: bigint,
): { interest: bigint; feeAmount: bigint; toBalance: bigint } {
  if (feeRateBp > MAX_FEE_RATE) throw new Error('EInvalidFeeRate (1003)');
  const interest = redeemedAmount > principalPortion
    ? redeemedAmount - principalPortion
    : 0n;
  const feeAmount = (interest * feeRateBp) / FEE_DENOMINATOR; // floor
  return {
    interest,
    feeAmount,
    toBalance: redeemedAmount - feeAmount,
  };
}
```

Important properties:

- If `redeemed_amount <= principal_portion` (loss / rounding-down case), `interest = 0` and `fee_amount = 0` — the principal is **never** taxed.
- `fee_amount` only accrues to `fee_house.fee` when `> 0`.
- The same fee path runs for owner / agent / protocol callers — yield fee is universal.

---

## 6. End-to-End Prediction Helper

Wrap the four formulas to predict the post-redeem `pm.balance[T]` delta given a snapshot:

```typescript
interface ReserveSnapshot {
  cash: bigint;
  debt: bigint;
  revenue: bigint;
  supply: bigint;
}

interface VaultSnapshot {
  scoinTotal: bigint;     // balance::value(&vault.scoin)
  principalTotal: bigint; // vault.principal
}

function predictRedeem(
  reserve: ReserveSnapshot,
  vault: VaultSnapshot,
  wantScoin: bigint,
  feeRateBp: bigint,
): {
  expectedUnderlying: bigint;
  principalPortion: bigint;
  interest: bigint;
  feeAmount: bigint;
  toBalance: bigint;
} {
  const expectedUnderlying = computeExpectedUnderlying(
    reserve.cash, reserve.debt, reserve.revenue, reserve.supply, wantScoin,
  );
  const pp = principalPortion(vault.principalTotal, vault.scoinTotal, wantScoin);
  const yieldFee = applyYieldFee(expectedUnderlying, pp, feeRateBp);
  return {
    expectedUnderlying,
    principalPortion: pp,
    interest: yieldFee.interest,
    feeAmount: yieldFee.feeAmount,
    toBalance: yieldFee.toBalance,
  };
}
```

Live Scallop redeem may pay slightly more than `expectedUnderlying` (the contract only asserts `>=`); use `expectedUnderlying` as the conservative lower bound for your strategy logic.

---

## 7. Reading Reserve State Off-Chain

The simplest approach is a dry-run of the same accrue-then-read PTB:

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. protocol::market::vault(market) → reserve
3. protocol::reserve::balance_sheets(reserve) → wit_table
4. wit_table::borrow(sheets, type_name<T>()) → balance_sheet
5. protocol::reserve::balance_sheet(sheet) → (cash, debt, revenue, supply)
```

Because cdpm imports the same view path (`protocol::reserve` + `x::wit_table`), any consistency you achieve in your dry run mirrors what `start_supply` / `start_redeem` will see if your real PTB also runs `accrue_interest_for_market` first.

---

## 8. Safety Margins

When sizing inputs:

- For `start_supply<T>`: `coin_amount × supply >= denom_underlying` to avoid `EZeroExpected`. In practice deposit at least a few hundred MIST equivalents.
- For `start_redeem<T>`: `scoin_amount × denom_underlying >= supply` for the same reason.
- For both, build in headroom against `EAmountShortfall` by either calling `accrue_interest_for_market` immediately before, or shaving a small slippage off `expected_*` and verifying live values match before signing.
