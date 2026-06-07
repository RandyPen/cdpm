# Kai SAV Lending Math

## Contents

- [1. Vault Snapshot](#1-vault-snapshot)
- [2. `predictKaiDeposit` (off-chain twin of `kai_vault::deposit`)](#2-predictkaideposit-off-chain-twin-of-kai_vaultdeposit)
- [3. `predictKaiWithdraw` (off-chain twin of `kai_vault::withdraw`)](#3-predictkaiwithdraw-off-chain-twin-of-kai_vaultwithdraw)
- [4. Principal Amortization (`pull_from_kai_lending`)](#4-principal-amortization-pull_from_kai_lending)
- [5. Yield Fee Inside `kai_redeem`](#5-yield-fee-inside-kai_redeem)
- [6. End-to-End Prediction Helper](#6-end-to-end-prediction-helper)
- [7. Inverse Direction — Sizing Redemptions](#7-inverse-direction-sizing-redemptions)
- [8. Reading Vault State Off-Chain](#8-reading-vault-state-off-chain)
- [9. Safety Margins](#9-safety-margins)
- [10. Reading Live Vault APY Off-Chain (Supply-Side Half of the Picker)](#10-reading-live-vault-apy-off-chain-supply-side-half-of-the-picker)
- [11. Cross-Reference](#11-cross-reference)

## 1. Vault Snapshot

The off-chain twins of `kai_vault::deposit` / `kai_vault::withdraw` read two `u64` values from `kai_sav::vault::Vault<T, YT>` for sizing:

| Symbol | Source | Meaning |
|--------|--------|---------|
| `total_available` | `kai_vault::total_available_balance(vault, clock)` | Underlying value redeemable right now (free balance + strategy NAV + unlocked time-locked profit) |
| `yt_supply`       | `kai_vault::total_yt_supply(vault)`                | Outstanding YT supply (`Vault<T, YT>` minted but not burned) |

Per-YT redemption value: `p = total_available / yt_supply`.

> **Self-accruing snapshot.** Kai's `total_available_balance(clock)` folds in time-locked profit via `tlb::max_withdrawable`. Reading the vault at clock `t` predicts exactly what `vault::deposit` / `vault::withdraw` will see at the same clock; no separate accrual command is needed.

cdpm also tracks per-PM Kai vault state inside `pm.lending` under bag key `type_name<YT>`:

| Symbol           | Source                                 | Meaning |
|------------------|----------------------------------------|---------|
| `yt_in_pm`       | `balance::value(&KaiVault.yt_balance)` | YT held by this PM, not the global supply |
| `principal_in_pm`| `KaiVault.principal`                   | Sum of underlying deposited by this PM |

`principal_in_pm <= yt_in_pm × p` is **not** an invariant — when the vault has earned yield, the PM's principal is strictly below its YT-implied value, and the difference is the interest that the yield fee taxes on redeem.

---

## 2. `predictKaiDeposit` (off-chain twin of `kai_vault::deposit`)

```
expected_yt =
  total_available == 0 ? t_amount
                       : floor(yt_supply × t_amount / total_available)
```

TypeScript twin:

```typescript
function predictKaiDeposit(
  totalAvailable: bigint,
  ytSupply: bigint,
  tAmount: bigint,
): bigint {
  if (totalAvailable === 0n) {
    return tAmount; // bootstrap: 1:1 YT per underlying
  }
  return (ytSupply * tAmount) / totalAvailable; // floor division
}
```

Edge cases:

- **Bootstrap** (`total_available == 0`): Kai's `vault::deposit` returns `t_amount` YT directly (1:1).
- **Degenerate** (`total_available > 0` and `yt_supply == 0`): the production Kai vault auto-mints performance fees on every accrual, so `yt_supply == 0` only at `total_available == 0`. If this state still appears, treat the prediction as `0` and increase the deposit input rather than rely on the bootstrap branch.
- When `t_amount × yt_supply < total_available`, the floor returns `0`. `kai_supply` still runs and joins a zero `Balance<YT>` into `pm.lending`. Off-chain sizing should increase the input.

---

## 3. `predictKaiWithdraw` (off-chain twin of `kai_vault::withdraw`)

```
expected_underlying = floor(yt_amount × total_available / yt_supply)
```

This is the inverse of `predictKaiDeposit`.

```typescript
function predictKaiWithdraw(
  totalAvailable: bigint,
  ytSupply: bigint,
  ytAmount: bigint,
): bigint {
  if (ytSupply === 0n) {
    throw new Error('Kai vault YT supply is zero');
  }
  return (ytAmount * totalAvailable) / ytSupply; // floor division
}
```

> **Asymmetry note.** Kai's `vault::withdraw` uses `muldiv_round_up` internally to compute the underlying owed to the redeemer, biasing in favor of remaining YT holders. The off-chain predictor floors. The live `vault::withdraw` therefore returns `>= expected_underlying`, so treating `predictKaiWithdraw` as a lower bound is safe.

When the result is `0`, the redeem call still runs and credits `0` underlying to `pm.balance[T]` (less the yield fee, which is also `0` since there is no interest).

---

## 4. Principal Amortization (`pull_from_kai_lending`)

When the caller wants to redeem `want_amount` YT out of a PM-Kai-vault that holds `yt_in_pm` YT and `principal_in_pm` principal, cdpm splits the principal proportionally:

```
if want_amount >= yt_in_pm:
    pulled_yt          = yt_in_pm
    principal_portion  = principal_in_pm
    (KaiVault entry is removed from pm.lending)
else:
    principal_portion  = floor(principal_in_pm × want_amount / yt_in_pm)
    pulled_yt          = want_amount
    KaiVault.principal -= principal_portion
    KaiVault.yt_balance -= want_amount
```

TypeScript twin:

```typescript
function kaiPrincipalPortion(
  pInPm: bigint,    // current KaiVault.principal
  ytInPm: bigint,   // current balance::value(&KaiVault.yt_balance)
  wantAmount: bigint,
): bigint {
  if (wantAmount >= ytInPm) return pInPm;  // full drain
  return (pInPm * wantAmount) / ytInPm;    // floor
}
```

Properties:

- Floor-division can leave 1 unit of principal "stuck" in the PM-vault entry after a partial redeem; benign — swept on a later full drain.
- `principal_portion <= principal_in_pm` always.
- Monotonically non-decreasing in `wantAmount`.

This formula is structurally identical to Scallop's `pull_from_scallop_lending`; the only difference is the bag key and the type of the inner balance (`Balance<YT>` vs `Balance<MarketCoin<T>>`).

---

## 5. Yield Fee Inside `kai_redeem`

```
redeemed_amount   = balance::value(&underlying)            // result of redeem_withdraw_ticket
interest          = max(0, redeemed_amount − principal_portion)
fee_amount        = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance     = redeemed_amount − fee_amount
```

`fee_house.fee_rate` is in basis points (`FEE_DENOMINATOR = 10_000`), capped at `MAX_FEE_RATE = 5000` (50%) by `admin_set_fee`. Default is `2000` (20%). The same `fee_house` is shared with Scallop redeems — there is **no** separate Kai fee rate.

```typescript
const FEE_DENOMINATOR = 10_000n;
const MAX_FEE_RATE = 5_000n;

function applyKaiYieldFee(
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

Wrap the four formulas to predict the post-redeem `pm.balance[T]` delta given a snapshot.

```typescript
interface KaiVaultSnapshot {
  totalAvailable: bigint;  // total_available_balance(vault, clock)
  ytSupply: bigint;        // total_yt_supply(vault)
}

interface KaiPmVaultSnapshot {
  ytInPm: bigint;          // balance::value(&KaiVault.yt_balance)
  principalInPm: bigint;   // KaiVault.principal
}

function predictKaiRedeem(
  vault: KaiVaultSnapshot,
  pm: KaiPmVaultSnapshot,
  wantYt: bigint,
  feeRateBp: bigint,
): {
  expectedUnderlying: bigint;
  principalPortion: bigint;
  interest: bigint;
  feeAmount: bigint;
  toBalance: bigint;
} {
  const expectedUnderlying = predictKaiWithdraw(
    vault.totalAvailable, vault.ytSupply, wantYt,
  );
  const pp = kaiPrincipalPortion(pm.principalInPm, pm.ytInPm, wantYt);
  const yieldFee = applyKaiYieldFee(expectedUnderlying, pp, feeRateBp);
  return {
    expectedUnderlying,
    principalPortion: pp,
    interest: yieldFee.interest,
    feeAmount: yieldFee.feeAmount,
    toBalance: yieldFee.toBalance,
  };
}
```

The live Kai redeem may pay slightly more than `expectedUnderlying` (Kai's `vault::withdraw` uses `muldiv_round_up`, the off-chain twin floors). Use `expectedUnderlying` as the conservative lower bound for strategy logic. The same applies to `toBalance`: it is a lower bound on what actually lands in `pm.balance[T]` after `kai_redeem`.

### 6.1 Forward direction — "I burn N YT, what do I net?"

Already covered by `predictKaiRedeem(vault, pm, N, feeRateBp).toBalance`. This answers *"what underlying lands in `pm.balance[T]`?"*. See section 3 for the raw `predictKaiWithdraw` formula and section 5 for the yield-fee deduction.

---

## 7. Inverse Direction — Sizing Redemptions

The forward formulas in sections 2-6 answer "given an `N` YT to burn, what comes back?". The inverse — "I need at least `K` underlying, what `N` do I feed `kai_redeem`?" — is what bots and rebalancing strategies actually need.

### 7.1 Inverse: YT to burn for target underlying (pre-fee)

`predictKaiWithdraw` is `floor(N × total / yt_supply)`. To guarantee the predicted output is `>= K`, invert with **ceiling** division:

```
yt_to_burn = ceil(K × yt_supply / total_available)
           = (K × yt_supply + total_available − 1) / total_available
```

Use ceiling because the off-chain predictor floors. (Kai's live `muldiv_round_up` adds further headroom in your favor, but the floor is what the predictor produces, so ceiling on the inverse is the right protection.)

If the resulting `yt_to_burn` exceeds `pm.ytInPm`, the user wants more underlying than the PM-vault contains. Either lower the target or pass `MAX_U64` to drain the whole entry and accept whatever the redeem pays out.

```typescript
const MAX_U64 = (1n << 64n) - 1n;

function ceilDiv(a: bigint, b: bigint): bigint {
  if (b <= 0n) throw new Error('ceilDiv: divisor must be positive');
  return (a + b - 1n) / b;
}

/**
 * Inverse of `predictKaiWithdraw`. Returns the smallest `N` such that
 * `floor(N × total / yt_supply) >= desiredUnderlying`.
 *
 * Returns `MAX_U64` when the PM-vault entry cannot satisfy the target — caller
 * should either drain (pass `MAX_U64` as `yt_amount`) or downsize the request.
 */
function ytToBurnForTargetUnderlying(
  vault: KaiVaultSnapshot,
  desiredUnderlying: bigint,
  ytInPm: bigint,
): bigint {
  if (desiredUnderlying <= 0n) return 0n;
  if (vault.ytSupply === 0n) throw new Error('Kai vault YT supply is zero');
  if (vault.totalAvailable === 0n) return MAX_U64;

  const n = ceilDiv(desiredUnderlying * vault.ytSupply, vault.totalAvailable);
  return n > ytInPm ? MAX_U64 : n;
}
```

The `MAX_U64` sentinel: callers can pass that straight into `kai_redeem`'s `yt_amount`; `pull_from_kai_lending` clamps to the PM-vault entry's `yt_in_pm` and removes the bag entry, returning whatever the live `vault::withdraw` pays out after the strategy walk.

### 7.2 Inverse: YT to burn for target **net** underlying (after yield-fee)

This is the practically useful inverse for an agent / bot driving redeems. Solve for `N` (YT to burn) such that the post-fee underlying credited to `pm.balance[T]` is `>= K`:

```
Let r = fee_rate / 10000           (e.g. 0.20 for 2000 bp)
Let π = principal_in_pm / yt_in_pm (per-YT principal share inside this PM)
Let p = total_available / yt_supply (per-YT underlying value, "ε")

Per-YT redemption (real-arithmetic, ignoring floors):
  underlying_per_yt        = p
  principal_portion_per_yt ≈ π
  interest_per_yt          = max(0, p − π)
  fee_per_yt               = r × interest_per_yt
  net_per_yt               = p − fee_per_yt
                           = p − r × max(0, p − π)
                           = p × (1 − r) + r × π     when p >  π   (typical, ε > 1)
                           = p                       when p <= π  (no interest, no fee)

So:
  N ≈ ceil(K / net_per_yt)
    = ceil(K × 10000 × yt_supply × yt_in_pm
           / ((10000 − r_bp) × total_available × yt_in_pm + r_bp × yt_supply × principal_in_pm))   when p > π
    = ceil(K × yt_supply / total_available)                                                        when p <= π
```

The closed form is an *approximation* because each on-chain step floors independently:

1. `principal_portion = floor(principal_in_pm × N / yt_in_pm)` discards up to `1` unit of principal.
2. `expected_underlying = floor(N × total / yt_supply)` discards up to `1` unit of underlying (twin side; Kai's live `muldiv_round_up` adds 1 unit of headroom on top).
3. `fee_amount = floor(interest × r_bp / 10000)` discards up to `1` unit of fee.

Each floor pushes `net` slightly *higher* than the closed-form predicts (less fee paid, less interest counted), which is safe — the closed form is a conservative *lower bound* on `net`, so the resulting `N` is occasionally 1 unit larger than the true minimum. That is acceptable; it never under-funds. Use the iterative refinement helper below if you want the exact minimum `N`.

```typescript
const FEE_DENOMINATOR = 10_000n;

/**
 * Closed-form approximation: smallest `N` such that the post-fee net
 * underlying credited to `pm.balance[T]` is `>= desiredNet`.
 *
 * Returns 0 when `desiredNet <= 0`. Returns `MAX_U64` when the PM-vault entry
 * cannot satisfy the request — caller should drain.
 */
function ytToBurnForTargetNetClosedForm(
  vault: KaiVaultSnapshot,
  pm: KaiPmVaultSnapshot,
  desiredNet: bigint,
  feeRateBp: bigint,
): bigint {
  if (desiredNet <= 0n) return 0n;
  if (vault.ytSupply === 0n) throw new Error('Kai vault YT supply is zero');
  if (pm.ytInPm === 0n) return MAX_U64;
  if (vault.totalAvailable === 0n) return MAX_U64;

  // p = total / yt_supply, π = principal_in_pm / yt_in_pm.
  // p > π  ⇔  total × yt_in_pm > yt_supply × principal_in_pm
  const pTimesYtInPm = vault.totalAvailable * pm.ytInPm;
  const piTimesYtInPm = vault.ytSupply * pm.principalInPm;
  const interestExists = pTimesYtInPm > piTimesYtInPm;

  let n: bigint;
  if (!interestExists) {
    // No interest, no fee — pure ceil(K × yt_supply / total).
    n = ceilDiv(desiredNet * vault.ytSupply, vault.totalAvailable);
  } else {
    // net_per_yt = ((10000 − r) × total × yt_in_pm + r × yt_supply × principal_in_pm)
    //              / (10000 × yt_supply × yt_in_pm)
    // N = ceil(desiredNet / net_per_yt)
    const r = feeRateBp;
    const numer =
      desiredNet * FEE_DENOMINATOR * vault.ytSupply * pm.ytInPm;
    const denomTerm =
      (FEE_DENOMINATOR - r) * vault.totalAvailable * pm.ytInPm +
      r * vault.ytSupply * pm.principalInPm;
    if (denomTerm === 0n) return MAX_U64;
    n = ceilDiv(numer, denomTerm);
  }

  return n > pm.ytInPm ? MAX_U64 : n;
}

/**
 * Iterative refinement: starts from the closed-form approximation and bumps
 * `N` upward by 1 YT at a time until forward simulation
 * (`predictKaiRedeem.toBalance`) confirms `>= desiredNet`. Caps at a small
 * iteration budget — in practice the closed form is exact or off-by-one.
 *
 * Returns either the minimum `N` that satisfies the target or `MAX_U64` when
 * the PM-vault entry cannot.
 */
function ytToBurnForTargetNet(
  vault: KaiVaultSnapshot,
  pm: KaiPmVaultSnapshot,
  desiredNet: bigint,
  feeRateBp: bigint,
  maxIterations: bigint = 8n,
): bigint {
  let n = ytToBurnForTargetNetClosedForm(vault, pm, desiredNet, feeRateBp);
  if (n === MAX_U64) return MAX_U64;

  for (let i = 0n; i < maxIterations; i++) {
    if (n > pm.ytInPm) return MAX_U64;
    if (n === 0n) { n = 1n; continue; }
    const sim = predictKaiRedeem(vault, pm, n, feeRateBp);
    if (sim.toBalance >= desiredNet) return n;
    n += 1n;
  }
  return n > pm.ytInPm ? MAX_U64 : n;
}
```

**Caveats:**

- The closed-form denominator `((10000 − r) × total × yt_in_pm + r × yt_supply × principal_in_pm)` can be very large under realistic mainnet values; `bigint` handles it without overflow but be aware that intermediate products are `O(u64⁴)`.
- The split between "interest exists" and "no interest" is a strict `>` on the cross-multiplied comparison. Equality (`p == π`) is degenerate — typically only at vault initialization before any yield has accrued, where there is also no interest to fee.
- **Strategy losses.** If a strategy emits `StrategyLossEvent` between snapshot and signing, `total_available_balance` shrinks and `p` drops. The closed form may then over-predict net; the iterative helper bumps `N` upward to compensate. If `total_available` drops far enough that `p <= π`, the closed form switches branches automatically (no fee).
- **Bootstrap branch.** When `total_available == 0`, `predictKaiDeposit` returns `t_amount` directly (1:1). The redeem inverse cannot be in this state — `predictKaiWithdraw` requires `yt_supply > 0`, and if `yt_supply > 0` and `total_available == 0` then per-YT value is `0` and any redeem nets `0` underlying. This helper returns `MAX_U64` in that branch, signaling "drain; expect zero net".
- **Admin guardrails.** Kai's `set_withdrawals_disabled` / `tvl_cap` / rate limiter are enforced inside `vault::withdraw`. The off-chain predictor does not see those flags; if they trigger, the inner `vault::withdraw` aborts and the whole `kai_redeem` PTB reverts. The PM is safe; the protocol bot retries when the limiter clears.

### 7.3 Worked Example

Vault state: `total_available = 1100`, `yt_supply = 1050`. PM-Kai-vault: `yt_in_pm = 1000` YT, `principal_in_pm = 950` underlying. Fee rate = `2000` bp = 20%.

Implied per-YT values: `p = 1100/1050 ≈ 1.0476`, `π = 950/1000 = 0.95`. Since `p > π`, interest exists.

**Goal:** redeem so that `>= 100` underlying lands in `pm.balance[T]` net of fee.

1. `net_per_yt = 1.0476 × 0.8 + 0.2 × 0.95 = 0.8381 + 0.19 = 1.0281`
2. Closed-form `N ≈ ceil(100 / 1.0281) = 98` YT.
3. Forward simulation with `N = 98`:
   - `principal_portion = floor(950 × 98 / 1000) = floor(93.1) = 93`
   - `expected_underlying = floor(98 × 1100 / 1050) = floor(102.67) = 102` (Kai's live `muldiv_round_up` would give `103`, but the off-chain twin floors)
   - `interest = 102 − 93 = 9`
   - `fee = floor(9 × 2000 / 10000) = floor(1.8) = 1`
   - `net = 102 − 1 = 101`  →  `101 >= 100`  

The forward sim confirms the closed form. The bot feeds `kai_redeem` with `yt_amount = 98`, the bot pays `1` underlying yield fee, and `pm.balance[T]` increases by `101` (or `102` if Kai's `muldiv_round_up` gives an extra unit).

If `desiredNet` had been `103`, the closed-form would have returned `N = 101`, and forward sim would have yielded `net = 103` — the iterative refinement helper would not have needed to bump.

---

## 8. Reading Vault State Off-Chain

The simplest approach is a dry-run of the same view path the off-chain twins use:

```
1. kai_sav::vault::total_available_balance(vault, clock)  → u64
2. kai_sav::vault::total_yt_supply(vault)                  → u64
```

Both are public view functions on `Vault<T, YT>`. A `dev_inspect` against the same vault and clock object that your live PTB will use produces snapshots that match the on-chain values `kai_supply` / `kai_redeem` consume.

For sizing, also read the per-PM Kai vault entry by querying `pm.lending` (a `Bag`) under bag key `type_name<YT>`:

- `KaiVault.yt_balance.value` → `yt_in_pm`
- `KaiVault.principal` → `principal_in_pm`

---

## 9. Safety Margins

When sizing inputs:

- For `kai_supply<T, YT>`: `t_amount × yt_supply >= total_available` to keep the predicted `expected_yt > 0`. In practice deposit at least a few hundred MIST equivalents.
- For `kai_redeem<T, ST, YT>`: `yt_amount × total_available >= yt_supply` for the same reason. The inverse helpers in section 7 already enforce ceiling rounding, so they cannot produce `N = 0` for any positive target.
- Re-snapshot the vault and PM-vault entry immediately before signing. Kai's `total_available_balance` ticks every block as time-locked profit unlocks; a stale snapshot can leave the realized redeem a few raw below the predicted `toBalance`.
- For batched protocol bots: snapshot once per batch, not once per PM. As long as the batch fits in one block, all redeems see the same `total_available_balance`. Across blocks, re-snapshot.
- **Strategy walks add a soft latency budget.** `kai_redeem` composes `vault::withdraw → klsp::withdraw → vault::redeem_withdraw_ticket` inside a single move-call; the inner chain is generic over the kai_leverage_supply_pool strategy `<T, ST, YT>` that every production Kai vault uses. Large vaults still pay gas proportional to the strategy chain's settlement work — factor it into your gas budget.

### 9.1 Floor-div dust on the redeem path

`kai_redeem` runs the full redemption as a single move-call: it pulls YT from `pm.lending`, drives the Kai withdrawal chain, deducts the yield fee from `interest`, and credits the residual to `pm.balance[T]`. The redeemed amount is whatever the chain actually returns; there is no off-chain prediction enforced at the cdpm boundary. A floor-div mismatch between off-chain twin and live chain can therefore only leave the realized `pm.balance[T]` increment 1-2 raw below the predicted `toBalance` — it cannot abort the transaction.

The dust budget:

- `vault::withdraw` computes the same `muldiv` target as the predictor, then the final priority loop reclaims the proportional-split residual — vault-level allocation is exact.
- The shortfall lives in `redeem_withdraw_ticket`: each strategy's `withdrawn_balance` ≤ its `to_withdraw` because `kai_leverage_supply_pool::withdraw` floors twice per strategy (`muldiv(shares, to_withdraw, nominal)` then `redeem_lossy`). Overshoots are skimmed to profit and capped at `to_withdraw`, so the result is always ≤ requested.

⟹ **dust ≈ 2 raw × (strategies actually drawn from)**. Free-balance-served redeems contribute ~0. Single-strategy mainnet SAVs ⟹ ≤2 raw. Constant in principal, not proportional. Withdraw-then-redeposit does not accumulate it.

This matters most when composing the redeem with a downstream `add_liquidity` in the same PTB. Two patterns:

1. **Treat `predictKaiWithdraw` as a strict upper bound.** Size the downstream `add_liquidity` against `floor(predicted) − safety_margin` (a few raw is plenty) rather than `predicted` itself. cdpm's worker uses `REDEEM_REALIZED_SAFETY_MARGIN_RAW = 3` (env-tunable); the unrealized few raw stay in the bag and deploy next cycle.
2. **Cap the burn on partial drains.** Pass `yt_amount = min(needed, ytInPm − LENDING_SAFE_MARGIN_WRAPPER_RAW)` (recommended default 100 YT raw). This leaves a residual entry in `pm.lending` so the bag key survives — useful when a later top-up will re-credit principal into the same entry.

```typescript
const LENDING_SAFE_MARGIN_WRAPPER_RAW = 100n;

function capRedeemBurnRaw(exact: bigint, wrapperRaw: bigint): bigint | null {
  if (wrapperRaw <= LENDING_SAFE_MARGIN_WRAPPER_RAW) return null;
  const safeMax = wrapperRaw - LENDING_SAFE_MARGIN_WRAPPER_RAW;
  return exact >= safeMax ? safeMax : exact;
}
```

**Deploy-side realized floor (redeem → add-liquidity in the same PTB).** Size the deploy to a guaranteed LOWER bound of the conversion, not to the requested `want`:

```
wrapperSplit = totalWrapper × share          // share = want / heldUnderlying ; the YT to burn
realized     = floor(amountRaw × r) − M      // M = small floor margin, e.g. 3 raw
deployTotal ≤ available + realized           // clamp the add to this, NOT available + want
```

Clamping the deploy to `realized = floor(amountRaw × r) − M` (a strict lower bound) prevents the downstream `0x2::balance::split` ENotEnough abort at `add_liquidity`.

Cross-references:

- `cdpm-protocol-sdk/reference/kai-lending.md` — protocol PTB template
- `cdpm-agent-sdk/reference/kai-lending.md` — agent PTB template
- `cdpm-user-sdk/reference/kai-lending.md` — owner / close-PM PTB template
- `cdpm-calculation-skill/reference/cross-protocol-ptb.md` §3 — cross-protocol composition

---

## 10. Reading Live Vault APY Off-Chain (Supply-Side Half of the Picker)

The pair `(total_available, yt_supply)` from §1 encodes the *current* per-YT price; what it does **not** give you directly is the *rate* at which `total_available` is unlocking — i.e. the supply APY a sleeping `pm.balance[T]` would earn if you parked it via `kai_supply<T, YT>`. Kai's vault holds time-locked profit (`tlb::max_withdrawable`) and aggregates strategy NAV, so the live yield depends on how fast the time-locked balance unlocks. Kai publishes both the snapshot and the derived APY via [`@kunalabs-io/kai`](https://github.com/kunalabs-io/kai-ts-sdk).

This page covers the Kai-side rate-query API. The cross-protocol "Scallop or Kai?" picker that consumes both this and the Scallop-side query lives in [`scallop-lending-math.md` §10.4](./scallop-lending-math.md#104-decision-recipe--scallop-vs-kai-supply-picker) — Kai-only callers can use the snippet in §10.4 below.

### 10.1 SDK Setup

Install (alongside `@mysten/sui` — pin the same major across the dep tree, see `cross-protocol-ptb.md` for the `instanceof Transaction` pitfall):

```bash
bun add @kunalabs-io/kai @mysten/sui
# or: npm install / pnpm add / yarn add
```

```typescript
import { SuiClient } from '@mysten/sui/client';
import {
  VAULTS,
  getVaultStats,
  getAllVaultStats,
  getWalletVaultInfo,
} from '@kunalabs-io/kai';

const client = new SuiClient({ url: 'https://fullnode.mainnet.sui.io' });
```

`VAULTS` is a frozen map of every Kai-deployed vault — instances expose the underlying / YT type metadata (`T`, `YT`), the on-chain object id, and the deposit / withdraw / fetch / `getStrategies` methods that compose into PTBs (see §10.5 below).

Two practical caveats:

1. **Mainnet only.** Every vault id in `VAULTS` is hard-coded to mainnet objects (`kai-ts-sdk/src/vault/vault.ts:441-533`). There is no testnet / devnet map. cdpm + Kai integration testing has to run against mainnet, fork a mainnet snapshot locally, or stub the Kai layer.
2. **`paused_*` keys exist.** The map includes `paused_suiUSDT` and `paused_USDC` alongside the active `suiUSDT` and `USDC`. These are deprecated vaults retained for redeem-only flows; **do not pick `paused_*` as a supply destination** in the picker — `kai_supply` will succeed but the vault no longer accrues. Filter them out at the call site:

   ```typescript
   const activeKaiKeys = Object.keys(VAULTS).filter(k => !k.startsWith('paused_'));
   ```

### 10.2 Rate-Query Methods

```typescript
// Single vault.
const data  = await VAULTS.suiUSDT.fetch(client);    // on-chain Vault<T, YT>
const stats = getVaultStats(data);                   // { tvl, apr, apy }

// Every vault in one round-trip.
const all = await getAllVaultStats(client);
//   → Array<{ vaultInfo, tvl, apr, apy }>
```

`getVaultStats` is **synchronous** once you have `vaultData` — the SDK already pulled the on-chain state via `fetch`. `getAllVaultStats` batches the fetch + compute across every entry in `VAULTS`.

### 10.3 Return Shape & APR Derivation

```typescript
interface VaultStats {
  tvl: Amount;   // total_available_balance, decimal-aware wrapper around bigint
  apr: number;   // annual unlock rate / TVL, post-performance-fee
  apy: number;   // continuously-compounded equivalent of apr
}
```

The APR is derived from the time-locked balance unlock schedule, not from a cached number on-chain. The performance fee is applied to `unlockPerSecond` *before* annualization (`muldiv(unlockPerSecond, 10000 - performanceFeeBps, 10000)`), so the reported `apr` is already the **net** rate the depositor sees:

```
unlockPerSecondNet = unlockPerSecond × (10000 − performanceFeeBps) / 10000
apr                = unlockPerSecondNet × 60 × 60 × 24 × 365 / tvl
apy                = Math.exp(apr) − 1                       // 1-year continuous compounding
```

The SDK calls `calcContinuousApy(apr, 365)` (`kai-ts-sdk/src/vault/util.ts:103`) which internally computes `time = days / 365` and then `Math.exp(apr × time) − 1`. Because `days` is hardcoded to `365`, `time = 1` and the formula collapses to `Math.exp(apr) − 1`.

Two important properties:

1. **Auto-zeroing past `finalUnlockTsSec`.** When the current Unix-second timestamp exceeds `finalUnlockTsSec`, the SDK treats `unlockPerSecond = 0` and reports `apr = 0` (`util.ts:77-79`). The time-locked balance has fully unlocked; no further yield is being released. cdpm-side bots should treat a sustained `apr = 0` as a signal to redeem the YT (no further upside) rather than hold.
2. **Bitcoin-denominated normalization.** For vaults whose underlying symbol is in `{'wBTC', 'LBTC', 'xBTC'}` the SDK averages `unlockPerSecond` over `min(unlockDurationSec, 30 × 60)` seconds before annualizing — sub-satoshi precision otherwise rounds the per-second rate to zero. The branch is gated on `vault.T.symbol`, so other coins (even high-decimal ones) follow the simple formula above.

### 10.4 Decision Recipe — Scallop vs Kai Supply Picker

The dominant cdpm use case for live rates is "where to park `pm.balance[T]` — Scallop or Kai?". Because both venues share `pm.lending` (under different bag keys) and the cdpm yield-fee is identical across both, the picker reduces to a raw `apy` comparison. The canonical picker — querying Scallop and Kai in parallel and returning `{ venue, apy, detail }` — lives in [`scallop-lending-math.md` §10.4](./scallop-lending-math.md#104-decision-recipe--scallop-vs-kai-supply-picker) so it sits alongside the Scallop-side `MarketPool` field reference. Wire `getVaultStats(VAULTS[kaiKey].fetch(client)).apy` in as the Kai input there rather than maintaining a parallel single-protocol "is Kai worth it?" helper here.

If you need a Kai-only quick check (e.g. when the Scallop market is paused and Scallop is not on the table), inline:

```typescript
const { apy } = getVaultStats(await VAULTS[kaiKey].fetch(client));
const supplyKai = apy >= minApy;
```

— there's no need for a separate function wrapping that call. The picker's `pickSupplyVenue` in §10.4 of the Scallop math doc handles the `kaiVaultKey: null` degenerate case symmetrically when Scallop is the sole option.

### 10.5 Wallet-Level vs Vault-Level Stats

`getWalletVaultInfo(client, walletAddress, vaultData)` returns the YT balance + equity for a given address. **It is not directly useful for a `pm.balance[T]` decision** — the YT lives inside `pm.lending[type_name<YT>]`, not in the owner / agent / protocol wallet. To compute per-PM stats, use the bag-key path described in §1 + §8, then multiply `yt_in_pm × p` (where `p = total_available / yt_supply` from `getVaultStats`).

Wallet-level YT (`getWalletVaultInfo`) is only relevant for addresses that hold YT independently of cdpm — e.g. a user who supplied to Kai directly outside any PositionManager. cdpm itself exposes no wrapper-extract function, so no cdpm flow lands raw `Coin<YT>` in the owner / agent / protocol wallet.

### 10.6 Error / Staleness Notes

- `vault.fetch` and `getVaultStats` are pure reads — no on-chain accrual command needed. Kai's `total_available_balance(clock)` self-accrues via `tlb::max_withdrawable` (cf. §1).
- The SDK reads `clock` via the `SuiClient` automatically. If you batch many `fetch` calls inside a tight loop, the clock used for APR derivation is the per-call timestamp; APR can drift micro-seconds across the batch. For cross-vault picking this is irrelevant; for tight A/B comparison, snapshot once and pass the same `clock` ms across helpers.
- Strategy losses (`StrategyLossEvent`) shrink `total_available` between snapshot and signing. Treat a sudden APR drop on a vault as a hint that one of its strategies just took a loss; rely on `predictKaiWithdraw` as a lower bound rather than an exact predictor in volatile windows.
- **No hosted REST endpoint.** Unlike Scallop (`https://sui.apis.scallop.io/...`), Kai does not publish a hosted APY API; the SDK is the only documented surface. Read-only consumers either depend on `@kunalabs-io/kai` or call the on-chain `total_available_balance` / `total_yt_supply` view functions directly via `dev_inspect`.
- **Reusable off-chain twins.** The SDK exposes `calcTotalAvailableBalance`, `calcYtToTAmount`, `calcTToYtAmount`, `calcYtConversionRate` (`kai-ts-sdk/src/vault/util.ts:42-55,147-212`) — pure functions that mirror the Kai math in §2 and §3 (using `muldiv` floor matching the off-chain twins). Prefer these to a hand-rolled twin: when Kai changes the per-vault math, the SDK absorbs the change and your sizing helpers stay correct.
- **Batched fetch.** `getVaultDataBatch(client, vaultIds)` (`util.ts:255-284`) issues one `multiGetObjects` call for many vaults — useful when the picker needs Kai snapshots across multiple `T` simultaneously.

---

## 11. Cross-Reference

- Owner PTB recipes: [`cdpm-user-sdk/reference/kai-lending.md`](../../cdpm-user-sdk/reference/kai-lending.md)
- Agent PTB recipes: [`cdpm-agent-sdk/reference/kai-lending.md`](../../cdpm-agent-sdk/reference/kai-lending.md)
- Protocol PTB recipes: [`cdpm-protocol-sdk/reference/kai-lending.md`](../../cdpm-protocol-sdk/reference/kai-lending.md)
- Scallop counterpart math: [`scallop-lending-math.md`](./scallop-lending-math.md)
