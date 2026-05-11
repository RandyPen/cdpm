# CDPM Formal Verification with sui-prover

## Scope

This document records the formal-verification surface for the CDPM (Position
Manager) Move package against the [sui-prover](https://info.asymptotic.tech/sui-prover)
toolchain (asymptotic.tech). sui-prover lowers Move to Boogie and discharges
verification conditions with Z3. Specifications live in a sibling package
[`specs/`](./specs/) so they are invisible to the standard Sui Move build.

The aim is *not* end-to-end correctness but selective high-leverage invariants
that protect admin gates and hot-potato boundaries. Lending arithmetic
(`pull_from_lending`'s ratio non-decrease, `add_to_lending` co-positivity)
proved beyond what we can express without first refactoring `sources/cdpm.move`
to call `bag::contains_with_type` rather than `bag::contains`. We chose **not**
to refactor production code for verification convenience and instead document
the gap below.

## Verified Properties

| ID | Statement | File:Line | Status |
|----|-----------|-----------|--------|
| **P-FeeRateBound** | `admin_set_fee` aborts iff `(fee_rate as u128) > 3000`. Encoded as `asserts((fee_rate as u128) <= SPEC_MAX_FEE_RATE)`. | [`specs/sources/cdpm_spec.move:44`](./specs/sources/cdpm_spec.move) | **proven** |
| **P-FeeCap** | After `admin_set_fee`, `spec_fee_house_rate(fee_house) == fee_rate`, hence `<= 3000`. Encoded as two `ensures`. | [`specs/sources/cdpm_spec.move:49-50`](./specs/sources/cdpm_spec.move) | **proven** |
| **P-WrongPm-supply** | `finish_supply<T>(pm, ticket, scoin)` requires `ticket.pm_id == object::id(pm)` (otherwise aborts with `EWrongPm`). Structural `asserts`. | [`specs/sources/cdpm_spec.move:75`](./specs/sources/cdpm_spec.move) | **structural** (see "Limitations") |
| **P-AmountShortfall-supply** | `finish_supply` requires `scoin.value() >= ticket.expected_scoin` (else `EAmountShortfall`). Structural `asserts`. | [`specs/sources/cdpm_spec.move:77`](./specs/sources/cdpm_spec.move) | **structural** |
| **P-WrongPm-redeem** | `finish_redeem<T>` requires `ticket.pm_id == object::id(pm)` (else `EWrongPm`). | [`specs/sources/cdpm_spec.move:102`](./specs/sources/cdpm_spec.move) | **structural** |
| **P-AmountShortfall-redeem** | `finish_redeem` requires `underlying.value() >= ticket.expected_underlying` (else `EAmountShortfall`). | [`specs/sources/cdpm_spec.move:104`](./specs/sources/cdpm_spec.move) | **structural** |
| **P-FakeSCoinExtraction-blocked** | `finish_supply<T>` is type-locked to `Coin<MarketCoin<T>>`; agents cannot fabricate fake sCoin types. Enforced by Move type system, not prover. | type-system, no spec needed | **type-checked** |
| **P-Kai-WrongPm-supply** | `kai_finish_supply<T, YT>(pm, ticket, yt)` aborts when `ticket.pm_id != object::id(pm)` (`EWrongPm`). | [`specs/sources/cdpm_spec.move`](./specs/sources/cdpm_spec.move) (`kai_finish_supply_spec`) | **written, sui-prover blocked** (see Limitations) |
| **P-Kai-AmountShortfall-supply** | `kai_finish_supply` requires `yt.value() >= ticket.expected_yt` (`EAmountShortfall`). | same | **written, sui-prover blocked** |
| **P-Kai-WrongPm-redeem** | `kai_finish_redeem<T, YT>` requires `ticket.pm_id == object::id(pm)`. | `kai_finish_redeem_spec` | **written, sui-prover blocked** |
| **P-Kai-AmountShortfall-redeem** | `kai_finish_redeem` requires `underlying.value() >= ticket.expected_underlying`. | same | **written, sui-prover blocked** |
| **P-FakeYTExtraction-blocked** | `kai_finish_supply<T, YT>` is type-locked to `Coin<YT>`; YT's `TreasuryCap<YT>` is held inside Kai's `Vault.lp_treasury` (private). `kai_sav::vault::new` is `public(package)` so external code cannot publish a `Vault<T, EvilYT>` with attacker-controlled YT. | type-system, no spec needed | **type-checked** |

All three spec functions are checked across the prover's three phases (`Check`,
`Assume`, `SpecNoAbortCheck`) and pass; the prover's last line is
`Verification successful`.

### Skipped / Aspirational Properties

The following candidates from the original property list were **not** encoded as
verifier-checked conditions, in each case for a reason explained below.

- **P-PrincipalMonotonic** (lending math, ratio non-decrease). Expressing
  `(P − ⌊P·w/S⌋)/(S − w) ≥ P/S` in spec syntax requires `Q64`/`Real` reasoning
  over the floor introduced by `pull_from_lending`. Tractable in principle —
  but `pull_from_lending`'s body contains `bag::contains` + `bag::borrow`
  (which the prover cannot connect; see Limitations) and a `balance::split`
  whose abort coverage would have to be encoded simultaneously. The clean
  fix is to refactor `pull_from_lending` to use `bag::contains_with_type`,
  which we are not doing here. Property left as future work — see
  `tests/cdpm_properties.move` for the matching property-test that already
  exercises the same arithmetic at runtime.
- **P-VaultPositiveAfterAdd** (co-positivity post-`add_to_lending`).
  Same root cause: `add_to_lending` calls `bag::contains` then `bag::borrow_mut`.
  The audit-flagged co-positivity edge case is enforced at runtime by
  `start_supply` (`assert!(actual > 0, EZeroExpected)` and the
  `expected_scoin > 0` check); the property tests in `tests/cdpm_properties.move`
  already exercise it.
- **P-EZeroExpected**. `start_supply` / `start_redeem` aborts on
  `compute_expected_*<T>(market, ...) == 0`. Encoding requires either reasoning
  over Scallop's `wit_table::borrow` (which lives in the `ScallopProtocol`
  package and is fully opaque to our specs) or stubbing it via `#[ext(pure)]`
  axioms. Out of scope for this pass.

