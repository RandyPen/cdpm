# CDPM Formal Verification with sui-prover

## Status

The current mainnet dependency set passes `admin_set_fee_spec` with
`sui-prover` 1.5.3. The verification runner resolves the two Wormhole
packages separately and checks both original on-chain addresses.

> **2026-08-18 security advisory:** the four lending-helper specs
> (`spec_call_add_to_*_lending_spec` / `spec_call_pull_from_*_lending_spec`)
> were **removed** together with the `#[spec_only] public fun spec_call_*`
> wrappers they targeted. Those wrappers compiled into production bytecode
> as unauthenticated `&mut PositionManager` entry points (Critical). The
> accumulation / conservation properties they proved are now enforced by
> `#[test_only]` unit tests in `tests/cdpm_tests.move` (see below).

```
✅ admin_set_fee_spec                       (fee-rate cap + post-state)
```

## Scope

Specifications live in a sibling package [`specs/`](./specs/) consumed only by
`sui-prover`. The chain package (`sources/cdpm.move`) contains **no**
`#[spec_only]` items — spec support uses `#[test_only]` getters only (see
"Spec Support in `cdpm.move`" below).

> **IMPORTANT — do not trust the "stripped like `#[test_only]`" claim.**
> `#[spec_only]` is a **custom attribute**, not a Move primitive. The regular
> compiler tolerates it as an unknown-attribute warning and compiles the
> annotated items into production bytecode **verbatim**. Only `#[test_only]`
> is stripped from non-test builds. The 2026-08-18 advisory confirmed this via
> bytecode disassembly: the `spec_call_*` wrappers were present in the
> deployed bytecode as ordinary `public` functions. Any future spec support
> must therefore use `#[test_only]` getters, never `#[spec_only]`.

cdpm calls `protocol::mint::mint` / `protocol::redeem::redeem` /
`kai_vault::deposit` / `kai_vault::withdraw` /
`kai_leverage_supply_pool::withdraw` / `kai_vault::redeem_withdraw_ticket`
itself. The public lending entries (`scallop_supply`, `scallop_redeem`,
`kai_supply`, `kai_redeem`) thread the asset amount and the upstream
shared objects into those calls. They are not direct sui-prover targets
in this package because they call into external packages outside cdpm's
verification scope.

The verified surface is the **load-bearing money-flow core**: the four
internal lending helpers that the public entries call, plus the admin
fee-rate cap. These together pin the worst-case skim and the fee model.

## Verified Properties

### A. Admin gate

| ID | Spec | Statement |
|----|------|-----------|
| **P-FeeRateBound** | `admin_set_fee_spec` | `admin_set_fee` aborts iff `(fee_rate as u128) > 5000` (`EInvalidFeeRate`). |
| **P-FeeCap** | `admin_set_fee_spec` | On successful return, `fee_house.fee_rate == fee_rate`, hence `<= 5000`. |

### B. Lending helpers — accumulation & conservation (moved to unit tests)

> **Removed from prover scope on 2026-08-18.** The `spec_call_*` wrappers
> that made the private helpers targetable cross-package were `#[spec_only]`
> `public` functions and shipped in production bytecode unauthenticated.
> The properties below are now asserted by `#[test_only]` unit tests in
> `tests/cdpm_tests.move` (which the compiler strips from production).

| Test | Statement |
|------|-----------|
| `test_call_add_to_*_lending` | Post-state: `vault.principal_after == pre + principal_added`; `vault.scoin/yt_after == pre + balance.value()`. **No silent skim of either coordinate.** |
| `test_call_pull_from_*_lending` | **Conservation**: returned `principal_portion <= vault.principal_before`. Returned balance value `== min(want_amount, total_before)`. |

## End-to-End Composition

Read the matrix in context of the four public lending entries:

1. **Supply (`scallop_supply` / `kai_supply`)** — cdpm withdraws `Coin<T>`
   from `pm.balance`, calls `mint::mint` / `kai_vault::deposit` with it, gets
   `Balance<MarketCoin<T>>` / `Balance<YT>` back, and inlines
   `add_to_*_lending(pm, balance, actual_coin_value)`.
   - The unit-tested `add_to_*_lending` accumulation property guarantees the
     vault's principal grows by exactly the actual coin withdrawn from PM,
     and the share-token balance grows by exactly what the external call
     returned. No silent skim of either coordinate at the storage boundary.

