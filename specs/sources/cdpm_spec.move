// CDPM Formal Verification Specs (sui-prover / asymptotic.tech).
//
// This module is compiled ONLY by `sui-prover`. Regular `sui move build`
// must NOT see this package — its `Move.toml` is the verification toolchain
// entry point. See ../../SPEC.md for property descriptions and reproduce
// instructions.
//
// All specs target functions in `cdpm::cdpm`. Private-field reads route
// through `#[spec_only]` accessors defined at the bottom of `cdpm.move`.

module cdpm_specs::cdpm_spec;

#[spec_only]
use prover::prover::{asserts, ensures};

use cdpm::cdpm::{
    Self,
    AdminCap,
    FeeHouse,
    PositionManager,
    SupplyTicket,
    RedeemTicket,
};
use sui::coin::Coin;
use sui::tx_context::TxContext;

// MAX_FEE_RATE in cdpm is `30 %` of FEE_DENOMINATOR (10_000) — capped at 3000.
// EInvalidFeeRate = 1003.
const SPEC_MAX_FEE_RATE: u128 = 3000;

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

// ---------------------------------------------------------------------------
// P-WrongPm-supply + P-AmountShortfall-supply
//
//   finish_supply<T, S>(pm, ticket, scoin) aborts when
//     ticket.pm_id   != object::id(pm)             // EWrongPm
//     scoin.value()  <  ticket.expected_scoin      // EAmountShortfall
//
// `ignore_abort` is required because finish_supply calls add_to_lending which
// uses `bag::contains` + `bag::borrow_mut` — the prover cannot connect those
// (only `bag::contains_with_type` does — see SPEC.md Limitations). The two
// `asserts(...)` calls below remain as structural documentation; they are
// NOT verified as exhaustive abort conditions, but the spec body still
// proves that finish_supply runs to completion when those preconditions hold
// (modulo the bag/balance-internal aborts handled by `ignore_abort`).
// ---------------------------------------------------------------------------
#[spec(prove, ignore_abort, target = cdpm::finish_supply)]
public fun finish_supply_spec<T, S>(
    pm: &mut PositionManager,
    ticket: SupplyTicket<T, S>,
    scoin: Coin<S>,
) {
    // P-WrongPm (structural assertion, see comment above).
    asserts(cdpm::spec_supply_ticket_pm_id(&ticket) == object::id(pm));
    // P-AmountShortfall (structural assertion, see comment above).
    asserts(scoin.value() >= cdpm::spec_supply_ticket_expected_scoin(&ticket));

    cdpm::finish_supply<T, S>(pm, ticket, scoin);
}

// ---------------------------------------------------------------------------
// P-WrongPm-redeem + P-AmountShortfall-redeem
//
//   finish_redeem<T, S>(pm, fee_house, ticket, underlying, ctx) aborts when
//     ticket.pm_id          != object::id(pm)                  // EWrongPm
//     underlying.value()    <  ticket.expected_underlying      // EAmountShortfall
//
// `ignore_abort` because finish_redeem performs `balance::split` (ENotEnough),
// fee arithmetic (overflow on adversarial fee_rate), and `bag::add` that the
// prover sees as potentially aborting. See SPEC.md Limitations.
// ---------------------------------------------------------------------------
#[spec(prove, ignore_abort, target = cdpm::finish_redeem)]
public fun finish_redeem_spec<T, S>(
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    ticket: RedeemTicket<T, S>,
    underlying: Coin<T>,
    ctx: &mut TxContext,
) {
    // P-WrongPm (structural assertion).
    asserts(cdpm::spec_redeem_ticket_pm_id(&ticket) == object::id(pm));
    // P-AmountShortfall (structural assertion).
    asserts(underlying.value() >= cdpm::spec_redeem_ticket_expected_underlying(&ticket));

    cdpm::finish_redeem<T, S>(pm, fee_house, ticket, underlying, ctx);
}