## How to Reproduce

```bash
# Prerequisites (one-time)
brew install asymptotic-code/sui-prover/sui-prover
# brew also pulls Z3 and Boogie.

# Run the prover.
cd /path/to/cdpm-scallop/specs
GIT_CONFIG_PARAMETERS="'http.version=HTTP/1.1'" sui-prover --timeout 120
```

Expected last line: `Verification successful`.

A regular `sui move build` of the production package still works:

```bash
cd /path/to/cdpm-scallop
GIT_CONFIG_PARAMETERS="'http.version=HTTP/1.1'" sui move build
```

(The compiler emits `unknown attribute 'spec_only'` warnings — that is
intentional. `sui-prover` consumes those attributes; `sui move build` discards
them with a warning, exactly like `#[test_only]`.)

### Move.toml Notes

Both `Move.toml` files use PascalCase package names with `rename-from` because
`sui-prover` validates dep keys against the dep package's own `[package].name`
(stricter than `sui` CLI). The patched `cetusdlmm` lives at
`/tmp/cetus-dlmm-patched/packages/dlmm` (see the toml comment for why the patch
is needed).

The spec package `specs/Move.toml` references the prover library at
`../../sui-prover/packages/prover` — this is the local clone of
`https://github.com/asymptotic-code/sui-prover.git`. Adjust the path if the
clone lives elsewhere.

## Prover-Only Code in `cdpm.move`