2. **Redeem (`scallop_redeem` / `kai_redeem`)** — cdpm calls
   `pull_from_*_lending(pm, want)` to get `(Balance<sToken>, principal_portion)`,
   then passes the balance through `redeem::redeem` /
   `kai_vault::withdraw + klsp::withdraw + redeem_withdraw_ticket` to get
   `Balance<T>`. The fee carve uses the `principal_portion` returned from
   `pull_from_*_lending`.
   - The unit-tested `pull_from_*_lending` conservation property bounds the
     principal_portion: `principal_portion <= pre_principal`. Together with
     the inline fee formula `interest = max(0, redeemed - principal_portion)`,
     this gives the upper bound on skimmable interest.

3. **Fee rate cap** — `admin_set_fee_spec` guarantees `fee_rate <= 5000` for
   any `FeeHouse` that ever existed. The fee formula in `scallop_redeem` /
   `kai_redeem` is `fee = interest * fee_rate / 10000`, so the maximum fee
   on any redeem is `0.5 * interest`. This is invariant by construction +
   the verified admin spec.

## What the prover does NOT cover (and why)

| Surface | Why | Mitigation |
|---------|-----|------------|
| **Inline fee/balance arithmetic** in `scallop_redeem` / `kai_redeem` | The fee formula is the spec; we'd need a separate axiomatic statement of "the documented fee model" to verify it, which is circular. | Unit tests cover principal bookkeeping. The inline fee calculation is reviewed separately from the proof. |
| **Lending helper accumulation / conservation** (`add_to_*_lending` / `pull_from_*_lending`) | Cross-package verification required `#[spec_only] public` wrappers, which shipped in production bytecode (Critical, 2026-08-18). Removed. | `#[test_only]` unit tests in `tests/cdpm_tests.move`. |
| **External call returns** (`mint::mint`, `redeem::redeem`, `kai_vault::deposit`, `kai_vault::withdraw`, `klsp::withdraw`, `redeem_withdraw_ticket`) | External packages outside cdpm's prover scope. | Trust boundary acknowledged. Scallop / Kai are upstream-audited; cdpm faithfully forwards their returns. |
| **Kai strategy loss** (`StrategyLossEvent` in `redeem_withdraw_ticket`) | Kai vault internal. | The cdpm fee carve gives `interest = 0` if `redeemed < principal_portion`, so a strategy-loss redeem charges no fee. |
| **ACL** (`assert_caller_authorized`) | Standard `vec_set::contains` membership check; low intrinsic risk. | Not a money-flow property. |
| **Cetus DLMM integration** (`protocol_*` / `agent_*`) | Crosses into Cetus's contracts. | Cetus is independently audited. |
| **DEP_ONLY upgrade policy** | Off-chain package governance. | The current deployment uses OnlyDep policy `192`. [Mainnet deployment](README.md#sui-mainnet) |

## Spec Preconditions (Audit-Visible Assumptions)

The `requires(...)` clauses encode assumptions the prover takes for granted.

### Balance non-overflow
- **Assumption**: `pre + delta <= u64::MAX` for `vault.principal`,
  `vault.scoin/yt_balance`.
- **Used in**: the removed `spec_call_add_to_*_lending_spec` proofs (now
  unit-tested in `tests/cdpm_tests.move`).
- **Justification**: cross-protocol PTBs always source the delta from a
  clamped coin value (see
  `skills/cdpm-calculation-skill/reference/cross-protocol-ptb.md`), never
  from an unconstrained u64. Single-asset PMs in practice never approach
  `u64::MAX` per coin (bounded by token total supply).

### Bag size bound
- **Assumption**: `pm.lending.size < u64::MAX`.
- **Used in**: the removed `spec_call_add_to_*_lending_spec` proofs (now
  unit-tested).
- **Justification**: the prover doesn't model the bag invariant
  `size = #entries`. Real bags are bounded by the number of distinct
  `coin_type` strings — finite by Move's type system.

### Vault exists for pull
- **Assumption**: `spec_pm_scallop_vault_exists<T>(pm)` (resp. Kai).
- **Used in**: the removed `spec_call_pull_from_*_lending_spec` proofs (now
  unit-tested).
- **Justification**: `pull_from_*_lending` asserts the vault exists
  (`ENoSuchVault`). All real call sites (`scallop_redeem` / `kai_redeem`)
  reach this only after a successful prior supply.

## How to Reproduce

From the repository root, with Bun, Sui CLI 1.84, and `sui-prover` installed:

```bash
brew install asymptotic-code/sui-prover/sui-prover
bun --no-env-file specs/verify.ts
```

A successful run ends with `Verification successful`. The runner builds
CDPM with the mainnet dependency graph in `Move.lock`, then stages the
compiled source set and the specification in a temporary directory. It uses
the source maps from that build to recover each package's original address.

The legacy prover resolver requires unique package and address names in its
input. In the staged copies, the Pyth Pro branch uses `pyth_pro` and
`wormhole_simple_majority`, retaining both original addresses alongside
the Pyth core and token bridge references. The runner copies the upstream
test modules required by dependency declarations and adapts two APIs for the
older prover framework. It uses the original `dynamic_field::exists_`
name and the same quotient-and-remainder expression for `div_ceil`.

The runner compiles the CDPM implementation and its current specification
without editing either. Production builds use the root `Move.toml` and
`Move.lock`.

## Spec Support in `cdpm.move`

`sources/cdpm.move` contains **no** `#[spec_only]` items. `#[spec_only]` is a
custom attribute that the regular compiler tolerates but does **not** strip —
the 2026-08-18 advisory showed the former `spec_call_*` wrappers shipping in
production bytecode unauthenticated. Spec support uses only `#[test_only]`
(Move primitive, compiler-stripped):

| Category | Purpose |
|----------|---------|
| **Private-field getters** (`test_only_fee_house_rate`, `test_only_scallop_lending_state`, etc.) | Let the spec package read private fields cross-module — the sui-prover SKILL.md "Private struct field access" pattern. Stripped from production by the compiler. |
| **Test-only lending wrappers** (`test_only_add_to_*_lending`, `test_only_pull_from_*_lending`) | `#[test_only]` 1:1 forwarders around private lending helpers for unit tests. Stripped from production by the compiler. |

## Production Code Changes for Verification

One production-code change was carried over from the pre-refactor spec:

**`bag::contains<K>` → `bag::contains_with_type<K, V>`** in
`add_to_balance`, `withdraw_from_balance`, `add_to_fee`, `withdraw_from_fee`,
`deposit_into_fee_house`, `add_to_scallop_lending`, `pull_from_scallop_lending`,
`add_to_kai_lending`, `pull_from_kai_lending`.
- **Why**: the prover's encoding does not connect `contains<K>` with
  `borrow<K, V>` (entries could in principle have a different value type).
  `contains_with_type<K, V>` does, so abort proofs go through.
- **Behavior change**: strictly narrower abort surface. The old code would
  `abort EFieldTypeMismatch` if a key existed with a wrong value type; the
  new code returns false and takes the `else` branch (which then
  `bag::add` would `abort EFieldAlreadyExists`). Both unreachable in cdpm's
  actual usage — we strictly insert one value type per key.

## Files

- `specs/verify.ts` — builds and stages dependencies, then runs the proof.
- `specs/Move.toml` — manifest copied into the temporary verification package.
- `specs/sources/cdpm_spec.move` — 1 spec function targeting `cdpm::*`
  (admin fee-rate gate; lending-helper proofs removed 2026-08-18).
- `sources/cdpm.move` — production source. No `#[spec_only]` items;
  spec support uses `#[test_only]` getters only.
- `tests/cdpm_tests.move` — unit tests for the lending helpers
  (accumulation / conservation) via the `#[test_only]` wrappers.
- `Move.toml` and `Move.lock` — production dependency manifest and pins.
