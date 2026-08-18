// CDPM Formal Verification Specs (sui-prover / asymptotic.tech).
//
// This module is compiled ONLY by `sui-prover`. Regular `sui move build`
// must NOT see this package — its `Move.toml` is the verification toolchain
// entry point. See ../../SPEC.md for property descriptions and reproduce
// instructions.
//
// All specs target functions in `cdpm::cdpm`. Private-field reads route
// through `#[test_only]` accessors in `cdpm.move` — the official pattern
// (sui-prover SKILL.md "Private struct field access"). The chain package
// contains NO `#[spec_only]` items: that custom attribute is not stripped
// by the regular compiler, so shipping it would leak functions into
// production bytecode (see the 2026-08-18 advisory).
//
// Scope: the admin fee-rate gate.
//
// SECURITY NOTE (2026-08-18 advisory): the four lending-helper proofs that
// previously lived here were removed together with the `#[spec_only]
// public fun spec_call_*` wrappers they targeted. Those wrappers compiled
// into production bytecode as unauthenticated `&mut PositionManager` entry
// points (a Critical vulnerability). The accumulation / conservation
// properties they proved are now covered by `#[test_only]` unit tests in
// `tests/cdpm_tests.move` instead — `#[test_only]` is a Move primitive that
// the compiler strips from production builds, unlike the custom
// `#[spec_only]` attribute. See SPEC.md.

module cdpm_specs::cdpm_spec;

#[spec_only]
use prover::prover::{asserts, ensures, requires};
use prover::prover;

use cdpm::cdpm::{
    Self,
    AdminCap,
    FeeHouse,
};

// MAX_FEE_RATE in cdpm is `50 %` of FEE_DENOMINATOR (10_000) — capped at 5000.
// EInvalidFeeRate = 1003.
const SPEC_MAX_FEE_RATE: u128 = 5000;

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
    ensures(cdpm::test_only_fee_house_rate(fee_house) == fee_rate);
    ensures((cdpm::test_only_fee_house_rate(fee_house) as u128) <= SPEC_MAX_FEE_RATE);
}
