# CDPM Formal Verification with sui-prover

## Status

**5 specifications, all passing** (`sui-prover` 2.8.5 bottle).
`Verification successful`.

```
✅ admin_set_fee_spec                       (fee-rate cap + post-state)
✅ spec_call_add_to_scallop_lending_spec    (accumulation)
✅ spec_call_pull_from_scallop_lending_spec (conservation)
✅ spec_call_add_to_kai_lending_spec        (accumulation)
✅ spec_call_pull_from_kai_lending_spec     (conservation)
```

## Scope

Specifications live in a sibling package [`specs/`](./specs/) consumed only by
`sui-prover`. Regular `sui move build` ignores the `#[spec_only]` /
`#[spec(...)]` attributes (with a warning) and ships byte-identical
production code.

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

### B. Lending helpers — accumulation & conservation

| Spec | Statement |
|------|-----------|
| `spec_call_add_to_scallop_lending_spec` / `spec_call_add_to_kai_lending_spec` | Post-state: `vault.principal_after == pre + principal_added`; `vault.scoin/yt_after == pre + balance.value()`. **No silent skim of either coordinate.** |
| `spec_call_pull_from_scallop_lending_spec` / `spec_call_pull_from_kai_lending_spec` | **Conservation**: returned `principal_portion <= vault.principal_before`. Returned balance value `== min(want_amount, total_before)`. |

## End-to-End Composition

Read the matrix in context of the four public lending entries:

1. **Supply (`scallop_supply` / `kai_supply`)** — cdpm withdraws `Coin<T>`
   from `pm.balance`, calls `mint::mint` / `kai_vault::deposit` with it, gets
   `Balance<MarketCoin<T>>` / `Balance<YT>` back, and inlines
   `add_to_*_lending(pm, balance, actual_coin_value)`.
   - The verified `add_to_*_lending` accumulation property guarantees the
     vault's principal grows by exactly the actual coin withdrawn from PM,
     and the share-token balance grows by exactly what the external call
     returned. No silent skim of either coordinate at the storage boundary.

2. **Redeem (`scallop_redeem` / `kai_redeem`)** — cdpm calls
   `pull_from_*_lending(pm, want)` to get `(Balance<sToken>, principal_portion)`,
   then passes the balance through `redeem::redeem` /
   `kai_vault::withdraw + klsp::withdraw + redeem_withdraw_ticket` to get
   `Balance<T>`. The fee carve uses the `principal_portion` returned from
   `pull_from_*_lending`.
   - The verified `pull_from_*_lending` conservation property bounds the
     principal_portion: `principal_portion <= pre_principal`. Together with
     the inline fee formula `interest = max(0, redeemed - principal_portion)`,
     this gives the spec-mandated upper bound on skimmable interest.

3. **Fee rate cap** — `admin_set_fee_spec` guarantees `fee_rate <= 5000` for
   any `FeeHouse` that ever existed. The fee formula in `scallop_redeem` /
   `kai_redeem` is `fee = interest * fee_rate / 10000`, so the maximum fee
   on any redeem is `0.5 * interest`. This is invariant by construction +
   the verified admin spec.

## What the prover does NOT cover (and why)

| Surface | Why | Mitigation |
|---------|-----|------------|
| **Inline fee/balance arithmetic** in `scallop_redeem` / `kai_redeem` | The fee formula is the spec; we'd need a separate axiomatic statement of "the documented fee model" to verify it, which is circular. | Unit-test coverage + code inspection. Blast radius is bounded by `pull_from_*_lending` conservation: any skim is `<= principal_portion <= pre_principal`. |
| **External call returns** (`mint::mint`, `redeem::redeem`, `kai_vault::deposit`, `kai_vault::withdraw`, `klsp::withdraw`, `redeem_withdraw_ticket`) | External packages outside cdpm's prover scope. | Trust boundary acknowledged. Scallop / Kai are upstream-audited; cdpm faithfully forwards their returns. |
| **Kai strategy loss** (`StrategyLossEvent` in `redeem_withdraw_ticket`) | Kai vault internal. | The cdpm fee carve gives `interest = 0` if `redeemed < principal_portion`, so a strategy-loss redeem charges no fee. |
| **ACL** (`assert_caller_authorized`) | Standard `vec_set::contains` membership check; low intrinsic risk. | Not a money-flow property. |
| **Cetus DLMM integration** (`protocol_*` / `agent_*`) | Crosses into Cetus's contracts. | Cetus is independently audited. |
| **DEP_ONLY upgrade policy** | Off-chain (`only_dep_upgrades` is invoked post-publish). | Recorded in `publish.md` with the tx digest. |

## Spec Preconditions (Audit-Visible Assumptions)

The `requires(...)` clauses encode assumptions the prover takes for granted.

### Balance non-overflow
- **Assumption**: `pre + delta <= u64::MAX` for `vault.principal`,
  `vault.scoin/yt_balance`.
- **Used in**: `spec_call_add_to_*_lending_spec`.
- **Justification**: cross-protocol PTBs always source the delta from a
  clamped coin value (see
  `skills/cdpm-calculation-skill/reference/cross-protocol-ptb.md`), never
  from an unconstrained u64. Single-asset PMs in practice never approach
  `u64::MAX` per coin (bounded by token total supply).

### Bag size bound
- **Assumption**: `pm.lending.size < u64::MAX`.
- **Used in**: `spec_call_add_to_*_lending_spec`.
- **Justification**: the prover doesn't model the bag invariant
  `size = #entries`. Real bags are bounded by the number of distinct
  `coin_type` strings — finite by Move's type system.

### Vault exists for pull
- **Assumption**: `spec_pm_scallop_vault_exists<T>(pm)` (resp. Kai).
- **Used in**: `spec_call_pull_from_*_lending_spec`.
- **Justification**: `pull_from_*_lending` asserts the vault exists
  (`ENoSuchVault`). All real call sites (`scallop_redeem` / `kai_redeem`)
  reach this only after a successful prior supply.

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
   on Scallop deps (sui-prover refuses `rename-from`). After the
   direct-integration refactor, this patched copy also points `protocol`
   at `../sui-lending-protocol/contracts/protocol` so the system has a
   single on-chain Scallop package.

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
| **PositionManager / FeeHouse state probes** (`spec_pm_*`, `spec_fee_house_*`) | Read internal bag entries for pre/post-state comparisons in ensures. The `_exists` / `_size` variants support `requires(...)` for abort soundness. |
| **Function call wrappers** (`spec_call_add_to_*_lending`, `spec_call_pull_from_*_lending`) | Thin `public fun` forwarders around private `fun`s so the cross-module spec package can target them. |
| **Constants** (`spec_max_fee_rate`) | Expose internal `MAX_FEE_RATE` to the spec. |

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

- `specs/Move.toml` — spec package manifest (prover-only).
- `specs/sources/cdpm_spec.move` — 5 spec functions targeting `cdpm::*`.
- `sources/cdpm.move` — production source + `#[spec_only]` scaffolding.
- `Move.toml` — production manifest. Deps use PascalCase + `rename-from`
  for sui-prover compatibility (stricter than `sui` CLI on dep keys).
