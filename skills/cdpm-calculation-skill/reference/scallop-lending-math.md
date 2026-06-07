# Scallop Lending Math

## Contents

- [1. Reserve Snapshot](#1-reserve-snapshot)
- [2. `predictScallopMint` (off-chain twin of `protocol::mint::mint`)](#2-predictscallopmint-off-chain-twin-of-protocolmintmint)
- [3. `predictScallopRedeem` (off-chain twin of `protocol::redeem::redeem`)](#3-predictscallopredeem-off-chain-twin-of-protocolredeemredeem)
- [4. Principal Amortization (`pull_from_scallop_lending`)](#4-principal-amortization-pull_from_scallop_lending)
- [5. Yield Fee Inside `scallop_redeem`](#5-yield-fee-inside-scallop_redeem)
- [6. End-to-End Prediction Helper](#6-end-to-end-prediction-helper)
- [7. Inverse Direction — Sizing Redemptions](#7-inverse-direction-sizing-redemptions)
- [8. Reading Reserve State Off-Chain](#8-reading-reserve-state-off-chain)
- [9. Safety Margins](#9-safety-margins)
- [10. Reading Live Supply APY Off-Chain (Scallop vs Kai Picker)](#10-reading-live-supply-apy-off-chain-scallop-vs-kai-picker)

## 1. Reserve Snapshot

The off-chain twins of `protocol::mint::mint` / `protocol::redeem::redeem` read four `u64` values from Scallop's `protocol::reserve::balance_sheet` for the underlying type `T`:

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

A healthy reserve has `cash + debt >= revenue` and `denom_underlying > 0`. When either fails, Scallop's upstream `mint` / `redeem` is the authoritative source of behavior; the off-chain predictor should treat the state as unsizable and either widen its slippage budget or skip the action.

> **Pre-flight accrual.** `protocol::mint::mint` and `protocol::redeem::redeem` call `accrue_interest_for_market` as their first step, so the on-chain `balance_sheet` they consume is fresh relative to the PTB clock by construction. Off-chain dry runs and gRPC reads that read `balance_sheet` without first simulating an accrue see a stale snapshot whose `denom_underlying` is smaller than reality and **over-predict** the sCoin mint / underlying redeem. To match what `scallop_supply` / `scallop_redeem` will see on-chain, run a `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)` dry-run command before reading `balance_sheet`, or use the dev-inspect simulation pattern in §8.

---

## 2. `predictScallopMint` (off-chain twin of `protocol::mint::mint`)

```
expected_scoin =
  supply == 0 ? coin_amount
              : floor(coin_amount × supply / (cash + debt − revenue))
```

TypeScript twin:

```typescript
function predictScallopMint(
  cash: bigint,
  debt: bigint,
  revenue: bigint,
  supply: bigint,
  coinAmount: bigint,
): bigint {
  if (supply === 0n) {
    return coinAmount; // bootstrap: 1:1 sCoin per underlying
  }
  if (cash + debt < revenue) {
    throw new Error('Scallop reserve revenue exceeds cash + debt');
  }
  const denom = cash + debt - revenue;
  if (denom === 0n) {
    throw new Error('Scallop reserve lendable denominator is zero');
  }
  return (coinAmount * supply) / denom; // floor division
}
```

Edge cases:

- **Bootstrap** (`supply == 0`): Scallop's `mint` returns `coin_amount` directly (1:1).
- **Degenerate** (`coin_amount × supply < denom`): the floor returns `0`. `scallop_supply` still runs — the `Balance<MarketCoin<T>>` joined into `pm.lending` is zero, and the `ScallopSupplied` event records `market_coin_minted: 0`. Off-chain sizing should increase the input rather than rely on this.

---

## 3. `predictScallopRedeem` (off-chain twin of `protocol::redeem::redeem`)

```
expected_underlying = floor(scoin_amount × (cash + debt − revenue) / supply)
```

This is the inverse of `predictScallopMint`.

```typescript
function predictScallopRedeem(
  cash: bigint,
  debt: bigint,
  revenue: bigint,
  supply: bigint,
  scoinAmount: bigint,
): bigint {
  if (supply === 0n) {
    throw new Error('Scallop reserve sCoin supply is zero');
  }
  if (cash + debt < revenue) {
    throw new Error('Scallop reserve revenue exceeds cash + debt');
  }
  const denom = cash + debt - revenue;
  return (scoinAmount * denom) / supply; // floor division
}
```

When the result is `0`, the redeem call still runs and credits `0` underlying to `pm.balance[T]` (less the yield fee, which is also `0` since there is no interest).

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

TypeScript twin (matches the on-chain `pull_from_scallop_lending` formula):

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

Properties:

- Floor-division can leave 1 unit of principal "stuck" in the vault after a partial redeem; benign — swept on a later full drain.
- `principal_portion <= P_total` always.
- Monotonically non-decreasing in `wantAmount`.

This formula is structurally identical to Kai's `pull_from_kai_lending`; the only difference is the bag key and the type of the inner balance (`Balance<MarketCoin<T>>` vs `Balance<YT>`).

---

## 5. Yield Fee Inside `scallop_redeem`

The interest portion is whatever Scallop returned beyond the principal slice; the yield fee is taken from the interest only:

```
redeemed_amount  = balance::value(&underlying)            // result of redeem::redeem
interest         = max(0, redeemed_amount − principal_portion)
fee_amount       = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance    = redeemed_amount − fee_amount
```

`fee_house.fee_rate` is in basis points (`FEE_DENOMINATOR = 10_000`) and capped at `MAX_FEE_RATE = 5000` (50%) by `admin_set_fee`. The default is `2000` (20%).

TypeScript twin:

```typescript
const FEE_DENOMINATOR = 10_000n;
const MAX_FEE_RATE = 5_000n;

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
- The same fee path runs for owner / agent / protocol callers — the yield fee is universal.

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
  const expectedUnderlying = predictScallopRedeem(
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

`expectedUnderlying` is the off-chain prediction of what `redeem::redeem` will return; `toBalance` is the predicted increment to `pm.balance[T]` after the yield-fee carve-out. Both can drift by ±1 raw against the live execution because the off-chain `balance_sheet` snapshot is read before the PTB clock and Scallop's auto-accrual inside `redeem::redeem` advances `denom` by a few units.

### 6.1 Forward direction — "I burn N sCoin, what do I net?"

Already covered by `predictRedeem(reserve, vault, N, feeRateBp).toBalance`. This is the answer to *"what underlying lands in `pm.balance[T]`?"*. See section 3 for the raw `predictScallopRedeem` formula and section 5 for the yield-fee deduction.

---

## 7. Inverse Direction — Sizing Redemptions

The forward formulas in sections 2-6 answer "given an `N` sCoin to burn, what comes back?". The inverse — "I need at least `K` underlying, what `N` do I feed `scallop_redeem`?" — is what bots and rebalancing strategies actually need at call sites.

### 7.1 Inverse: sCoin to burn for target underlying (pre-fee)

`predictScallopRedeem` is `floor(N × denom / supply)`. To guarantee the on-chain output is `>= K`, invert with **ceiling** division:

```
scoin_to_burn = ceil(K × supply / denom)
              = (K × supply + denom − 1) / denom    // integer ceil
```

Use ceiling because Scallop's redeem floors the underlying output. If you ask for `floor(K × supply / denom)` sCoin you may receive 1 unit fewer than `K`. Ceiling rounds up so you receive `>= K` (possibly 1 unit more, never 1 unit less).

If the resulting `scoin_to_burn` exceeds `vault.scoinTotal`, the user wants more underlying than the vault contains. Either lower the target or pass `MAX_U64` to drain the whole vault entry and accept whatever the redeem pays out.

```typescript
const MAX_U64 = (1n << 64n) - 1n;

function ceilDiv(a: bigint, b: bigint): bigint {
  if (b <= 0n) throw new Error('ceilDiv: divisor must be positive');
  return (a + b - 1n) / b;
}

/**
 * Inverse of `predictScallopRedeem`. Returns the smallest `N` such that
 * `floor(N × denom / supply) >= desiredUnderlying`.
 *
 * Returns `MAX_U64` when the vault cannot satisfy the target — caller should
 * either drain (pass `MAX_U64` as `scoin_amount`) or downsize the request.
 */
function scoinToBurnForTargetUnderlying(
  reserve: ReserveSnapshot,
  desiredUnderlying: bigint,
  vaultScoinTotal: bigint,
): bigint {
  if (desiredUnderlying <= 0n) return 0n;
  if (reserve.supply === 0n) throw new Error('Scallop reserve sCoin supply is zero');
  if (reserve.cash + reserve.debt < reserve.revenue) {
    throw new Error('Scallop reserve revenue exceeds cash + debt');
  }
  const denom = reserve.cash + reserve.debt - reserve.revenue;
  if (denom === 0n) throw new Error('Scallop reserve lendable denominator is zero');

  const n = ceilDiv(desiredUnderlying * reserve.supply, denom);
  return n > vaultScoinTotal ? MAX_U64 : n;
}
```

The `MAX_U64` sentinel: callers can pass that straight into `scallop_redeem`'s `scoin_amount`; `pull_from_scallop_lending` clamps to the vault's `scoinTotal` and removes the vault entry, returning whatever the live reserve pays out.

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
  if (reserve.supply === 0n) throw new Error('Scallop reserve sCoin supply is zero');
  if (reserve.cash + reserve.debt < reserve.revenue) {
    throw new Error('Scallop reserve revenue exceeds cash + debt');
  }
  if (vault.scoinTotal === 0n) return MAX_U64;
  const denom = reserve.cash + reserve.debt - reserve.revenue;
  if (denom === 0n) throw new Error('Scallop reserve lendable denominator is zero');

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
  return n > vault.scoinTotal ? MAX_U64 : n;
}
```

**Caveats:**

- The closed-form denominator `((10000 − r) × denom × S + r × supply × P)` can be very large under realistic mainnet values; `bigint` handles it without overflow but be aware that intermediate products are `O(u64⁴)`.
- The split between "interest exists" and "no interest" is a strict `>` on the cross-multiplied comparison. Equality (`p == π`) is degenerate — typically only at vault initialization before any yield has accrued, where there is also no interest to fee.
- In a *socialized loss* scenario where Scallop's reserve underflows and `denom < principal_per_scoin × supply / S_vault`, the per-scoin underlying drops below the per-scoin principal. The closed form correctly falls into the `interestExists = false` branch (no fee), but the redeemed amount is also less than the principal slice. Net is just `expected_underlying`; the fee path stays `0`. `scallop_redeem` simply skips the fee branch and forwards the full underlying.

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
   - `net = 102 − 1 = 101`  →  `101 >= 100`  

The forward sim confirms the closed form. The user feeds `scallop_redeem` with `scoin_amount = 98`, the bot pays `1` underlying yield fee, and `pm.balance[T]` increases by `101`.

If `desiredNet` had been `103`, the closed-form would have returned `N = 101`, and forward sim would have yielded `net = 103` exactly — the iterative refinement helper would not have needed to bump.

---

## 8. Reading Reserve State Off-Chain

The simplest approach is a dry-run of the same accrue-then-read PTB Scallop performs internally during `mint` / `redeem`:

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. protocol::market::vault(market) → reserve
3. protocol::reserve::balance_sheets(reserve) → wit_table
4. wit_table::borrow(sheets, type_name<T>()) → balance_sheet
5. protocol::reserve::balance_sheet(sheet) → (cash, debt, revenue, supply)
```

Because `scallop_supply` / `scallop_redeem` call `mint::mint` / `redeem::redeem`, which themselves run `accrue_interest_for_market` as the first step, the on-chain `balance_sheet` consumed by the move-call is fresh. To make your off-chain prediction match, simulate the accrue command first.

---

## 9. Safety Margins

When sizing inputs:

- For `scallop_supply<T>`: `coin_amount × supply >= denom_underlying` to keep the predicted `expected_scoin > 0`. In practice deposit at least a few hundred MIST equivalents.
- For `scallop_redeem<T>`: `scoin_amount × denom_underlying >= supply` for the same reason on the inverse direction. The inverse helpers in section 7 already enforce ceiling rounding, so they cannot produce `N = 0` for any positive target.
- When using `scoinToBurnForTargetNet` for a rebalancing bot: re-snapshot `reserve` and `vault` immediately before signing — sizing on stale snapshots can leave you 1-2 underlying short on the very next block.

### 9.1 Floor-div dust on the redeem path

`scallop_redeem` runs the full redemption as a single move-call: it pulls sCoin from `pm.lending`, calls `protocol::redeem::redeem`, deducts the yield fee from `interest`, and credits the residual to `pm.balance[T]`. The redeemed amount is whatever `redeem::redeem` actually returns; there is no off-chain prediction enforced at the cdpm boundary, so a floor-div mismatch between off-chain twin and live reserve cannot abort the transaction. It can only leave the realized `pm.balance[T]` increment 1-2 raw below the predicted `toBalance`.

This matters most when composing the redeem with a downstream `add_liquidity` in the same PTB. Two patterns:

1. **Treat `predictScallopRedeem` as a strict upper bound.** Size the downstream `add_liquidity` against `floor(predicted) − safety_margin` (a few raw is plenty) rather than `predicted` itself. If the live redeem comes in one raw short, the smaller add still passes; if it comes in one raw over, the residual stays in `pm.balance[T]` and deploys next cycle.
2. **Cap the burn on partial drains.** Pass `scoin_amount = min(needed, scoinTotal − LENDING_SAFE_MARGIN_WRAPPER_RAW)` (recommended default 100 sCoin raw). This leaves a residual entry in `pm.lending` so the bag key survives — useful when a later top-up will re-credit principal into the same entry.

```typescript
const LENDING_SAFE_MARGIN_WRAPPER_RAW = 100n;

function capRedeemBurnRaw(exact: bigint, scoinTotal: bigint): bigint | null {
  if (scoinTotal <= LENDING_SAFE_MARGIN_WRAPPER_RAW) return null;
  const safeMax = scoinTotal - LENDING_SAFE_MARGIN_WRAPPER_RAW;
  return exact >= safeMax ? safeMax : exact;
}
```

Cross-references:

- `cdpm-protocol-sdk/reference/scallop-lending.md` — protocol PTB template
- `cdpm-agent-sdk/reference/scallop-lending.md` — agent PTB template
- `cdpm-user-sdk/reference/scallop-lending.md` — owner / close-PM PTB template
- `cdpm-calculation-skill/reference/cross-protocol-ptb.md` §3 — cross-protocol composition

---

## 10. Reading Live Supply APY Off-Chain (Scallop vs Kai Picker)

The dominant cdpm use case for live rates is **"where do I park `pm.balance[T]` — Scallop or Kai?"**. cdpm holds the same underlying `T` in both vaults under different bag keys, so the decision is purely yield-driven: query both protocols' live supply APY, subtract the cdpm yield-fee, pick the higher. Scallop publishes its supply APY via [`@scallop-io/sui-scallop-sdk`](https://github.com/scallop-io/sui-scallop-sdk); the Kai twin lives in [`kai-lending-math.md` §10](./kai-lending-math.md). Borrow-side rates (`borrowApy`, kink fields, `maxBorrowApy`, etc.) are not part of the cdpm supply path — they are exposed by the same SDK but have no bearing on the parking decision.

### 10.1 SDK Setup

Install (alongside `@mysten/sui` — pin the same major across the dep tree, see `cross-protocol-ptb.md` for the `instanceof Transaction` pitfall):

```bash
bun add @scallop-io/sui-scallop-sdk @mysten/sui
# or: npm install / pnpm add / yarn add
```

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
| `growthInterest` | `number` | Cumulative interest factor since the on-chain `lastUpdated` — `currentBorrowIndex / borrowIndex − 1`. NOT a per-second rate; it's the multiplicative growth that has accrued but not yet been written to `balance_sheet`. Useful for verifying the off-chain dry-run accrual makes sense before sizing. |
| `supplyAmount`, `borrowAmount`, `reserveAmount` | `number` | Raw `u64` totals (cash + debt − reserve etc., undivided by decimals). |
| `supplyCoin`, `borrowCoin`, `reserveCoin` | `number` | Decimaled equivalents (`raw / 10^coinDecimal`). Use these for human-readable display; use the raw forms for ratio math against on-chain values. |
| `marketCoinSupplyAmount` | `number` | sCoin supply, raw `u64` (same as `supply` in §1). |
| `coinType` | `string` | Move type tag for `T`. Thread back into the cdpm PTB without hardcoding. |
| `marketCoinType`, `sCoinType` | `string` | Move type tags for `MarketCoin<T>` (legacy) and the new sCoin (preferred). |
| `coinDecimal`, `coinPrice` | `number` | Decimals (used by the SDK for the raw↔decimaled split above) and live USD price. `coinPrice` is `0` when the price feed is stale. |
| `isIsolated` | `boolean` | Isolated markets have stricter caps and (sometimes) different rate curves. Worth surfacing in any UI that lets users pick a market. |
| `maxSupplyCoin` | `number` | Per-market supply cap, decimaled. If your `idleAmount` plus `supplyCoin` would breach this, `scallop_supply` will be rejected on-chain — short-circuit before submitting. |

`MarketPool` also exposes borrow-side fields (`borrowApy`, `baseBorrowApy`, `borrowApyOnMidKink`, `borrowApyOnHighKink`, `maxBorrowApy`, `borrowFee`, `borrowWeight`, etc.). These describe Scallop's borrow market and are unrelated to cdpm's supply-only integration; do not pull them into supply-decision code paths — they will only confuse the picker.

> **Note on units.** `supplyAmount` / `borrowAmount` / `reserveAmount` are raw `u64`; `supplyCoin` / `borrowCoin` / `reserveCoin` apply `BigNumber.shiftedBy(-coinDecimal)` (verified in `sui-scallop-sdk/src/utils/query.ts:118-163`).

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

- **Fee cancels.** cdpm's yield-fee is taken on redeem from the interest portion regardless of venue (`scallop_redeem` and `kai_redeem` share `fee_house.fee_rate`). When comparing two `supplyApy` numbers under the same fee, the `(1 − r)` factor is symmetric and drops out — compare raw APY directly.
- **`Promise.all`.** Both reads are independent gRPC calls; doing them in parallel halves the picker's wall-clock latency, which matters for rebalance bots that re-pick every block.
- **Utilization tripwire.** If `scallopPool.utilizationRate > 0.9` (or whatever your chain-condition threshold is), `cash` is thin and a same-block redeem may not have liquidity. Either downgrade Scallop's effective rank (subtract a liquidity-risk premium from `scallopApy`), or just skip Scallop for now. Kai has no equivalent metric — its `total_available_balance` already nets out the strategy locks.
- **No Kai vault available.** When `kaiVaultKey` is `null`, the picker degenerates to "Scallop or idle" cleanly. The reverse — a Kai vault exists but no Scallop market — is rare for major underlyings; if it happens, drop Scallop from the call and use `getVaultStats` alone.
- **APR vs APY.** Both SDKs report compounded `apy` and simple `apr`. cdpm itself doesn't compound (interest realizes only on redeem), so comparing `apy` is closest to "what the PM actually earns over the idle window". If you compare `apr`, do it consistently across both venues.

Heuristic numbers to keep in mind: at 5% APY, a 100 MIST gas round-trip pays for itself within ~12 hours on any idle balance ≥ 22 MIST × coin-decimal multiplier. For typical mainnet USDC parking (6 decimals, 100k+ MIST balances), the picker should almost always return a non-`idle` venue — the only reason to gate is when both venues are paying near zero (Scallop with very low utilization + Kai near `finalUnlockTsSec`).

### 10.5 Using the SDK Strictly for Address Resolution

Even when you build cdpm PTBs manually, the SDK is the cleanest source of Scallop package / object ids. The API lives on `scallop.client.address`:

```typescript
// Singleton getter — string-or-undefined, validated against AddressStringPath.
const SCALLOP_PROTOCOL   = scallop.client.address.get('core.packages.protocol.id');
const SCALLOP_VERSION_ID = scallop.client.address.get('core.version');
const SCALLOP_MARKET_ID  = scallop.client.address.get('core.market');

// Or grab the whole bundle once and pluck what you need.
const bundle = scallop.client.address.getAddresses();
```

The path keys are typed via `AddressStringPath` (`sui-scallop-sdk/src/types/address.ts:175-178`); typos return `undefined` at runtime rather than throwing, so wrap reads in an assertion if a missing key would silently break your PTB.

Reading these once at boot and reusing them across all cdpm Scallop PTBs survives Scallop upgrades that bump the package id but keep the move-call shapes intact.

### 10.6 Error / Staleness Notes

- The SDK caches address-bundle reads. To force-refresh, call `await scallop.client.address.read(addressId)` (it re-fetches `https://sui.apis.scallop.io/addresses/{addressId}` and repopulates the bundle).
- `queryMarket` / `getMarketPool` already trigger an off-chain recompute that mimics `accrue_interest_for_market`, so the returned `supplyApy` is fresh as of the SDK call. The on-chain `balance_sheet` is only fresh after the move-call's own internal accrual; treat the SDK number as decision-grade.
- If you compare `pool.conversionRate × supply` against your `predictRedeem.expectedUnderlying`, expect tiny discrepancies — the SDK uses floats internally; cdpm and the on-chain reserve do u128 ceil/floor. Treat the SDK numbers as decision-grade, not settlement-grade.
- For pure read-only consumers (e.g. a dashboard that only displays APY), fetching `https://sui.apis.scallop.io/addresses/{addressId}` directly avoids pulling in the full SDK; pair it with a hand-rolled `getMarketPool` over the resolved object ids if dependency size matters.
