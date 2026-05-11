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

> **Pre-flight requirement (enforced).** The live PTB **must** run `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)` as its first command. cdpm now enforces this: `scallop_start_supply` / `scallop_start_redeem` take `&Clock` and assert `borrow_dynamics::last_updated_by_type(market.borrow_dynamics(), type<T>) == clock::timestamp_ms(clock) / 1000`. Omitting the pre-step aborts at the cdpm boundary with `EStaleScallopState (1011)` before any balance is touched. Off-chain dry runs and gRPC reads that do not simulate this command will also see a stale `balance_sheet` whose `denom_underlying` is smaller than reality and *over-predict* the sCoin mint / underlying redeem.

---

## 2. `compute_expected_scoin` (used by `scallop_start_supply`)

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

## 3. `compute_expected_underlying_scallop` (used by `scallop_start_redeem`)

```move
fun compute_expected_underlying_scallop<T>(market: &Market, scoin_amount: u64): u64 {
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

`EZeroExpected (1007)` when the result is `0` (the asserted-positive check happens inside `scallop_start_redeem`).

---

## 4. Principal Amortization (`pull_from_scallop_lending`)

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

## 5. Yield Fee Inside `scallop_finish_redeem`

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

Wrap the four formulas to predict the post-redeem `pm.balance[T]` delta given a snapshot. The same `ReserveSnapshot` / `VaultSnapshot` types are reused by the inverse helpers in section 7.

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

Live Scallop redeem may pay slightly more than `expectedUnderlying` (the contract only asserts `>=`); use `expectedUnderlying` as the conservative lower bound for your strategy logic. The same applies to `toBalance`: it is a lower bound on what actually lands in `pm.balance[T]` after `scallop_finish_redeem`.

### 6.1 Forward direction — "I burn N sCoin, what do I net?"

Already covered by `predictRedeem(reserve, vault, N, feeRateBp).toBalance`. This is the answer to *"what underlying lands in `pm.balance[T]`?"*. See section 3 for the raw `compute_expected_underlying_scallop` formula and section 5 for the yield-fee deduction.

---

## 7. Inverse Direction — Sizing Redemptions

The forward formulas in sections 2-6 answer "given an `N` sCoin to burn, what comes back?". The inverse — "I need at least `K` underlying, what `N` do I feed `scallop_start_redeem`?" — is what bots and rebalancing strategies actually need at call sites.

### 7.1 Inverse: sCoin to burn for target underlying (pre-fee)

`compute_expected_underlying_scallop` is `floor(N × denom / supply)`. To guarantee the on-chain output is `>= K`, invert with **ceiling** division:

```
scoin_to_burn = ceil(K × supply / denom)
              = (K × supply + denom − 1) / denom    // integer ceil
```

Use ceiling because Scallop's redeem floors the underlying output. If you ask for `floor(K × supply / denom)` sCoin you may receive 1 unit fewer than `K`. Ceiling rounds up so you receive `>= K` (possibly 1 unit more, never 1 unit less).

If the resulting `scoin_to_burn` exceeds `vault.scoinTotal`, the user wants more underlying than the vault contains. Either lower the target or `MAX_U64`-redeem the whole vault and accept whatever drains.

```typescript
const MAX_U64 = (1n << 64n) - 1n;

function ceilDiv(a: bigint, b: bigint): bigint {
  if (b <= 0n) throw new Error('ceilDiv: divisor must be positive');
  return (a + b - 1n) / b;
}

/**
 * Inverse of `compute_expected_underlying_scallop`. Returns the smallest `N` such that
 * `floor(N × denom / supply) >= desiredUnderlying`.
 *
 * Throws `EReserveEmpty (1006)` when `denom == 0` or `cash + debt < revenue`.
 * Returns `MAX_U64` when the vault cannot satisfy the target — caller should
 * either drain (`MAX_U64`-redeem) or downsize the request.
 */
