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
    ScallopSupplyTicket,
    ScallopRedeemTicket,
    KaiSupplyTicket,
    KaiRedeemTicket,
};
use sui::coin::Coin;
use sui::tx_context::TxContext;
use protocol::reserve::MarketCoin;

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
//   scallop_finish_supply<T>(pm, ticket, scoin) aborts when
//     ticket.pm_id   != object::id(pm)             // EWrongPm
//     scoin.value()  <  ticket.expected_scoin      // EAmountShortfall
//
// Note (post Option D): `S` was removed from the public surface; sCoin type
// is now structurally pinned to `protocol::reserve::MarketCoin<T>` by the
// type system. The fake-S extraction vector that motivated separate ticket
// audits no longer exists; both asserts below are now type-safe.
//
// `ignore_abort` is still required because scallop_finish_supply calls add_to_scallop_lending
// which uses `bag::contains` + `bag::borrow_mut` — the prover cannot connect
// those (only `bag::contains_with_type` does — see SPEC.md Limitations).
// ---------------------------------------------------------------------------
#[spec(prove, ignore_abort, target = cdpm::scallop_finish_supply)]
public fun scallop_finish_supply_spec<T>(
    pm: &mut PositionManager,
    ticket: ScallopSupplyTicket<T>,
    scoin: Coin<MarketCoin<T>>,
) {
    // P-WrongPm (structural assertion, see comment above).
    asserts(cdpm::spec_scallop_supply_ticket_pm_id(&ticket) == object::id(pm));
    // P-AmountShortfall (structural assertion, see comment above).
    asserts(scoin.value() >= cdpm::spec_scallop_supply_ticket_expected_scoin(&ticket));

    cdpm::scallop_finish_supply<T>(pm, ticket, scoin);
}

// ---------------------------------------------------------------------------
// P-WrongPm-redeem + P-AmountShortfall-redeem
//
//   scallop_finish_redeem<T>(pm, fee_house, ticket, underlying, ctx) aborts when
//     ticket.pm_id          != object::id(pm)                  // EWrongPm
//     underlying.value()    <  ticket.expected_underlying      // EAmountShortfall
//
// `ignore_abort` because scallop_finish_redeem performs `balance::split` (ENotEnough),
// fee arithmetic (overflow on adversarial fee_rate), and `bag::add` that the
// prover sees as potentially aborting. See SPEC.md Limitations.
// ---------------------------------------------------------------------------
#[spec(prove, ignore_abort, target = cdpm::scallop_finish_redeem)]
public fun scallop_finish_redeem_spec<T>(
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    ticket: ScallopRedeemTicket<T>,
    underlying: Coin<T>,
    ctx: &mut TxContext,
) {
    // P-WrongPm (structural assertion).
    asserts(cdpm::spec_scallop_redeem_ticket_pm_id(&ticket) == object::id(pm));
    // P-AmountShortfall (structural assertion).
    asserts(underlying.value() >= cdpm::spec_scallop_redeem_ticket_expected_underlying(&ticket));

    cdpm::scallop_finish_redeem<T>(pm, fee_house, ticket, underlying, ctx);
}

// ---------------------------------------------------------------------------
// P-Kai-WrongPm-supply + P-Kai-AmountShortfall-supply
//
//   kai_finish_supply<T, YT>(pm, ticket, yt) aborts when
//     ticket.pm_id  != object::id(pm)            // EWrongPm
//     yt.value()    <  ticket.expected_yt        // EAmountShortfall
//
// `YT` is structurally pinned by Kai SAV's `lp_treasury: TreasuryCap<YT>`
// (vault.move): only the Kai vault module can mint `Coin<YT>`. cdpm need not
// (and does not) verify pool identity beyond Move's type system, since
// `kai_sav::vault::new` is `public(package)` (vault.move:235), so external
// code cannot publish a `Vault<T, YT>` shared object with attacker-controlled
// YT.
//
// `ignore_abort` for the same `bag::contains` + `bag::borrow_mut` reason as
// the Scallop `finish_supply_spec`. See SPEC.md Limitations.
// ---------------------------------------------------------------------------
#[spec(prove, ignore_abort, target = cdpm::kai_finish_supply)]
public fun kai_finish_supply_spec<T, YT>(
    pm: &mut PositionManager,
    ticket: KaiSupplyTicket<T, YT>,
    yt: Coin<YT>,
) {
    asserts(cdpm::spec_kai_supply_ticket_pm_id(&ticket) == object::id(pm));
    asserts(yt.value() >= cdpm::spec_kai_supply_ticket_expected_yt(&ticket));

    cdpm::kai_finish_supply<T, YT>(pm, ticket, yt);
}

// ---------------------------------------------------------------------------
// P-Kai-WrongPm-redeem + P-Kai-AmountShortfall-redeem
//
//   kai_finish_redeem<T, YT>(pm, fee_house, ticket, underlying, ctx) aborts:
//     ticket.pm_id          != object::id(pm)              // EWrongPm
//     underlying.value()    <  ticket.expected_underlying  // EAmountShortfall
// ---------------------------------------------------------------------------
#[spec(prove, ignore_abort, target = cdpm::kai_finish_redeem)]
public fun kai_finish_redeem_spec<T, YT>(
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    ticket: KaiRedeemTicket<T, YT>,
    underlying: Coin<T>,
    ctx: &mut TxContext,
) {
    asserts(cdpm::spec_kai_redeem_ticket_pm_id(&ticket) == object::id(pm));
    asserts(underlying.value() >= cdpm::spec_kai_redeem_ticket_expected_underlying(&ticket));

    cdpm::kai_finish_redeem<T, YT>(pm, fee_house, ticket, underlying, ctx);
}
