# CDPM Formal Verification with sui-prover

## Status

**15 specifications × 3 prover phases = 45 verification conditions, all
passing** (`sui-prover` 2.8.5 bottle). `Verification successful`.

```
✅ admin_set_fee_spec                 (fee-rate cap + post-state)
✅ scallop_start_supply_spec          (ticket construction)
✅ scallop_start_redeem_spec          (ticket construction)
✅ kai_start_supply_spec              (ticket construction)
✅ kai_start_redeem_spec              (ticket construction)
✅ scallop_finish_supply_spec         (abort + accumulation)
✅ scallop_finish_redeem_spec         (abort + dust + fee/balance split)
✅ kai_finish_supply_spec             (abort + accumulation)
✅ kai_finish_redeem_spec             (abort + dust + fee/balance split)
✅ spec_call_add_to_scallop_lending_spec    (accumulation)
✅ spec_call_pull_from_scallop_lending_spec (conservation)
✅ spec_call_add_to_kai_lending_spec        (accumulation)
✅ spec_call_pull_from_kai_lending_spec     (conservation)
✅ spec_call_compute_expected_scoin_spec               (bootstrap + formula)
✅ spec_call_compute_expected_underlying_scallop_spec  (formula)
```

## Scope

Specifications live in a sibling package [`specs/`](./specs/) consumed only by
`sui-prover`. Regular `sui move build` ignores the `#[spec_only]` /
`#[spec(...)]` attributes (with a warning) and ships byte-identical
production code.

The verification effort focuses on cdpm's **money-flow correctness**: the
boundary at which user/agent value enters cdpm's `PositionManager` and the
boundary at which it exits to the user via `FeeHouse` / `pm.balance`. Together
the four classes of property below pin every raw unit of every lending
flow.

## Verified Properties

### A. Admin gate

| ID | Spec | Statement |
|----|------|-----------|
| **P-FeeRateBound** | `admin_set_fee_spec` | `admin_set_fee` aborts iff `(fee_rate as u128) > 3000` (`EInvalidFeeRate`). |
| **P-FeeCap** | `admin_set_fee_spec` | On successful return, `fee_house.fee_rate == fee_rate`, hence `<= 3000`. |

### B. Ticket construction (F-03 canonical-object binding origin)

For each of `scallop_start_supply`, `scallop_start_redeem`,
`kai_start_supply`, `kai_start_redeem`:

| ID | Statement |
|----|-----------|
| **P-Bind-{Pm,Market,Vault}** | `ticket.pm_id == object::id(pm)`, etc. |
| **P-NoSkim** | `ticket.principal == coin.value()` (supply) /<br>`ticket.scoin_burned == scoin.value()` (Scallop redeem) /<br>`ticket.yt_burned == yt.value()` (Kai redeem). |
| **P-NonZeroExpected** | `ticket.expected_* > 0` (else `EZeroExpected`). |

### C. Hot-potato consumption (abort + accumulation)

For each of `scallop_finish_supply`, `scallop_finish_redeem`,
`kai_finish_supply`, `kai_finish_redeem`:

| ID | Statement |
|----|-----------|
| **P-WrongPm** | function aborts when `ticket.pm_id != object::id(pm)`. |
| **P-WrongMarket / P-WrongVault** | function aborts when `ticket.market_id != object::id(market)` / `vault_id != object::id(vault)`. |
| **P-AmountShortfall** | supply: aborts when `scoin.value() < ticket.expected_scoin` (or YT equivalent). Redeem: aborts when `expected − redeemed > REDEEM_DUST_TOLERANCE_RAW = 4`. |
| **P-Supply-Accumulation** | post-state: `vault.principal_after == pre + ticket.principal`; `vault.scoin/yt_after == pre + coin.value()`. **No silent skim of either coordinate.** |
| **P-Redeem-FeeSplit** | post-state: `fee_house.balance[T]_after == pre + predicted_fee`; `pm.balance[T]_after == pre + redeemed - predicted_fee`, where<br>`predicted_fee = if redeemed > principal_portion`<br>`then ((redeemed - principal_portion) * fee_rate) / 10000`<br>`else 0`. **No silent fee theft; principal never taxed; remainder fully refunded.** |