function scoinToBurnForTargetUnderlying(
  reserve: ReserveSnapshot,
  desiredUnderlying: bigint,
  vaultScoinTotal: bigint,
): bigint {
  if (desiredUnderlying <= 0n) return 0n;
  if (reserve.supply === 0n) throw new Error('EReserveEmpty (1006)');
  if (reserve.cash + reserve.debt < reserve.revenue) {
    throw new Error('EReserveEmpty (1006)');
  }
  const denom = reserve.cash + reserve.debt - reserve.revenue;
  if (denom === 0n) throw new Error('EReserveEmpty (1006)');

  const n = ceilDiv(desiredUnderlying * reserve.supply, denom);
  return n > vaultScoinTotal ? MAX_U64 : n;
}
```

Note the `MAX_U64` sentinel: callers can pass that straight into `scallop_start_redeem`'s `market_coin_amount`; `pull_from_scallop_lending` clamps to the vault's `scoinTotal` and removes the vault entry, returning whatever the live reserve pays out.

### 7.2 Inverse: sCoin to burn for target **net** underlying (after yield-fee)

This is the practically useful inverse for an agent / bot driving redeems. Solve for `N` (sCoin to burn) such that the post-fee underlying credited to `pm.balance[T]` is `>= K`:

```
Let r = fee_rate / 10000           (e.g. 0.20 for 2000 bp)
Let π = P_vault / S_vault          (per-scoin principal share)
Let p = denom / supply             (per-scoin underlying value, "ε")

Per-sCoin redemption (real-arithmetic, ignoring floors):
  underlying_per_scoin        = p
  principal_portion_per_scoin ≈ π
  interest_per_scoin          = max(0, p − π)
  fee_per_scoin               = r × interest_per_scoin
  net_per_scoin               = p − fee_per_scoin
                              = p − r × max(0, p − π)
                              = p × (1 − r) + r × π     when p >  π   (typical, ε > 1)
                              = p                        when p <= π  (no interest, no fee)

So:
  N ≈ ceil(K / net_per_scoin)
    = ceil(K × 10000 × S_vault
           / ((10000 − r_bp) × denom × S_vault / supply + r_bp × P_vault))    when p >  π
    = ceil(K × supply / denom)                                                 when p <= π
```

The closed form is an *approximation* because each on-chain step floors independently:

1. `principal_portion = floor(P × N / S)` discards up to `1` unit of principal.
2. `expected_underlying = floor(N × denom / supply)` discards up to `1` unit of underlying.
3. `fee_amount = floor(interest × r_bp / 10000)` discards up to `1` unit of fee.

Each floor pushes `net` slightly *higher* than the closed-form predicts (less fee paid, less interest counted), which is safe — the closed form is a conservative *lower bound* on `net`, so the resulting `N` is occasionally 1 unit larger than the true minimum. That is acceptable; it never under-funds. Use the iterative refinement helper below if you want the exact minimum `N`.

```typescript
const FEE_DENOMINATOR = 10_000n;

/**
 * Closed-form approximation: smallest `N` such that the post-fee net
 * underlying credited to `pm.balance[T]` is `>= desiredNet`.
 *
 * Returns 0 when `desiredNet <= 0`. Returns `MAX_U64` when the vault cannot
 * satisfy the request — caller should drain.
 */
function scoinToBurnForTargetNetClosedForm(
  reserve: ReserveSnapshot,
  vault: VaultSnapshot,
  desiredNet: bigint,
  feeRateBp: bigint,
): bigint {
  if (desiredNet <= 0n) return 0n;
  if (reserve.supply === 0n) throw new Error('EReserveEmpty (1006)');
  if (reserve.cash + reserve.debt < reserve.revenue) {
    throw new Error('EReserveEmpty (1006)');
  }
  if (vault.scoinTotal === 0n) return MAX_U64;
  const denom = reserve.cash + reserve.debt - reserve.revenue;
  if (denom === 0n) throw new Error('EReserveEmpty (1006)');

  // p = denom / supply, π = P_vault / S_vault. Compare without dividing.
  // p > π  ⇔  denom × S_vault > supply × P_vault
  const pTimesS = denom * vault.scoinTotal;
  const piTimesS = reserve.supply * vault.principalTotal;
  const interestExists = pTimesS > piTimesS;

  let n: bigint;
  if (!interestExists) {
    // No interest, no fee — pure ceil(K × supply / denom).
    n = ceilDiv(desiredNet * reserve.supply, denom);
  } else {
    // net_per_scoin = ((10000 − r) × denom × S_vault + r × supply × P_vault)
    //                 / (10000 × supply × S_vault)
    // N = ceil(desiredNet / net_per_scoin)
    //   = ceil(desiredNet × 10000 × supply × S_vault
    //          / ((10000 − r) × denom × S_vault + r × supply × P_vault))
    const r = feeRateBp;
    const numer =
      desiredNet * FEE_DENOMINATOR * reserve.supply * vault.scoinTotal;
    const denomTerm =
      (FEE_DENOMINATOR - r) * denom * vault.scoinTotal +
      r * reserve.supply * vault.principalTotal;
    if (denomTerm === 0n) return MAX_U64;
    n = ceilDiv(numer, denomTerm);
  }

  return n > vault.scoinTotal ? MAX_U64 : n;
}

