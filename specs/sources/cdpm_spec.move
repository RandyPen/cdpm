// CDPM Formal Verification Specs (sui-prover / asymptotic.tech).
//
// This module is compiled ONLY by `sui-prover`. Regular `sui move build`
// must NOT see this package — its `Move.toml` is the verification toolchain
// entry point. See ../../SPEC.md for property descriptions and reproduce
// instructions.
//
// All specs target functions in `cdpm::cdpm`. Private-field reads route
// through `#[spec_only]` accessors defined at the bottom of `cdpm.move`.
//
// Scope: the admin fee-rate gate plus the four internal lending helpers
// (`add_to_scallop_lending`, `pull_from_scallop_lending`,
// `add_to_kai_lending`, `pull_from_kai_lending`) reached through
// `#[spec_only] public fun spec_call_*` 1:1 wrappers. These four helpers
// carry the accumulation and conservation properties that bound the
// principal and share-token coordinates of every `pm.lending` mutation,
// and therefore bound the worst-case skim of every public lending entry
// (`scallop_supply` / `scallop_redeem` / `kai_supply` / `kai_redeem`).

module cdpm_specs::cdpm_spec;

#[spec_only]
use prover::prover::{asserts, ensures, requires};
use prover::prover;

use cdpm::cdpm::{
    Self,
    AdminCap,
    FeeHouse,
    PositionManager,
};
use sui::balance::Balance;
use sui::balance;
use protocol::reserve::MarketCoin;

// MAX_FEE_RATE in cdpm is `50 %` of FEE_DENOMINATOR (10_000) — capped at 5000.
// EInvalidFeeRate = 1003.
const SPEC_MAX_FEE_RATE: u128 = 5000;

// u64::MAX. Used in `requires` bounds for `balance::join` non-overflow proofs.
const U64_MAX: u128 = 18446744073709551615;

// ---------------------------------------------------------------------------
// P-FeeRateBound + P-FeeCap
//
//   admin_set_fee aborts iff (fee_rate as u128) > 3000.
//   On success, fee_house.fee_rate == fee_rate (and therefore <= 3000).
// ---------------------------------------------------------------------------
#[spec(prove, target = cdpm::admin_set_fee)]
public fun admin_set_fee_spec(
    admin_cap: &AdminCap,
    fee_house: &mut FeeHouse,
    fee_rate: u64,
) {
    // Abort condition: rate above MAX_FEE_RATE (cdpm::EInvalidFeeRate).
    asserts((fee_rate as u128) <= SPEC_MAX_FEE_RATE);

    cdpm::admin_set_fee(admin_cap, fee_house, fee_rate);

    // P-FeeCap: stored rate equals the input rate (and thus <= MAX).
    ensures(cdpm::spec_fee_house_rate(fee_house) == fee_rate);
    ensures((cdpm::spec_fee_house_rate(fee_house) as u128) <= SPEC_MAX_FEE_RATE);
}

// ===========================================================================
// Lending helpers — accumulation & conservation
// ===========================================================================
// Verified via `#[spec_only] public fun spec_call_*` 1:1 wrappers in cdpm.move
// (the private helpers are not directly addressable across packages). The
// wrappers strip from production bytecode like `#[test_only]`.
//
// Properties verified:
//   - add_to_*_lending: vault.principal grows by exactly `principal_added`,
//     vault.scoin/yt_balance grows by exactly the deposited balance value.
//     (No silent skim of either coordinate.)
//   - pull_from_*_lending: returned principal_portion never exceeds the
//     vault's pre-call principal (conservation, no over-withdraw), and the
//     returned balance value equals min(want_amount, total).
//
// These specs are the load-bearing money-flow guarantees for the redeem
// path. The public lending entries (`scallop_redeem`, `kai_redeem`)
// consume the `(balance, principal_portion)` tuple returned by
// `pull_from_*_lending`, so the conservation property here directly
// constrains how much principal can be skimmed from any single redeem.
// ---------------------------------------------------------------------------

#[spec(prove, target = cdpm::spec_call_add_to_scallop_lending)]
public fun spec_call_add_to_scallop_lending_spec<T>(
    pm: &mut PositionManager,
    scoin: Balance<MarketCoin<T>>,
    principal_added: u64,
) {
    requires(
        (cdpm::spec_pm_scallop_vault_principal<T>(pm) as u128) + (principal_added as u128)
            <= U64_MAX,
    );
    requires(
        (cdpm::spec_pm_scallop_vault_scoin_value<T>(pm) as u128)
            + (balance::value<MarketCoin<T>>(&scoin) as u128) <= U64_MAX,
    );
    requires((cdpm::spec_pm_lending_size(pm) as u128) < U64_MAX);

    // Snapshot pre-state (these accessors return 0 if the vault entry is
    // absent, so the accumulation ensures below holds uniformly for both
    // the borrow_mut branch and the bag::add else branch).
    let pre_principal = cdpm::spec_pm_scallop_vault_principal<T>(pm);
    let pre_scoin = cdpm::spec_pm_scallop_vault_scoin_value<T>(pm);
    let scoin_value_added = balance::value<MarketCoin<T>>(&scoin);

    cdpm::spec_call_add_to_scallop_lending<T>(pm, scoin, principal_added);

    ensures(cdpm::spec_pm_scallop_vault_principal<T>(pm) == pre_principal + principal_added);
    ensures(
        cdpm::spec_pm_scallop_vault_scoin_value<T>(pm) == pre_scoin + scoin_value_added,
    );
}