### D. Internal helpers (called by finish_*)

| Spec | Statement |
|------|-----------|
| `spec_call_add_to_scallop_lending_spec` / `_kai_` | post-state: `vault.principal_after == pre + principal_added`; `vault.scoin/yt_after == pre + balance.value()`. |
| `spec_call_pull_from_scallop_lending_spec` / `_kai_` | **Conservation**: returned `principal_portion <= vault.principal_before`. Returned balance value `== min(want_amount, total_before)`. |

### E. Compute_expected_* (Scallop only)

| Spec | Statement |
|------|-----------|
| `spec_call_compute_expected_scoin_spec` | **Bootstrap**: `supply == 0 ⇒ result == coin_amount` (1:1 mint).<br>**Formula**: `supply > 0 ⇒ result == coin_amount * supply / (cash + debt - revenue)` (verified against `Market` accessors that walk the same `reserve::balance_sheets` chain as the function). |
| `spec_call_compute_expected_underlying_scallop_spec` | **Formula**: `result == scoin_amount * (cash + debt - revenue) / supply`. |

## End-to-End Composition

Read the matrix top-to-bottom and the following end-to-end invariants
emerge from composing per-function specs:

1. **No skim user → vault**:
   - `start_supply` (B-NoSkim): `ticket.principal == coin.value()`.
   - `finish_supply` (C-Supply-Accumulation): `vault.principal_after == pre + ticket.principal`.
   - ⇒ Every raw the user deposits hits the vault. Cannot be diverted.

2. **No skim vault → user (on redeem)**:
   - `start_redeem` (D-Conservation): `principal_portion <= vault.principal_before`; `scoin_burned == burned`.
   - `finish_redeem` (C-Redeem-FeeSplit): exact fee/balance split per formula.
   - ⇒ User receives `redeemed - formula_fee`; fee_house receives `formula_fee`.
     No third leak.

3. **Fee model is the documented one**:
   - `fee_amount = (redeemed - principal_portion) * fee_rate / 10000` only when redeem yields interest.
   - `fee_rate <= 3000` is invariant by construction (D below).
   - Principal is never taxed (only the interest portion).

4. **F-03 canonical-object binding (end-to-end)**:
   - `start_*` (B-Bind-*): ticket born bound to `(pm, market/vault)`.
   - `finish_*` (C-WrongPm/WrongMarket/WrongVault): ticket can only be
     replayed against the same `(pm, market/vault)` triple.
   - ⇒ No cross-PM or cross-market/vault replay.

## Spec Preconditions (Audit-Visible Assumptions)

The `requires(...)` clauses encode assumptions the prover takes for granted.
Each is justified below; SPEC.md is the central record for auditors.

### Fee rate bound
- **Assumption**: `fee_house.fee_rate <= MAX_FEE_RATE = 3000`.
- **Used in**: `scallop_finish_redeem_spec`, `kai_finish_redeem_spec`.
- **Justification**: `FeeHouse` has a single construction site — `init`
  (`cdpm.move:375`) — which hardcodes `fee_rate: 2000` and runs once at
  module publish (Sui Move privileged initializer; cannot be invoked
  post-deploy). The only mutator is `admin_set_fee`, proven by
  `admin_set_fee_spec` to abort on `> 3000`. Move struct-field privacy
  + the single-construction-point guarantees no `FeeHouse` instance can
  escape `fee_rate <= 3000`.
- **Soundness**: closed by construction + admin_set_fee_spec.

### Balance non-overflow
- **Assumption**: `pre + delta <= u64::MAX` for `pm.balance`, `pm.fee`,
  `fee_house.fee`, `vault.principal`, `vault.scoin/yt_balance`.
- **Used in**: all finish_* specs; add_to_*_lending specs.
- **Justification**: cross-protocol PTBs always source the delta from a
  clamped coin value (see `skills/cdpm-calculation-skill/reference/cross-protocol-ptb.md`),
  never from an unconstrained u64. Single-asset PMs in practice never
  approach `u64::MAX` per coin (bounded by token total supply).