/**
 * Iterative refinement: starts from the closed-form approximation and bumps
 * `N` upward by 1 sCoin at a time until forward simulation
 * (`predictRedeem.toBalance`) confirms `>= desiredNet`. Caps at a small
 * iteration budget — in practice the closed form is exact or off-by-one.
 *
 * Returns either the minimum `N` that satisfies the target or `MAX_U64` when
 * the vault cannot.
 */
function scoinToBurnForTargetNet(
  reserve: ReserveSnapshot,
  vault: VaultSnapshot,
  desiredNet: bigint,
  feeRateBp: bigint,
  maxIterations: bigint = 8n,
): bigint {
  let n = scoinToBurnForTargetNetClosedForm(
    reserve, vault, desiredNet, feeRateBp,
  );
  if (n === MAX_U64) return MAX_U64;

  for (let i = 0n; i < maxIterations; i++) {
    if (n > vault.scoinTotal) return MAX_U64;
    if (n === 0n) { n = 1n; continue; }
    const sim = predictRedeem(reserve, vault, n, feeRateBp);
    if (sim.toBalance >= desiredNet) return n;
    n += 1n;
  }
  // Fell through the budget — vault probably cannot satisfy the request.
  return n > vault.scoinTotal ? MAX_U64 : n;
}
```

**Caveats:**

- The closed-form denominator `((10000 − r) × denom × S + r × supply × P)` can be very large under realistic mainnet values; `bigint` handles it without overflow but be aware that intermediate products are `O(u64⁴)`.
- The split between "interest exists" and "no interest" is a strict `>` on the cross-multiplied comparison. Equality (`p == π`) is degenerate — typically only at vault initialization before any yield has accrued, where there is also no interest to fee.
- In a *socialized loss* scenario where Scallop's reserve underflows and `denom < principal_per_scoin × supply / S_vault`, the per-scoin underlying drops below the per-scoin principal. The closed form correctly falls into the `interestExists = false` branch (no fee), but the redeemed amount is also less than the principal slice. Net is just `expected_underlying`; the fee path stays `0`. cdpm itself does not surface a special error for this — `scallop_finish_redeem` simply skips the fee branch and forwards the full underlying.

### 7.3 Worked Example

Vault state: `S_vault = 1000` sCoin, `P_vault = 950` underlying (principal). Reserve: `cash + debt − revenue = 1100`, `supply = 1050`. Fee rate = `2000` bp = 20%.

Implied per-sCoin values: `p = 1100/1050 ≈ 1.0476`, `π = 950/1000 = 0.95`. Since `p > π`, interest exists.

**Goal:** redeem so that `>= 100` underlying lands in `pm.balance[T]` net of fee.

1. `net_per_scoin = 1.0476 × 0.8 + 0.2 × 0.95 = 0.8381 + 0.19 = 1.0281`
2. Closed-form `N ≈ ceil(100 / 1.0281) = 98` sCoin.
3. Forward simulation with `N = 98`:
   - `principal_portion = floor(950 × 98 / 1000) = floor(93.1) = 93`
   - `expected_underlying = floor(98 × 1100 / 1050) = floor(102.67) = 102`
   - `interest = 102 − 93 = 9`
   - `fee = floor(9 × 2000 / 10000) = floor(1.8) = 1`
   - `net = 102 − 1 = 101`  →  `101 >= 100`  ✓

The forward sim confirms the closed form. The user feeds `scallop_start_redeem` with `market_coin_amount = 98`, the bot pays `1` underlying yield fee, and `pm.balance[T]` increases by `101`.

If `desiredNet` had been `103`, the closed-form would have returned `N = 101`, and forward sim would have yielded `net = 103` exactly — the iterative refinement helper would not have needed to bump.

---

## 8. Reading Reserve State Off-Chain

The simplest approach is a dry-run of the same accrue-then-read PTB:

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. protocol::market::vault(market) → reserve
3. protocol::reserve::balance_sheets(reserve) → wit_table
4. wit_table::borrow(sheets, type_name<T>()) → balance_sheet
5. protocol::reserve::balance_sheet(sheet) → (cash, debt, revenue, supply)
```