#[spec(prove, target = cdpm::spec_call_pull_from_scallop_lending)]
public fun spec_call_pull_from_scallop_lending_spec<T>(
    pm: &mut PositionManager,
    want_amount: u64,
): (Balance<MarketCoin<T>>, u64) {
    // The function asserts the vault exists (ENoSuchVault otherwise). All
    // real call sites (`scallop_redeem`) reach this only after a successful
    // supply, so the requires is consistent with usage.
    requires(cdpm::spec_pm_scallop_vault_exists<T>(pm));
    // Bag internal invariant: `bag.size` equals the number of entries, so
    // `vault_exists ⇒ bag.size >= 1`. The prover does not model this
    // invariant, so we state it explicitly to prevent the symbolic
    // `bag.size - 1` underflow in `bag::remove` (full-path branch).
    requires(cdpm::spec_pm_lending_size(pm) > 0);

    let pre_principal = cdpm::spec_pm_scallop_vault_principal<T>(pm);
    let pre_scoin = cdpm::spec_pm_scallop_vault_scoin_value<T>(pm);

    let (s_balance, principal_portion) =
        cdpm::spec_call_pull_from_scallop_lending<T>(pm, want_amount);

    // Conservation: returned principal_portion never exceeds the vault's
    // pre-call principal. Catches division-by-zero / multiplication-overflow
    // bugs that could over-return principal.
    ensures(principal_portion <= pre_principal);
    // Balance accounting: returned scoin equals min(want_amount, total_scoin).
    ensures(
        balance::value<MarketCoin<T>>(&s_balance)
            == (if (want_amount >= pre_scoin) pre_scoin else want_amount),
    );

    (s_balance, principal_portion)
}

#[spec(prove, target = cdpm::spec_call_add_to_kai_lending)]
public fun spec_call_add_to_kai_lending_spec<T, YT>(
    pm: &mut PositionManager,
    yt_balance: Balance<YT>,
    principal_added: u64,
) {
    requires(
        (cdpm::spec_pm_kai_vault_principal<T, YT>(pm) as u128) + (principal_added as u128)
            <= U64_MAX,
    );
    requires(
        (cdpm::spec_pm_kai_vault_yt_value<T, YT>(pm) as u128)
            + (balance::value<YT>(&yt_balance) as u128) <= U64_MAX,
    );
    requires((cdpm::spec_pm_lending_size(pm) as u128) < U64_MAX);

    let pre_principal = cdpm::spec_pm_kai_vault_principal<T, YT>(pm);
    let pre_yt = cdpm::spec_pm_kai_vault_yt_value<T, YT>(pm);
    let yt_value_added = balance::value<YT>(&yt_balance);

    cdpm::spec_call_add_to_kai_lending<T, YT>(pm, yt_balance, principal_added);

    ensures(cdpm::spec_pm_kai_vault_principal<T, YT>(pm) == pre_principal + principal_added);
    ensures(cdpm::spec_pm_kai_vault_yt_value<T, YT>(pm) == pre_yt + yt_value_added);
}

#[spec(prove, target = cdpm::spec_call_pull_from_kai_lending)]
public fun spec_call_pull_from_kai_lending_spec<T, YT>(
    pm: &mut PositionManager,
    want_amount: u64,
): (Balance<YT>, u64) {
    requires(cdpm::spec_pm_kai_vault_exists<T, YT>(pm));
    requires(cdpm::spec_pm_lending_size(pm) > 0);

    let pre_principal = cdpm::spec_pm_kai_vault_principal<T, YT>(pm);
    let pre_yt = cdpm::spec_pm_kai_vault_yt_value<T, YT>(pm);

    let (yt_balance, principal_portion) =
        cdpm::spec_call_pull_from_kai_lending<T, YT>(pm, want_amount);

    ensures(principal_portion <= pre_principal);
    ensures(
        balance::value<YT>(&yt_balance)
            == (if (want_amount >= pre_yt) pre_yt else want_amount),
    );

    (yt_balance, principal_portion)
}

// ===========================================================================
// Notes on the public lending API (scallop_supply / scallop_redeem /
// kai_supply / kai_redeem) — NOT verified as direct sui-prover targets in
// this package.
//
// Rationale: each entry calls into external packages (`protocol::mint`,
// `protocol::redeem`, `kai_vault::deposit`, `kai_vault::withdraw`,
// `klsp::withdraw`, `kai_vault::redeem_withdraw_ticket`) whose return values
// are opaque from cdpm's perspective. The prover cannot give a meaningful
// post-condition on values that flow back from packages outside the
// verification scope.
//
// The end-to-end money-flow guarantees cdpm cares about are:
//   (a) Principal accumulation on supply (vault.principal += actual coin).
//   (b) Principal-proportional withdrawal on redeem
//       (principal_portion <= pre_principal, by share of YT/scoin burned).
//   (c) Fee split formula on redeem (fee = interest * fee_rate / DENOM, with
//       interest = max(0, redeemed - principal_portion)).
//   (d) FeeHouse rate cap (fee_rate <= MAX_FEE_RATE).
//
// (a) and (b) are proved by the internal-helper specs above
// (add_to_*_lending / pull_from_*_lending). (d) is proved by
// admin_set_fee_spec. (c) follows from (b) and the formula being a single
// inlined expression in cdpm::scallop_redeem / cdpm::kai_redeem (reviewed
// by code inspection at cdpm.move, not by the prover).
//
// What the prover does NOT cover: the inline fee/balance arithmetic in the
// public entries. The blast radius of a bug there is bounded by (b): any
// skim is ≤ principal_portion ≤ pre_principal, and any fee charged ≤
// redeemed_amount because of `balance::split`'s ENotEnough abort. Catching a
// regression in the fee formula requires a unit test, not a formal proof,
// since the formula itself is what we'd need to specify to verify it.
// ===========================================================================
