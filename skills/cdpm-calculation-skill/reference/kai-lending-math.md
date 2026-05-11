# Kai SAV Lending Math

This page documents the off-chain twins of every numeric formula the cdpm contract uses for Kai SAV supply / redeem (`kai_start_supply`, `kai_finish_supply`, `kai_start_redeem`, `kai_finish_redeem`). Use them to predict outputs **before** broadcasting, to validate dry-run results, and to size deposits so that `EZeroExpected (1007)` and `EAmountShortfall (1009)` never trip in production.

All formulas mirror `sources/cdpm.move` exactly. The contract widens to `u128` before arithmetic and narrows back to `u64`, so every off-chain implementation should do the same.

---

## 1. Vault Snapshot

cdpm reads two `u64` values from `kai_sav::vault::Vault<T, YT>` for sizing:

| Symbol | Source | Meaning |
|--------|--------|---------|
| `total_available` | `kai_vault::total_available_balance(vault, clock)` | Underlying value redeemable right now (free balance + strategy NAV + unlocked time-locked profit) |
| `yt_supply`       | `kai_vault::total_yt_supply(vault)`                | Outstanding YT supply (`Vault<T, YT>` minted but not burned) |

Per-YT redemption value: `p = total_available / yt_supply`.

> **No pre-flight accrual command.** Unlike Scallop, Kai's `total_available_balance(clock)` already folds in time-locked profit via `tlb::max_withdrawable`. Reading the vault at clock `t` predicts exactly what `vault::deposit` / `vault::withdraw` will see at the same clock, with no separate accrual step. (cdpm does **not** wrap a `vault::accrue` call — Kai's vault accrues lazily inside `total_available_balance`.)

cdpm also tracks per-PM Kai vault state inside `pm.lending` under bag key `type_name<YT>`:

| Symbol           | Source                                 | Meaning |
|------------------|----------------------------------------|---------|
| `yt_in_pm`       | `balance::value(&KaiVault.yt_balance)` | YT held by this PM, not the global supply |
| `principal_in_pm`| `KaiVault.principal`                   | Sum of underlying deposited by this PM |

`principal_in_pm <= yt_in_pm × p` is **not** an invariant — when the vault has earned yield, the PM's principal is strictly below its YT-implied value, and the difference is the interest that the yield fee taxes on redeem.

---

## 2. `compute_expected_yt` (used by `kai_start_supply`)

```move
fun compute_expected_yt<T, YT>(
    vault: &kai_vault::Vault<T, YT>,
    clock: &Clock,
    t_amount: u64,
): u64 {
    let total = total_available_balance(vault, clock);
    let yt_supply = total_yt_supply(vault);
    if (total == 0) {
        // bootstrap: 1:1 YT per underlying (matches vault.move:606-608)
        t_amount
    } else {
        floor(yt_supply × t_amount / total)
    }
}
```

TypeScript twin:

```typescript
function computeExpectedYt(
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

- **Bootstrap** (`total == 0`): cdpm returns `t_amount` directly. Kai's `vault::deposit` does the same when `total_available_balance == 0`.
- **Degenerate** (`total > 0` and `yt_supply == 0`): cdpm returns `0`, and `kai_start_supply` aborts with `EZeroExpected (1007)`. This state should not occur on a healthy Kai vault — Kai's deposit auto-mints performance fees so `yt_supply == 0` only at `total == 0`. cdpm's conservative behavior protects against an unforeseen state mutation.
- `EZeroExpected (1007)` also fires when `t_amount × yt_supply < total_available` (very small deposit relative to vault size).

---

## 3. `compute_expected_underlying_kai` (used by `kai_start_redeem`)

```move
fun compute_expected_underlying_kai<T, YT>(
    vault: &kai_vault::Vault<T, YT>,
    clock: &Clock,
    yt_amount: u64,
): u64 {
    let total = total_available_balance(vault, clock);
    let yt_supply = total_yt_supply(vault);
    assert!(yt_supply > 0, EReserveEmpty);
    floor(yt_amount × total / yt_supply)
}
```

This is the inverse of `compute_expected_yt`.

```typescript
function computeExpectedUnderlyingKai(
  totalAvailable: bigint,
  ytSupply: bigint,
  ytAmount: bigint,
): bigint {
  if (ytSupply === 0n) throw new Error('EReserveEmpty (1006)');
  return (ytAmount * totalAvailable) / ytSupply; // floor division
}
```

> **Asymmetry note.** Kai's *real* `vault::withdraw` uses `muldiv_round_up` to compute the underlying owed to the redeemer, biasing in favor of remaining YT holders. cdpm's prediction floors. As long as the live `vault::withdraw` returns at least the floored value (which it does — `ceil >= floor`), `kai_finish_redeem` passes the `redeemed_amount >= expected_underlying` check.

`EZeroExpected (1007)` fires when the result is `0` (asserted-positive check inside `kai_start_redeem`).

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

This formula is structurally identical to Scallop's `pull_from_lending`; the only difference is the bag key and the type of the inner balance (`Balance<YT>` vs `Balance<MarketCoin<T>>`).

---

## 5. Yield Fee Inside `kai_finish_redeem`

```
redeemed_amount   = underlying.value()                  // input Coin<T>
interest          = max(0, redeemed_amount − principal_portion)
fee_amount        = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance     = redeemed_amount − fee_amount
```

`fee_house.fee_rate` is in basis points (`FEE_DENOMINATOR = 10_000`), capped at `MAX_FEE_RATE = 3000` (30%) by `admin_set_fee`. Default is `2000` (20%). The same `fee_house` is shared with Scallop redeems — there is **no** separate Kai fee rate.

```typescript
const FEE_DENOMINATOR = 10_000n;
const MAX_FEE_RATE = 3_000n;

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
- The same fee path runs for owner / agent / protocol callers — yield fee is universal.

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
  const expectedUnderlying = computeExpectedUnderlyingKai(
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

The live Kai redeem may pay slightly more than `expectedUnderlying` (Kai's `vault::withdraw` uses `muldiv_round_up`, cdpm floors). Use `expectedUnderlying` as the conservative lower bound for your strategy logic. The same applies to `toBalance`: it is a lower bound on what actually lands in `pm.balance[T]` after `kai_finish_redeem`.

### 6.1 Forward direction — "I burn N YT, what do I net?"

Already covered by `predictKaiRedeem(vault, pm, N, feeRateBp).toBalance`. This answers *"what underlying lands in `pm.balance[T]`?"*. See section 3 for the raw `compute_expected_underlying_kai` formula and section 5 for the yield-fee deduction.

---

## 7. Inverse Direction — Sizing Redemptions

The forward formulas in sections 2-6 answer "given an `N` YT to burn, what comes back?". The inverse — "I need at least `K` underlying, what `N` do I feed `kai_start_redeem`?" — is what bots and rebalancing strategies actually need.

### 7.1 Inverse: YT to burn for target underlying (pre-fee)

`compute_expected_underlying_kai` is `floor(N × total / yt_supply)`. To guarantee the on-chain output is `>= K`, invert with **ceiling** division:

```
yt_to_burn = ceil(K × yt_supply / total_available)
           = (K × yt_supply + total_available − 1) / total_available
```

Use ceiling because cdpm's prediction floors. (Kai's live `muldiv_round_up` adds further headroom in your favor, but cdpm's floor is what gates the `redeemed_amount >= expected_underlying` check, so ceiling on the inverse is the right protection.)

If the resulting `yt_to_burn` exceeds `pm.ytInPm`, the user wants more underlying than the PM-vault contains. Either lower the target or `MAX_U64`-redeem the whole entry and accept whatever drains.

```typescript
const MAX_U64 = (1n << 64n) - 1n;

function ceilDiv(a: bigint, b: bigint): bigint {
  if (b <= 0n) throw new Error('ceilDiv: divisor must be positive');
  return (a + b - 1n) / b;
}

/**
 * Inverse of `compute_expected_underlying_kai`. Returns the smallest `N` such that
 * `floor(N × total / yt_supply) >= desiredUnderlying`.
 *
 * Throws `EReserveEmpty (1006)` when `yt_supply == 0`.
 * Returns `MAX_U64` when the PM-vault entry cannot satisfy the target — caller
 * should either drain (`MAX_U64`-redeem) or downsize the request.
 */
function ytToBurnForTargetUnderlying(
  vault: KaiVaultSnapshot,
  desiredUnderlying: bigint,
  ytInPm: bigint,
): bigint {
  if (desiredUnderlying <= 0n) return 0n;
  if (vault.ytSupply === 0n) throw new Error('EReserveEmpty (1006)');
  if (vault.totalAvailable === 0n) return MAX_U64;

  const n = ceilDiv(desiredUnderlying * vault.ytSupply, vault.totalAvailable);
  return n > ytInPm ? MAX_U64 : n;
}
```

The `MAX_U64` sentinel: callers can pass that straight into `kai_start_redeem`'s `yt_amount`; `pull_from_kai_lending` clamps to the PM-vault entry's `yt_in_pm` and removes the bag entry, returning whatever the live `vault::withdraw` pays out after the strategy walk.

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
2. `expected_underlying = floor(N × total / yt_supply)` discards up to `1` unit of underlying (cdpm side; Kai's live `muldiv_round_up` adds 1 unit of headroom on top).
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
  if (vault.ytSupply === 0n) throw new Error('EReserveEmpty (1006)');
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
- **Bootstrap branch.** When `total_available == 0` cdpm's `compute_expected_yt` returns `t_amount` directly (1:1). The redeem inverse cannot be in this state — `compute_expected_underlying_kai` requires `yt_supply > 0`, and if `yt_supply > 0` and `total_available == 0` then per-YT value is `0` and any redeem nets `0` underlying. This helper returns `MAX_U64` in that branch, signaling "drain; expect zero net".
- **Admin guardrails.** Kai's `set_withdrawals_disabled` / `tvl_cap` / rate limiter are enforced inside `vault::withdraw`. The cdpm-side prediction does **not** see those flags; if they trigger, the inner `vault::withdraw` aborts and the cdpm hot-potato ticket is never consumed. The PM is safe; the protocol bot retries when the limiter clears.

### 7.3 Worked Example

Vault state: `total_available = 1100`, `yt_supply = 1050`. PM-Kai-vault: `yt_in_pm = 1000` YT, `principal_in_pm = 950` underlying. Fee rate = `2000` bp = 20%.

Implied per-YT values: `p = 1100/1050 ≈ 1.0476`, `π = 950/1000 = 0.95`. Since `p > π`, interest exists.

**Goal:** redeem so that `>= 100` underlying lands in `pm.balance[T]` net of fee.

1. `net_per_yt = 1.0476 × 0.8 + 0.2 × 0.95 = 0.8381 + 0.19 = 1.0281`
2. Closed-form `N ≈ ceil(100 / 1.0281) = 98` YT.
3. Forward simulation with `N = 98`:
   - `principal_portion = floor(950 × 98 / 1000) = floor(93.1) = 93`
   - `expected_underlying = floor(98 × 1100 / 1050) = floor(102.67) = 102` (Kai's live `muldiv_round_up` would give `103`, but cdpm uses the floor)
   - `interest = 102 − 93 = 9`
   - `fee = floor(9 × 2000 / 10000) = floor(1.8) = 1`
   - `net = 102 − 1 = 101`  →  `101 >= 100`  ✓

The forward sim confirms the closed form. The bot feeds `kai_start_redeem` with `yt_amount = 98`, the bot pays `1` underlying yield fee, and `pm.balance[T]` increases by `101` (or `102` if Kai's `muldiv_round_up` gives an extra unit).

If `desiredNet` had been `103`, the closed-form would have returned `N = 101`, and forward sim would have yielded `net = 103` (or `104`) — the iterative refinement helper would not have needed to bump.

---

## 8. Reading Vault State Off-Chain

The simplest approach is a dry-run of the same view path cdpm uses:

```
1. kai_sav::vault::total_available_balance(vault, clock)  → u64
2. kai_sav::vault::total_yt_supply(vault)                  → u64
```

Both are public view functions on `Vault<T, YT>`. A dry-run gRPC `dev_inspect` against the same vault and clock object that your live PTB will use produces snapshots that exactly match the on-chain values cdpm sees.

For sizing, also read the per-PM Kai vault entry by querying `pm.lending` (a `Bag`) under bag key `type_name<YT>`:

- `KaiVault.yt_balance.value` → `yt_in_pm`
- `KaiVault.principal` → `principal_in_pm`

---

## 9. Safety Margins

When sizing inputs:

- For `kai_start_supply<T, YT>`: `t_amount × yt_supply >= total_available` to avoid `EZeroExpected`. In practice deposit at least a few hundred MIST equivalents.
- For `kai_start_redeem<T, YT>`: `yt_amount × total_available >= yt_supply` for the same reason. The inverse helpers in section 7 already enforce ceiling rounding, so they cannot produce `N = 0` for any positive target.
- Build in headroom against `EAmountShortfall` by re-snapshotting the vault and PM-vault entry *immediately* before signing. Kai's `total_available_balance` ticks every block as time-locked profit unlocks; a stale snapshot can predict a slightly higher `expected_underlying` than the live vault delivers.
- For batched protocol bots: snapshot once per batch, not once per PM. As long as the batch fits in one block, all redeems see the same `total_available_balance`. Across blocks, re-snapshot.
- **Strategy walks add a soft latency budget.** Each strategy walker is a move-call that runs the strategy module's settlement logic. Large vaults with many strategies make the redeem PTB longer (and gas-hungrier) than the equivalent Scallop redeem. Build the PTB length into your gas budget.

---

## 10. Cross-Reference

- Owner PTB recipes: [`cdpm-user-sdk/reference/kai-lending.md`](../../cdpm-user-sdk/reference/kai-lending.md)
- Agent PTB recipes: [`cdpm-agent-sdk/reference/kai-lending.md`](../../cdpm-agent-sdk/reference/kai-lending.md)
- Protocol PTB recipes: [`cdpm-protocol-sdk/reference/kai-lending.md`](../../cdpm-protocol-sdk/reference/kai-lending.md)
- Scallop counterpart math: [`scallop-lending-math.md`](./scallop-lending-math.md)