- **Soundness**: realistic-flow argument, not formal. A malicious caller
  cannot construct an adversarial `u64::MAX` ticket directly because
  `start_*` clamps via `withdraw_from_balance`.

### Bag size bound
- **Assumption**: `bag.size < u64::MAX` for `pm.lending`, `pm.balance`,
  `pm.fee`, `fee_house.fee`.
- **Used in**: finish_* specs, lending add_to_* specs.
- **Justification**: the prover doesn't model the bag invariant `size = #entries`.
  Real bags are bounded by the number of distinct `coin_type` strings —
  finite by Move's type system.

### Vault exists for pull
- **Assumption**: `spec_pm_scallop_vault_exists<T>(pm)` (resp. Kai).
- **Used in**: `spec_call_pull_from_*_lending_spec`.
- **Justification**: `pull_from_*_lending` asserts the vault exists (`ENoSuchVault`).
  All real call sites (`*_start_redeem`) reach this only after a successful
  prior `*_finish_supply`.

### Scallop reserve invariants
- **Assumption**: `cash + debt >= revenue` (no underflow in `denom`);
  `cash + debt - revenue <= u64::MAX` (no overflow in `coin * denom`
  intermediate).
- **Used in**: `spec_call_compute_expected_scoin_spec`,
  `spec_call_compute_expected_underlying_scallop_spec`.
- **Justification**: Scallop's `reserve.move` enforces these via u64
  arithmetic in `accrue_interest` / `into_underlying_coin_amount`. cdpm
  is a downstream consumer; we propagate Scallop's invariant rather than
  reverify it.

## Out of Scope

| Surface | Why | Mitigation |
|---------|-----|------------|
| **Kai `compute_expected_*`** | `kai_vault::total_available_balance` aggregates `StrategyState.borrowed` across an unbounded `VecMap<ID, StrategyState>`. Bounding the abort path requires exposing every strategy's state — Kai upstream's responsibility, not cdpm's. | Faithful pass-through is guaranteed by `kai_start_*_spec` (NoSkim) + `kai_finish_*_spec` (Shortfall + FeeSplit). The formula `compute_expected_*` returns is whatever the function computes; if it's incorrect, the bug is in Kai, not cdpm. |
| **ACL** (`assert_caller_authorized`) | Standard `vec_set::contains` membership check; low intrinsic risk. | Not a money-flow property. Considered when verifying `start_*` aborts (out of scope here). |
| **Oracle freshness** (`assert_scallop_state_fresh`) | Timestamp equality `(clock_ms / 1000) == last_updated`. | Verified at runtime by start_*'s assert; spec-only verification would just restate the comparison. |
| **Cetus DLMM integration** (`protocol_*`) | Crosses into Cetus's contracts. | Cetus is independently audited. cdpm's role is hot-potato passing; the bookkeeping properties above cover the cdpm side. |
| **PTB-level ordering** (start before finish, atomic bundling) | Off-chain. | Enforced on-chain by the hot-potato `*Ticket` types: they have no `drop` ability, so the PTB must consume each ticket within the same transaction. |

## How to Reproduce

```bash
# One-time setup (Homebrew tap).
brew install asymptotic-code/sui-prover/sui-prover

# Run the prover.
cd /path/to/cdpm/specs
sui-prover --skip-fetch-latest-git-deps
```

Expected last line:

```
Verification successful
```

Regular `sui move build` of the production package still works and is
unaffected by the spec scaffolding:

```bash
cd /path/to/cdpm
sui move build
```

(The compiler emits `unknown attribute 'spec_only'` warnings — intentional.
`sui-prover` consumes the attributes; `sui move build` ignores them like
`#[test_only]`.)

### Required upstream patches

These patches are external to the cdpm repo but the prover run depends on
them. They are documented here so the verification chain is reproducible.

1. **`cetusdlmm`** — local patch at `/tmp/cetus-dlmm-patched/packages/dlmm`
   adding a missing `use sui::vec_map;` in a `#[test_only]` helper. See
   `Move.toml` comment for the diff scope.