Because cdpm imports the same view path (`protocol::reserve` + `x::wit_table`), any consistency you achieve in your dry run mirrors what `scallop_start_supply` / `scallop_start_redeem` will see if your real PTB also runs `accrue_interest_for_market` first.

---

## 9. Safety Margins

When sizing inputs:

- For `scallop_start_supply<T>`: `coin_amount × supply >= denom_underlying` to avoid `EZeroExpected`. In practice deposit at least a few hundred MIST equivalents.
- For `scallop_start_redeem<T>`: `scoin_amount × denom_underlying >= supply` for the same reason. The inverse helpers in section 7 already enforce ceiling rounding, so they cannot produce `N = 0` for any positive target.
- For both, build in headroom against `EAmountShortfall` by either calling `accrue_interest_for_market` immediately before, or shaving a small slippage off `expected_*` and verifying live values match before signing.
- When using `scoinToBurnForTargetNet` for a rebalancing bot: re-snapshot `reserve` and `vault` *after* the accrual command and before signing — sizing on stale snapshots can leave you 1-2 underlying short on the very next block.

---

## 10. Reading Live Supply APY Off-Chain (Scallop vs Kai Picker)

The dominant cdpm use case for live rates is **"where do I park `pm.balance[T]` — Scallop or Kai?"**. cdpm holds the same underlying `T` in both vaults under different bag keys, so the decision is purely yield-driven: query both protocols' live supply APY, subtract the cdpm yield-fee, pick the higher. Scallop publishes its supply APY via [`@scallop-io/sui-scallop-sdk`](https://github.com/scallop-io/sui-scallop-sdk); the Kai twin lives in [`kai-lending-math.md` §10](./kai-lending-math.md). Borrow-side rates (`borrowApy`, kink fields, `maxBorrowApy`, etc.) are **not** part of the cdpm supply path — they are exposed by the same SDK but have no bearing on the parking decision.

### 10.1 SDK Setup

```typescript
import { Scallop } from '@scallop-io/sui-scallop-sdk';

// Instantiate ONCE at boot and reuse the singleton across every picker call.
// `createScallopQuery` runs `init()` which fetches the address bundle from
// `https://sui.apis.scallop.io/addresses/{addressId}` and warms internal
// caches; doing it per-call burns a network round-trip on each picker invocation.
const scallop = new Scallop({
  addressId: '67c44a103fe1b8c454eb9699',  // mainnet default — confirm via README
  networkType: 'mainnet',
});
const query = await scallop.createScallopQuery();
```

No `secretKey` is required for read paths (`getMarketPool`, `queryMarket`, etc.) — it is only needed when the SDK signs and submits transactions on your behalf, which cdpm flows do not do (the cdpm app signs).

`addressId` points at Scallop's address-bundle service; the SDK pulls every package / object id (`SCALLOP_VERSION_ID`, `SCALLOP_MARKET_ID`, sCoin types, etc.) from there, so a single id update is all you need when Scallop pushes a package upgrade. The same bundle is reachable as a plain HTTP `GET https://sui.apis.scallop.io/addresses/{addressId}` for read-only consumers that prefer not to add the SDK as a dependency.

### 10.2 Rate-Query Methods

```typescript
// Single market — returns MarketPool | undefined (undefined when the symbol
// is not in the runtime whitelist or the pool fetch failed).
const usdcPool = await query.getMarketPool('usdc');
if (!usdcPool) { /* fall through to idle */ }

// Many markets — returns { pools, collaterals }, where pools is
// Record<symbol, MarketPool | undefined>. There is NO array-shaped overload.
const { pools } = await query.getMarketPools(['sui', 'usdc', 'usdt']);
const suiPool = pools.sui;        // MarketPool | undefined
const usdcPool2 = pools.usdc;

// Whole market snapshot — supply pools + collateral pools in one call.
const market = await query.queryMarket();
```