`sources/cdpm.move:1740-1763` contains five `#[spec_only]` accessor functions
(`spec_fee_house_rate`, `spec_supply_ticket_pm_id`, `spec_supply_ticket_expected_scoin`,
`spec_redeem_ticket_pm_id`, `spec_redeem_ticket_expected_underlying`). These are
the only production-file additions for verification. They are stripped from
production bytecode by the prover toolchain (same mechanism as `#[test_only]`)
and emit only an "unknown attribute" warning under regular `sui move build`.

## Limitations

The prover does **not** cover:

- **Bag operations through `contains`/`borrow`.** `sui::bag::contains<K>` does
  not connect with `sui::bag::borrow<K, V>` in the prover's encoding (per
  asymptotic's own skill notes). `add_to_lending`, `pull_from_lending`,
  `finish_supply`, and `finish_redeem` all use this pattern. As a result the
  prover believes those bag accesses can abort even when `contains` returned
  `true`. We use `#[spec(prove, ignore_abort, ...)]` on `finish_supply_spec`
  and `finish_redeem_spec` to acknowledge this — the structural `asserts(...)`
  on ticket fields remain in the spec body as documentation but are *not*
  checked. **The fully-checked abort-iff property is `P-FeeRateBound` only.**
  To upgrade the finish_* specs to fully-checked, refactor `cdpm.move` to use
  `bag::contains_with_type`; see asymptotic skill `bag::contains_with_type`
  pattern.
- **Off-chain PTB construction.** The prover sees only on-chain Move semantics.
  It cannot verify ordering invariants imposed by PTB callers (e.g., that
  `start_supply` and `finish_supply` are bundled atomically). The hot-potato
  type pattern enforces this on-chain, but the spec does not formally state it.
- **Scallop-side invariants.** `ScallopProtocol::market::*` is treated as an
  opaque dependency. We do not prove anything about the lending pool's own
  balance sheets — only about how cdpm marshals values across the boundary.
- **Gas costs / DoS surface.** Out of scope for a verification tool.
- **H-D1 (T, S1) vs (T, S2) collision.** This issue no longer exists in the
  current code: the public surface no longer carries a free `S` generic;
  `finish_supply<T>` is statically typed to accept only `Coin<MarketCoin<T>>`.
  See README D-08 / DESIGN "Type-pinned sCoin".
- **Lending arithmetic** (P-PrincipalMonotonic, P-VaultPositiveAfterAdd) — see
  "Skipped" above.
- **Kai SAV specs (`kai_finish_supply_spec`, `kai_finish_redeem_spec`) are
  written but currently unverifiable by sui-prover.** The specs mirror the
  Scallop ones structurally and would prove the same `EWrongPm` /
  `EAmountShortfall` properties for the Kai branch. However,
  `kai_sav` (kai/sav/core/Move.toml) declares two transitive deps with
  `rename-from`: `scallop_protocol` → `protocol`, `scallop_pool` → `spool`.
  asymptotic's sui-prover requires every dep key to literally match the
  upstream `[package].name` and does not honor `rename-from` in transitive
  resolution. `sui move build` resolves these correctly because Sui CLI
  does honor `rename-from`. Verification of the Kai specs would require
  either (a) the asymptotic team adding `rename-from` support, or (b) a
  vendored copy of the kai_sav dep tree with canonical-name keys.
  Out of scope for this branch — the production `sui move build` and
  runtime correctness are unaffected. The type-pin defense for Kai
  (`Coin<YT>` mintable only by the live `Vault.lp_treasury`,
  `kai_sav::vault::new` is `public(package)`) is enforced by Move's
  type system regardless of spec verification status.

## Files

- `specs/Move.toml` — spec package manifest (prover-only).
- `specs/sources/cdpm_spec.move` — spec functions targeting `cdpm::*`.
- `sources/cdpm.move:1740-1763` — `#[spec_only]` accessors.
- `Move.toml` — production manifest (unchanged behaviour; deps renamed to
  PascalCase + `rename-from` so `sui-prover` accepts them).