2. **`kai_sav`** — patched copy at
   `../kai-contracts/kai/sav/core-prover-patched` that drops `rename-from`
   on Scallop deps (sui-prover refuses `rename-from`). See its `Move.toml`
   header for the full diff scope.

3. **`kai_leverage` test helper** — sui-prover bundles an older Move stdlib
   that lacks `std::u128::div_ceil`. The test file
   `kai-contracts/kai/leverage/core/tests/position_core/macros/standard_flow.move:53`
   uses `u128.div_ceil(...)`. A small inline helper
   `fun u128_div_ceil(a, b) { (a + b - 1) / b }` is substituted for that
   call to let sui-prover finish model building. Production `sui move build`
   skips upstream `tests/` and is unaffected.

## Prover-Only Code in `cdpm.move`

`sources/cdpm.move` contains `#[spec_only]` items (accessors, wrappers for
private helpers). All are stripped from production bytecode by the
asymptotic toolchain — same mechanism as `#[test_only]`. Categories:

| Category | Purpose |
|----------|---------|
| **Ticket field accessors** (`spec_*_ticket_*`) | Read private ticket fields from the cross-module spec package. |
| **PositionManager / FeeHouse state probes** (`spec_pm_*`, `spec_fee_house_*`) | Read internal bag entries for pre/post-state comparisons in ensures. The `_exists` / `_size` variants support `requires(...)` for abort soundness. |
| **Scallop market accessors** (`spec_scallop_market_{sheet_exists,supply,cash,debt,revenue}`) | Walk `market::vault → reserve::balance_sheets → wit_table::borrow → reserve::balance_sheet`, the same chain as `compute_expected_*`. Use the if-contains pattern so the accessors are total functions (no abort) and can be called freely from spec preconditions. |
| **Kai vault accessors** (`spec_kai_vault_total_available`, `spec_kai_vault_yt_supply`) | Forward to `kai_vault::*` for symmetry — declared but not used by any active spec (see Out of Scope). |
| **Function call wrappers** (`spec_call_*`) | Thin `public fun` forwarders around private `fun`s so the cross-module spec package can target them. |
| **Constants** (`spec_max_fee_rate`, `spec_redeem_dust_tolerance_raw`) | Expose internal constants to the spec. |
| **Compute_expected_* wrappers** | `spec_call_compute_expected_scoin` etc. forward to private helpers. |

## Production Code Changes for Verification

Two minimal changes to production code were required:

1. **`bag::contains<K>` → `bag::contains_with_type<K, V>`** in 9 sites
   (`add_to_balance`, `withdraw_from_balance`, `add_to_fee`, `withdraw_from_fee`,
   `deposit_into_fee_house`, `add_to_scallop_lending`, `pull_from_scallop_lending`,
   `add_to_kai_lending`, `pull_from_kai_lending`).
   - **Why**: the prover's encoding does not connect `contains<K>` with
     `borrow<K, V>` (entries could in principle have a different value
     type). `contains_with_type<K, V>` does, so abort proofs go through.
   - **Behavior change**: strictly narrower abort surface. The old code
     would `abort EFieldTypeMismatch` if a key existed with a wrong value
     type; the new code returns false and takes the `else` branch (which
     then `bag::add` would `abort EFieldAlreadyExists`). Both unreachable
     in cdpm's actual usage — we strictly insert one value type per key.

2. **`take_fee<T>` now returns `u64`** (the fee amount) instead of unit.
   - **Why**: caller (`protocol_collect_fee`, `protocol_collect_reward`)
     was computing `fee = amount_before - amount_after` by reading the
     balance twice. Returning the amount directly is cleaner and matches
     the inline fee math in `*_finish_redeem`.
   - **Behavior change**: none observable. The fee deposit + return are
     identical to the pre-refactor code path.

## Files

- `specs/Move.toml` — spec package manifest (prover-only).
- `specs/sources/cdpm_spec.move` — 15 spec functions targeting `cdpm::*`.
- `sources/cdpm.move` — production source + `#[spec_only]` scaffolding
  (~370 lines added, stripped from production bytecode).
- `Move.toml` — production manifest. Deps use PascalCase + `rename-from`
  for sui-prover compatibility (stricter than `sui` CLI on dep keys).