`getMarketPool(name)` internally calls `getMarketPools(undefined, …)` which fetches the **entire whitelisted set** in one shot, so a single-pool call costs the same as `queryMarket`. If you need more than one pool, prefer the batched form and read what you need from `pools.*`.

The authoritative coin-name set is the runtime `query.constants.whitelist.lending` (a `Set<string>`); typos pass through as `undefined` rather than throwing. Use that set for menu-driven UIs and `Set.has(name)` guards. For the underlying type in your cdpm PTB, resolve back via `pool.coinType` (`Move` type tag) and `pool.marketCoinType` / `pool.sCoinType` for the sCoin side.

### 10.3 `MarketPool` Field Reference (Supply-Only Subset)

The fields that matter for the parking decision:

| Field | Type | Meaning |
|-------|------|---------|
| `supplyApy` | `number` | Compounded annualized supply yield. The primary decision input. `0.052` means 5.2% APY. |
| `supplyApr` | `number` | Simple annualized rate, before compounding. Use when comparing to a quote already framed as APR. |
| `utilizationRate` | `number` | `borrowAmount / supplyAmount`. Higher utilization = higher live `supplyApy`, but also tighter `cash` reserves (slower redeems if `cash` runs low). Sanity-check that utilization is well below 1.0 before parking large amounts. |
| `conversionRate` | `number` | Live underlying-per-sCoin (`supplyAmount / marketCoinSupplyAmount`). Cross-check against your `predictRedeem` output before broadcasting. |
| `growthInterest` | `number` | **Cumulative** interest factor since the on-chain `lastUpdated` — `currentBorrowIndex / borrowIndex − 1`. NOT a per-second rate; it's the multiplicative growth that has accrued but not yet been written to `balance_sheet`. Useful for verifying `accrue_interest_for_market` is needed before sizing. |
| `supplyAmount`, `borrowAmount`, `reserveAmount` | `number` | **Raw `u64` totals** (cash + debt − reserve etc., undivided by decimals). |
| `supplyCoin`, `borrowCoin`, `reserveCoin` | `number` | **Decimaled** equivalents (`raw / 10^coinDecimal`). Use these for human-readable display; use the raw forms for ratio math against on-chain values. |
| `marketCoinSupplyAmount` | `number` | sCoin supply, raw `u64` (same as `supply` in §1). |
| `coinType` | `string` | Move type tag for `T`. Thread back into the cdpm PTB without hardcoding. |
| `marketCoinType`, `sCoinType` | `string` | Move type tags for `MarketCoin<T>` (legacy) and the new sCoin (preferred). |
| `coinDecimal`, `coinPrice` | `number` | Decimals (used by the SDK for the raw↔decimaled split above) and live USD price. `coinPrice` is `0` when the price feed is stale. |
| `isIsolated` | `boolean` | Isolated markets have stricter caps and (sometimes) different rate curves. Worth surfacing in any UI that lets users pick a market. |
| `maxSupplyCoin` | `number` | Per-market supply cap, decimaled. If your `idleAmount` plus `supplyCoin` would breach this, `scallop_start_supply` will be rejected on-chain — short-circuit before submitting. |

`MarketPool` also exposes borrow-side fields (`borrowApy`, `baseBorrowApy`, `borrowApyOnMidKink`, `borrowApyOnHighKink`, `maxBorrowApy`, `borrowFee`, `borrowWeight`, etc.). These describe Scallop's borrow market and are unrelated to cdpm's supply-only integration; do not pull them into supply-decision code paths — they will only confuse the picker.

> **Note on units.** Earlier revisions of this doc inverted the `supplyAmount` / `supplyCoin` decimal split. The correct semantics (verified in `sui-scallop-sdk/src/utils/query.ts:118-163`) is: `supplyAmount` / `borrowAmount` / `reserveAmount` are raw `u64`; `supplyCoin` / `borrowCoin` / `reserveCoin` apply `BigNumber.shiftedBy(-coinDecimal)`.

### 10.4 Decision Recipe — Scallop vs Kai Supply Picker

Both protocols can hold the same underlying `T` simultaneously (`pm.lending` keys differ — `type_name<T>` for Scallop, `type_name<YT>` for Kai). The cdpm yield-fee is identical across both, so the fee cancels in the comparison and the picker reduces to "raw `supplyApy` is higher → park there". Always query both before signing — utilization and Kai's time-locked unlock schedule both move continuously, and the winner can flip block-to-block.

```typescript
import { Scallop } from '@scallop-io/sui-scallop-sdk';
import {
  VAULTS,
  getVaultStats,
  type VaultInfo,
} from '@kunalabs-io/kai';
import { SuiClient } from '@mysten/sui/client';

type Venue = 'scallop' | 'kai' | 'idle';

interface PickResult {
  venue: Venue;
  apy: number;          // raw supply APY (cdpm fee cancels in the comparison)
  detail: {
    scallopApy: number;
    kaiApy: number | null;       // null if no Kai vault for this T
    utilization: number;          // Scallop pool utilization
  };
}

/**
 * Pick the better supply venue for a given underlying.
 *
 * - `scallopCoinName` is the SDK's coin alias ('usdc', 'sui', 'usdt', ...).
 * - `kaiVaultKey` is a key into the `VAULTS` map ('USDC', 'suiUSDT', ...);
 *   pass `null` when no Kai vault exists for this underlying — the picker
 *   then degenerates to a Scallop-vs-idle gate.
 * - `minApy` (e.g. 0.005) gates against parking when even the better venue
 *   pays less than gas-amortized round-trip cost. Tune per chain conditions.
 */
async function pickSupplyVenue(
  client: SuiClient,
  query: Awaited<ReturnType<Scallop['createScallopQuery']>>,  // pre-built singleton — see §10.1
  scallopCoinName: string,
  kaiVaultKey: keyof typeof VAULTS | null,
  minApy: number = 0.005,
): Promise<PickResult> {
  const [scallopPool, kaiStats] = await Promise.all([
    query.getMarketPool(scallopCoinName),                       // MarketPool | undefined
    kaiVaultKey
      ? VAULTS[kaiVaultKey].fetch(client).then(getVaultStats)
      : Promise.resolve(null),
  ]);

  const scallopApy   = scallopPool?.supplyApy ?? -Infinity;     // null-guard: symbol may be absent
  const utilization  = scallopPool?.utilizationRate ?? 0;
  const kaiApy       = kaiStats?.apy ?? null;

  const detail = { scallopApy, kaiApy, utilization };

  const best = Math.max(scallopApy, kaiApy ?? -Infinity);
  if (!Number.isFinite(best) || best < minApy) {
    return { venue: 'idle', apy: best, detail };
  }

  const venue: Venue = (kaiApy !== null && kaiApy >= scallopApy) ? 'kai' : 'scallop';
  return { venue, apy: best, detail };
}
```

Notes on the picker:

- **Fee cancels.** cdpm's yield-fee is taken on redeem from the interest portion regardless of venue (`scallop_finish_redeem` and `kai_finish_redeem` share `fee_house.fee_rate`). When comparing two `supplyApy` numbers under the same fee, the `(1 − r)` factor is symmetric and drops out — compare raw APY directly.
- **`Promise.all`.** Both reads are independent gRPC calls; doing them in parallel halves the picker's wall-clock latency, which matters for rebalance bots that re-pick every block.
- **Utilization tripwire.** If `scallopPool.utilizationRate > 0.9` (or whatever your chain-condition threshold is), `cash` is thin and a same-block redeem may not have liquidity. Either downgrade Scallop's effective rank (subtract a liquidity-risk premium from `scallopApy`), or just skip Scallop for now. Kai has no equivalent metric — its `total_available_balance` already nets out the strategy locks.
- **No Kai vault available.** When `kaiVaultKey` is `null`, the picker degenerates to "Scallop or idle" cleanly. The reverse — a Kai vault exists but no Scallop market — is rare for major underlyings; if it happens, drop Scallop from the call and use `getVaultStats` alone.
- **APR vs APY.** Both SDKs report compounded `apy` and simple `apr`. cdpm itself doesn't compound (interest realizes only on redeem), so comparing `apy` is closest to "what the PM actually earns over the idle window". If you compare `apr`, do it consistently across both venues.

Heuristic numbers to keep in mind: at 5% APY, a 100 MIST gas round-trip pays for itself within ~12 hours on any idle balance ≥ 22 MIST × coin-decimal multiplier. For typical mainnet USDC parking (6 decimals, 100k+ MIST balances), the picker should almost always return a non-`idle` venue — the only reason to gate is when both venues are paying near zero (Scallop with very low utilization + Kai near `finalUnlockTsSec`).

### 10.5 PTB-Builder Hooks — SDK Composables Inside cdpm's Hot-Potato

Scallop's SDK exposes **two layers** of builders:

| Layer | Methods | Coin source | Composable with cdpm? |
|---|---|---|---|
| High-level (wallet-rooted) | `scallopTxBlock.depositQuick(amount, coinName)`, `withdrawQuick(amount, coinName)`, `borrowQuick`, `repayQuick`, etc. | **Wallet.** Each `*Quick` runs `coinWithBalance` against `tx.gas` / wallet coins internally. | **No.** cdpm's `scallop_start_supply` returns the tx-result `Coin<T>` — there is no wallet coin to pull from. |
| Granular (tx-result-rooted) | `scallopTxBlock.deposit(coin, poolCoinName)` → `Coin<MarketCoin<T>>`, `scallopTxBlock.withdraw(marketCoin, poolCoinName)` → `Coin<T>`, plus `addCollateral / takeCollateral / borrow / repay` siblings (see `sui-scallop-sdk/src/builders/coreBuilder.ts:139-180`). | **Tx-result coin** passed directly. | **Yes.** Slots into cdpm's PTB between `scallop_start_supply` and `scallop_finish_supply`. |

The granular `deposit` / `withdraw` builders wrap `protocol::mint::mint<T>` / `protocol::redeem::redeem<T>`. Important detail: Scallop's `mint` and `redeem` Move modules **call `accrue_all_interests` internally** (see `sui-lending-protocol/.../market.move` `handle_redeem` at line 296 and `handle_mint` at line 307), so an explicit `protocol::accrue_interest::accrue_interest_for_market` command before them is redundant for the move-call itself. cdpm still benefits from running it as command 1 so that the off-chain sizing helpers in §7 / §10 match the on-chain `balance_sheet` snapshot the cdpm `scallop_start_*` ticket records — the accrue command is about *off-chain prediction freshness*, not about Scallop's mint/redeem correctness.

**Updated cdpm Scallop supply PTB using the SDK granular builder:**

```typescript
import { Scallop } from '@scallop-io/sui-scallop-sdk';

const builder = await scallop.createScallopBuilder();
const txBlock = builder.createTxBlock();
txBlock.setSender(senderAddress);

// 1. REQUIRED PTB[0] — cdpm asserts EStaleScallopState (1011) without this.
//    NOT injected by scallopTx.deposit / depositQuick.
txBlock.moveCall({
  target: `${SCALLOP_PROTOCOL}::accrue_interest::accrue_interest_for_market`,
  arguments: [
    txBlock.object(SCALLOP_VERSION_ID),
    txBlock.object(SCALLOP_MARKET_ID),
    txBlock.object('0x6'),
  ],
});

// 2. cdpm hot-potato start — takes &Clock for the freshness floor (EStaleScallopState=1011).
const [coinT, ticket] = txBlock.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_start_supply`,
  typeArguments: [underlyingCoinType],
  arguments: [
    txBlock.object(CDPM_MAINNET.ACCESS_LIST_ID),
    txBlock.object(pmId),
    txBlock.object(SCALLOP_MARKET_ID),
    txBlock.object('0x6'),
    txBlock.pure.u64(amount),
  ],
});

// 3. Replace the manual `protocol::mint::mint` move-call with the SDK helper.
const coinMarket = txBlock.deposit(coinT, 'usdc');     // → tx-result Coin<MarketCoin<T>>

// 4. cdpm hot-potato finish — re-takes &Market (EWrongMarket=1012).
txBlock.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_finish_supply`,
  typeArguments: [underlyingCoinType],
  arguments: [
    txBlock.object(pmId),
    txBlock.object(SCALLOP_MARKET_ID),
    ticket,
    coinMarket,
  ],
});

await suiClient.signAndExecuteTransaction({ signer, transaction: txBlock });
```

Redeem mirrors this — replace the `protocol::redeem::redeem` move-call with `txBlock.withdraw(coinMarket, 'usdc')`. The cdpm `scallop_start_redeem` / `scallop_finish_redeem` calls remain raw `tx.moveCall` against `${CDPM_PACKAGE}::cdpm::*` — only the inner Scallop command changes.

**Why prefer the granular builder over raw `tx.moveCall`?**

1. **Address resolution comes for free.** `txBlock.deposit('usdc')` resolves `SCALLOP_VERSION_ID`, `SCALLOP_MARKET_ID`, the `Coin<T>` type tag, and the witness types from the SDK's address bundle — no per-protocol-upgrade constant edits.
2. **Type-tag plumbing is implicit.** The SDK reads `MarketPool.coinType` / `MarketPool.marketCoinType` from the same bundle, so a coin-name change on the Scallop side doesn't require a cdpm code-side edit.
3. **One package upgrade away.** When Scallop pushes a `mint` / `redeem` signature change, the SDK absorbs it; raw `tx.moveCall` recipes would silently break on the next upgrade.

The wallet-rooted `*Quick` methods are useful for direct wallet-to-Scallop flows *outside* cdpm (e.g. a user redeeming sCoin they hold independently of any PositionManager). They have no role inside a cdpm hot-potato flow — cdpm exposes no wrapper-extract function, so no cdpm path ever lands raw sCoin in the owner / agent / protocol wallet.

For now the operational PTB recipes in [`cdpm-user-sdk/reference/scallop-lending.md`](../../cdpm-user-sdk/reference/scallop-lending.md) (and the agent / protocol counterparts) still show the raw `tx.moveCall` shape for clarity. Both shapes are correct; pick whichever fits your call-site abstraction.

> **Cross-protocol composition.** When the same PTB needs both Scallop and Kai legs (e.g. an atomic Scallop ↔ Kai rebalance, or any flow where the picker's choice should not gate atomicity at the tx layer), see the dedicated guide at [`cross-protocol-ptb.md`](./cross-protocol-ptb.md). It documents the canonical Mysten-rooted shared-`Transaction` pattern, the multi-approach comparison, five integration caveats (signing target, `setSender`, `@mysten/sui` dependency pinning, no `*Quick` outputs into cdpm finishes, re-snapshot before signing), and worked rebalance examples.

### 10.6 Using the SDK Strictly for Address Resolution

Even when you build cdpm PTBs manually (without the granular builders in §10.5), the SDK is the cleanest source of Scallop package / object ids. The actual API lives on `scallop.client.address` — `scallop.getAddresses()` does NOT exist:

```typescript
// Singleton getter — string-or-undefined, validated against AddressStringPath.
const SCALLOP_PROTOCOL   = scallop.client.address.get('core.packages.protocol.id');
const SCALLOP_VERSION_ID = scallop.client.address.get('core.version');
const SCALLOP_MARKET_ID  = scallop.client.address.get('core.market');

// Or grab the whole bundle once and pluck what you need.
const bundle = scallop.client.address.getAddresses();
```

The path keys are typed via `AddressStringPath` (`sui-scallop-sdk/src/types/address.ts:175-178`); typos return `undefined` at runtime rather than throwing, so wrap reads in an assertion if a missing key would silently break your PTB.

Reading these once at boot and reusing them across all cdpm Scallop PTBs survives Scallop upgrades that bump the package id but keep the move-call shapes intact — without it, every Scallop upgrade requires a cdpm-side constant edit.

### 10.7 Error / Staleness Notes

- The SDK caches address-bundle reads. To force-refresh, call `await scallop.client.address.read(addressId)` (it re-fetches `https://sui.apis.scallop.io/addresses/{addressId}` and repopulates the bundle). There is no `scallop.fetchAddresses()` shortcut.
- `queryMarket` / `getMarketPool` already trigger an off-chain recompute that mimics `accrue_interest_for_market`, so the returned `supplyApy` is fresh as of the SDK call. The on-chain `balance_sheet`, however, is **only** fresh after a real PTB runs `accrue_interest_for_market` — your sizing helpers (§7) still need that command first.
- If you compare `pool.conversionRate × supply` against your `predictRedeem.expectedUnderlying`, expect tiny discrepancies — the SDK uses floats internally; cdpm and the on-chain reserve do u128 ceil/floor. Treat the SDK numbers as decision-grade, not settlement-grade.
- For pure read-only consumers (e.g., a dashboard that only displays APY), fetching `https://sui.apis.scallop.io/addresses/{addressId}` directly avoids pulling in the full SDK; pair it with a hand-rolled `getMarketPool` over the resolved object ids if dependency size matters.
