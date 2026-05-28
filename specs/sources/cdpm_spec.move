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
use prover::prover::{asserts, ensures, requires};
use prover::prover;

use cdpm::cdpm::{
    Self,
    AccessList,
    AdminCap,
    FeeHouse,
    PositionManager,
    ScallopSupplyTicket,
    ScallopRedeemTicket,
    KaiSupplyTicket,
    KaiRedeemTicket,
};
use sui::coin::Coin;
use sui::balance::Balance;
use sui::tx_context::TxContext;
use sui::object;
use sui::clock::Clock;
use sui::balance;
use protocol::market::Market;
use protocol::reserve::MarketCoin;
use kai_sav::vault as kai_vault;

// MAX_FEE_RATE in cdpm is `30 %` of FEE_DENOMINATOR (10_000) — capped at 3000.
// EInvalidFeeRate = 1003.
const SPEC_MAX_FEE_RATE: u128 = 3000;

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
// `add_to_scallop_lending` was migrated from `bag::contains<K>` + `bag::borrow_mut<K, V>`
// to `bag::contains_with_type<K, V>` so the prover can associate the existence
// check with the subsequent borrow — full abort proof is now in scope, and
// `ignore_abort` is no longer needed.
// ---------------------------------------------------------------------------
#[spec(prove, target = cdpm::scallop_finish_supply)]
public fun scallop_finish_supply_spec<T>(
    pm: &mut PositionManager,
    market: &Market,
    ticket: ScallopSupplyTicket<T>,
    scoin: Coin<MarketCoin<T>>,
) {
    // Realistic-flow preconditions: `*_start_supply` clamps `ticket.principal`
    // and `scoin.value()` to the user's actual coin balance, never u64::MAX —
    // see skills/cdpm-calculation-skill/reference/cross-protocol-ptb.md. The
    // prover can construct adversarial unbounded inputs without these.
    requires(
        (cdpm::spec_pm_scallop_vault_principal<T>(pm) as u128)
            + (cdpm::spec_scallop_supply_ticket_principal<T>(&ticket) as u128)
            <= U64_MAX,
    );
    requires(
        (cdpm::spec_pm_scallop_vault_scoin_value<T>(pm) as u128) + (scoin.value() as u128)
            <= U64_MAX,
    );
    // `add_to_scallop_lending`'s else-branch calls `bag::add`, which increments
    // `pm.lending.size` (u64). Bounded by the number of distinct coin types
    // ever supplied through this PM — finite in any real deployment.
    requires((cdpm::spec_pm_lending_size(pm) as u128) < U64_MAX);

    // P-WrongPm (structural assertion, see comment above).
    asserts(cdpm::spec_scallop_supply_ticket_pm_id(&ticket) == object::id(pm));
    // P-WrongMarket (F-03 canonical-object binding).
    asserts(cdpm::spec_scallop_supply_ticket_market_id(&ticket) == object::id(market));
    // P-AmountShortfall (structural assertion, see comment above).
    asserts(scoin.value() >= cdpm::spec_scallop_supply_ticket_expected_scoin(&ticket));

    // Snapshot pre-state for the post-condition ensures (ticket is moved into
    // the call below, so capture its principal up front).
    let pre_principal = cdpm::spec_pm_scallop_vault_principal<T>(pm);
    let pre_scoin_value = cdpm::spec_pm_scallop_vault_scoin_value<T>(pm);
    let ticket_principal = cdpm::spec_scallop_supply_ticket_principal<T>(&ticket);
    let scoin_value_in = scoin.value();

    cdpm::scallop_finish_supply<T>(pm, market, ticket, scoin);

    // Post-state correctness — accumulation: vault.principal and vault.scoin
    // grow by exactly the ticket-recorded principal and the deposited scoin
    // value. No silent skim of either coordinate.
    ensures(cdpm::spec_pm_scallop_vault_principal<T>(pm) == pre_principal + ticket_principal);
    ensures(cdpm::spec_pm_scallop_vault_scoin_value<T>(pm) == pre_scoin_value + scoin_value_in);
}

// ---------------------------------------------------------------------------
// P-WrongPm-redeem + P-AmountShortfall-redeem
//
//   scallop_finish_redeem<T>(pm, fee_house, ticket, underlying, ctx) aborts when
//     ticket.pm_id          != object::id(pm)                            // EWrongPm
//     ticket.expected_underlying - underlying.value() > REDEEM_DUST_TOLERANCE_RAW
//                                                                        // EAmountShortfall
//
// The shortfall assert tolerates up to REDEEM_DUST_TOLERANCE_RAW raw of
// floor-div dust between the cdpm-side single-floor `expected_underlying`
// and the protocol redeem path's actual output (see cdpm.move comment on
// REDEEM_DUST_TOLERANCE_RAW). Spec mirrors the on-chain guard:
// `expected <= redeemed || expected - redeemed <= TOL` is the precondition
// under which EAmountShortfall does not fire.
//
// `bag::contains` → `bag::contains_with_type` migration in `add_to_balance` /
// `add_to_fee` / `deposit_into_fee_house` lets the prover connect the existence
// check with the subsequent borrow. The remaining aborts (`balance::split` on
// fee_amount > principal, fee arithmetic overflow) are bounded by the spec
// preconditions and the cdpm-enforced `MAX_FEE_RATE` cap.
// ---------------------------------------------------------------------------
#[spec(prove, target = cdpm::scallop_finish_redeem)]
public fun scallop_finish_redeem_spec<T>(
    pm: &mut PositionManager,
    market: &Market,
    fee_house: &mut FeeHouse,
    ticket: ScallopRedeemTicket<T>,
    underlying: Coin<T>,
    ctx: &mut TxContext,
) {
    // Soundness chain for this requires:
    //   1. `FeeHouse` has a single construction site: `init` (cdpm.move:375),
    //      which hardcodes `fee_rate: 2000` and runs once at module publish
    //      (Sui Move privileged initializer — cannot be invoked post-deploy).
    //   2. `FeeHouse.fee_rate` is private; the only mutator is `admin_set_fee`,
    //      which `admin_set_fee_spec` (also a target of this verification run)
    //      proves aborts on `fee_rate > MAX_FEE_RATE = 3000`.
    //   3. Move's privacy rules + struct field privacy guarantee no other path
    //      can produce a `FeeHouse` with `fee_rate > 3000`.
    // Required here so the prover can show `fee_amount <= 0.3 * interest <
    // underlying.value()` and that `balance::split(fee_amount)` does not
    // abort with ENotEnough.
    requires(cdpm::spec_fee_house_rate(fee_house) <= cdpm::spec_max_fee_rate());
    // `deposit_into_fee_house` joins the fee balance into `fee_house.fee[T]`.
    // fee_amount <= underlying.value(), so this bound covers it.
    requires(
        (cdpm::spec_fee_house_balance_value<T>(fee_house) as u128) + (underlying.value() as u128)
            <= U64_MAX,
    );
    // `add_to_balance` joins the post-fee remainder into `pm.balance[T]`. The
    // remainder is `underlying.value() - fee_amount <= underlying.value()`, so
    // this bound covers the join non-overflow.
    requires(
        (cdpm::spec_pm_balance_value<T>(pm) as u128) + (underlying.value() as u128) <= U64_MAX,
    );
    // Bag-size guards for `bag::add` (else-branches in `deposit_into_fee_house`
    // and `add_to_balance`).
    requires((cdpm::spec_fee_house_size(fee_house) as u128) < U64_MAX);
    requires((cdpm::spec_pm_balance_size(pm) as u128) < U64_MAX);

    // P-WrongPm (structural assertion).
    asserts(cdpm::spec_scallop_redeem_ticket_pm_id(&ticket) == object::id(pm));
    // P-WrongMarket (F-03 canonical-object binding).
    asserts(cdpm::spec_scallop_redeem_ticket_market_id(&ticket) == object::id(market));
    // P-AmountShortfall (structural assertion, mirrors the on-chain guarded subtraction).
    let expected = cdpm::spec_scallop_redeem_ticket_expected_underlying(&ticket);
    let redeemed = underlying.value();
    asserts(expected <= redeemed || expected - redeemed <= cdpm::spec_redeem_dust_tolerance_raw());

    // Snapshot pre-state + predict the fee that the on-chain formula will
    // charge. fee_amount = (interest * fee_rate) / FEE_DENOMINATOR when
    // redeemed > principal_portion, else 0. Mirrors cdpm.move:1552-1563.
    let pre_pm_balance = cdpm::spec_pm_balance_value<T>(pm);
    let pre_fee_house_balance = cdpm::spec_fee_house_balance_value<T>(fee_house);
    let principal_portion = cdpm::spec_scallop_redeem_ticket_principal_portion<T>(&ticket);
    let fee_rate = cdpm::spec_fee_house_rate(fee_house);
    let predicted_fee = if (redeemed > principal_portion) {
        (((redeemed - principal_portion) as u128) * (fee_rate as u128) / 10000) as u64
    } else { 0 };

    cdpm::scallop_finish_redeem<T>(pm, market, fee_house, ticket, underlying, ctx);

    // Post-state correctness: the on-chain split must match the predicted
    // formula exactly. Together with the principal_portion conservation
    // proved in `spec_call_pull_from_scallop_lending_spec` (start_redeem
    // upstream), these ensures bind the entire redeem money-flow to the
    // documented fee model.
    ensures(
        cdpm::spec_fee_house_balance_value<T>(fee_house) == pre_fee_house_balance + predicted_fee,
    );
    ensures(
        cdpm::spec_pm_balance_value<T>(pm) == pre_pm_balance + redeemed - predicted_fee,
    );
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
// `add_to_kai_lending` was migrated to `bag::contains_with_type` — same as
// the Scallop `finish_supply_spec` — so full abort proof is in scope.
// ---------------------------------------------------------------------------
#[spec(prove, target = cdpm::kai_finish_supply)]
public fun kai_finish_supply_spec<T, YT>(
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    ticket: KaiSupplyTicket<T, YT>,
    yt: Coin<YT>,
) {
    // Realistic-flow preconditions: mirror of scallop_finish_supply_spec —
    // `kai_start_supply` clamps `ticket.principal` and `yt.value()` to actual
    // coin balances, not u64::MAX (see cross-protocol-ptb.md).
    requires(
        (cdpm::spec_pm_kai_vault_principal<T, YT>(pm) as u128)
            + (cdpm::spec_kai_supply_ticket_principal<T, YT>(&ticket) as u128)
            <= U64_MAX,
    );
    requires(
        (cdpm::spec_pm_kai_vault_yt_value<T, YT>(pm) as u128) + (yt.value() as u128)
            <= U64_MAX,
    );
    requires((cdpm::spec_pm_lending_size(pm) as u128) < U64_MAX);

    asserts(cdpm::spec_kai_supply_ticket_pm_id(&ticket) == object::id(pm));
    asserts(cdpm::spec_kai_supply_ticket_vault_id(&ticket) == object::id(vault));
    asserts(yt.value() >= cdpm::spec_kai_supply_ticket_expected_yt(&ticket));

    let pre_principal = cdpm::spec_pm_kai_vault_principal<T, YT>(pm);
    let pre_yt_value = cdpm::spec_pm_kai_vault_yt_value<T, YT>(pm);
    let ticket_principal = cdpm::spec_kai_supply_ticket_principal<T, YT>(&ticket);
    let yt_value_in = yt.value();

    cdpm::kai_finish_supply<T, YT>(pm, vault, ticket, yt);

    ensures(cdpm::spec_pm_kai_vault_principal<T, YT>(pm) == pre_principal + ticket_principal);
    ensures(cdpm::spec_pm_kai_vault_yt_value<T, YT>(pm) == pre_yt_value + yt_value_in);
}

// ---------------------------------------------------------------------------
// P-Kai-WrongPm-redeem + P-Kai-AmountShortfall-redeem
//
//   kai_finish_redeem<T, YT>(pm, fee_house, ticket, underlying, ctx) aborts:
//     ticket.pm_id          != object::id(pm)                              // EWrongPm
//     ticket.expected_underlying - underlying.value() > REDEEM_DUST_TOLERANCE_RAW
//                                                                          // EAmountShortfall
//
// The shortfall assert tolerates up to REDEEM_DUST_TOLERANCE_RAW raw of
// floor-div dust between cdpm's single-floor `expected_underlying` and the
// multi-floor strategy-walker output (see cdpm.move). Spec mirrors the
// on-chain guard.
//
// `bag::contains_with_type` migration mirrors `scallop_finish_redeem_spec`;
// `ignore_abort` no longer needed.
// ---------------------------------------------------------------------------
#[spec(prove, target = cdpm::kai_finish_redeem)]
public fun kai_finish_redeem_spec<T, YT>(
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    fee_house: &mut FeeHouse,
    ticket: KaiRedeemTicket<T, YT>,
    underlying: Coin<T>,
    ctx: &mut TxContext,
) {
    // Mirror of scallop_finish_redeem_spec — same fee_amount <= 0.3 * interest
    // reasoning, same fee_house / pm.balance join non-overflow bounds.
    requires(cdpm::spec_fee_house_rate(fee_house) <= cdpm::spec_max_fee_rate());
    requires(
        (cdpm::spec_fee_house_balance_value<T>(fee_house) as u128) + (underlying.value() as u128)
            <= U64_MAX,
    );
    requires(
        (cdpm::spec_pm_balance_value<T>(pm) as u128) + (underlying.value() as u128) <= U64_MAX,
    );
    requires((cdpm::spec_fee_house_size(fee_house) as u128) < U64_MAX);
    requires((cdpm::spec_pm_balance_size(pm) as u128) < U64_MAX);

    asserts(cdpm::spec_kai_redeem_ticket_pm_id(&ticket) == object::id(pm));
    asserts(cdpm::spec_kai_redeem_ticket_vault_id(&ticket) == object::id(vault));
    let expected = cdpm::spec_kai_redeem_ticket_expected_underlying(&ticket);
    let redeemed = underlying.value();
    asserts(expected <= redeemed || expected - redeemed <= cdpm::spec_redeem_dust_tolerance_raw());

    // Mirror of scallop_finish_redeem_spec — same fee formula.
    let pre_pm_balance = cdpm::spec_pm_balance_value<T>(pm);
    let pre_fee_house_balance = cdpm::spec_fee_house_balance_value<T>(fee_house);
    let principal_portion = cdpm::spec_kai_redeem_ticket_principal_portion<T, YT>(&ticket);
    let fee_rate = cdpm::spec_fee_house_rate(fee_house);
    let predicted_fee = if (redeemed > principal_portion) {
        (((redeemed - principal_portion) as u128) * (fee_rate as u128) / 10000) as u64
    } else { 0 };

    cdpm::kai_finish_redeem<T, YT>(pm, vault, fee_house, ticket, underlying, ctx);

    ensures(
        cdpm::spec_fee_house_balance_value<T>(fee_house) == pre_fee_house_balance + predicted_fee,
    );
    ensures(
        cdpm::spec_pm_balance_value<T>(pm) == pre_pm_balance + redeemed - predicted_fee,
    );
}

// ===========================================================================
// *_start_* — ticket construction correctness
// ===========================================================================
// Properties verified for each `*_start_*`:
//   - ticket.pm_id / market_id / vault_id bound to the input object
//     (F-03 canonical-object binding originates here).
//   - ticket.principal (supply) / scoin_burned (redeem) / yt_burned (redeem)
//     matches the value of the coin/balance the caller receives — no skim.
//   - ticket.expected_* > 0 (the on-chain EZeroExpected guard).
//
// `ignore_abort` is used: start_* aborts on many non-target paths (auth fail,
// stale oracle, empty pm.balance, reserve_empty, ZeroExpected, intermediate
// u64-cast overflow in compute_expected_*). Enumerating them all adds no
// security signal for the construction-correctness properties above.
//
// Intentionally NOT verified here: formula equivalence
// `ticket.expected_* == compute_expected_*(market/vault, ...)`. Such an
// ensures would be circular (the function literally assigns this value, so
// the equality is trivially true), and the only way to make it meaningful is
// to write an independent axiomatic spec for `compute_expected_*` against
// `market`/`vault` internal state — separate work item.
// ---------------------------------------------------------------------------

#[spec(prove, ignore_abort, target = cdpm::scallop_start_supply)]
public fun scallop_start_supply_spec<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    market: &Market,
    clock: &Clock,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<T>, ScallopSupplyTicket<T>) {
    let (coin, ticket) = cdpm::scallop_start_supply<T>(access, pm, market, clock, amount, ctx);

    // Ticket binding: pm_id / market_id pin the ticket to the exact objects
    // observed during construction (the finish_* spec then verifies the
    // ticket is replayed against the same objects — together they prove
    // F-03 canonical-object binding end-to-end).
    ensures(cdpm::spec_scallop_supply_ticket_pm_id(&ticket) == object::id(pm));
    ensures(cdpm::spec_scallop_supply_ticket_market_id(&ticket) == object::id(market));
    // Principal == actual coin value returned (no skim, no rounding).
    ensures(cdpm::spec_scallop_supply_ticket_principal<T>(&ticket) == coin.value());
    // EZeroExpected guard — if it returned, expected_scoin > 0.
    ensures(cdpm::spec_scallop_supply_ticket_expected_scoin(&ticket) > 0);

    (coin, ticket)
}

#[spec(prove, ignore_abort, target = cdpm::scallop_start_redeem)]
public fun scallop_start_redeem_spec<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    market: &Market,
    clock: &Clock,
    market_coin_amount: u64,
    ctx: &mut TxContext,
): (Coin<MarketCoin<T>>, ScallopRedeemTicket<T>) {
    let (scoin, ticket) =
        cdpm::scallop_start_redeem<T>(access, pm, market, clock, market_coin_amount, ctx);

    ensures(cdpm::spec_scallop_redeem_ticket_pm_id(&ticket) == object::id(pm));
    ensures(cdpm::spec_scallop_redeem_ticket_market_id(&ticket) == object::id(market));
    // scoin_burned == returned scoin value (the redeem ticket records exactly
    // what the caller is asked to repay; mismatch would let the finish_*
    // bookkeeping diverge from the actual coin volume).
    ensures(cdpm::spec_scallop_redeem_ticket_scoin_burned<T>(&ticket) == scoin.value());
    ensures(cdpm::spec_scallop_redeem_ticket_expected_underlying(&ticket) > 0);

    (scoin, ticket)
}

#[spec(prove, ignore_abort, target = cdpm::kai_start_supply)]
public fun kai_start_supply_spec<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<T>, KaiSupplyTicket<T, YT>) {
    let (coin, ticket) =
        cdpm::kai_start_supply<T, YT>(access, pm, vault, amount, clock, ctx);

    ensures(cdpm::spec_kai_supply_ticket_pm_id(&ticket) == object::id(pm));
    ensures(cdpm::spec_kai_supply_ticket_vault_id(&ticket) == object::id(vault));
    ensures(cdpm::spec_kai_supply_ticket_principal<T, YT>(&ticket) == coin.value());
    ensures(cdpm::spec_kai_supply_ticket_expected_yt(&ticket) > 0);

    (coin, ticket)
}

#[spec(prove, ignore_abort, target = cdpm::kai_start_redeem)]
public fun kai_start_redeem_spec<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    yt_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<YT>, KaiRedeemTicket<T, YT>) {
    let (yt, ticket) =
        cdpm::kai_start_redeem<T, YT>(access, pm, vault, yt_amount, clock, ctx);

    ensures(cdpm::spec_kai_redeem_ticket_pm_id(&ticket) == object::id(pm));
    ensures(cdpm::spec_kai_redeem_ticket_vault_id(&ticket) == object::id(vault));
    ensures(cdpm::spec_kai_redeem_ticket_yt_burned<T, YT>(&ticket) == yt.value());
    ensures(cdpm::spec_kai_redeem_ticket_expected_underlying(&ticket) > 0);

    (yt, ticket)
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
// Bag-size and overflow `requires` mirror the finish_*_spec patterns.
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
    // real call sites (`scallop_start_redeem`) reach this only after a
    // successful supply, so the requires is consistent with usage.
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
// compute_expected_* — formula correctness
// ===========================================================================
// Verified via #[spec_only] public fun spec_call_compute_expected_*` 1:1
// wrappers in cdpm.move.
//
// Two classes of property per function:
//   1. Bootstrap / zero-input: structurally simple post-conditions that
//      catch high-impact regressions (e.g., broken first-deposit handling).
//   2. Formula equivalence under no-overflow guards: result equals the
//      documented Scallop/Kai pricing formula. Catches refactor bugs where
//      cdpm picks wrong field, flips numerator/denominator, or reads the
//      wrong balance sheet entry.
//
// The compute_expected_* functions abort on (a) missing balance sheet for T,
// (b) cash+debt < revenue, (c) denom == 0, (d) u64 cast overflow. We do NOT
// `ignore_abort`; instead we add `requires(...)` for each non-target abort
// condition so the prover can prove the function returns under the spec
// preconditions and that the returned value matches the formula.
// ---------------------------------------------------------------------------

#[spec(prove, target = cdpm::spec_call_compute_expected_scoin)]
public fun spec_call_compute_expected_scoin_spec<T>(market: &Market, coin_amount: u64): u64 {
    // Sheet for T must exist; otherwise `wit_table::borrow` aborts.
    requires(cdpm::spec_scallop_market_sheet_exists<T>(market));

    let supply = cdpm::spec_scallop_market_supply<T>(market);
    let cash = cdpm::spec_scallop_market_cash<T>(market);
    let debt = cdpm::spec_scallop_market_debt<T>(market);
    let revenue = cdpm::spec_scallop_market_revenue<T>(market);

    // Non-bootstrap branch needs the function's own asserts to hold, the
    // intermediate u128 product to not overflow, and the final u64 cast to
    // fit. Single `requires` with `&&` short-circuit avoids eager-eval
    // division-by-zero when supply == 0 (bootstrap branch).
    //
    // The `<= U64_MAX` bound on `(cash + debt - revenue)` reflects Scallop's
    // real-world reserve invariant (reserve value per sCoin can't exceed the
    // u64 token supply); without it `coin_amount * (cash + debt - revenue)`
    // can overflow u128 in adversarial states.
    requires(
        supply == 0
            || (
                (cash as u128) + (debt as u128) >= (revenue as u128)
                    && (cash as u128) + (debt as u128) - (revenue as u128) > 0
                    && (cash as u128) + (debt as u128) - (revenue as u128) <= U64_MAX
                    && (coin_amount as u128) * (supply as u128)
                        / ((cash as u128) + (debt as u128) - (revenue as u128))
                        <= U64_MAX
            ),
    );

    let result = cdpm::spec_call_compute_expected_scoin<T>(market, coin_amount);

    // P1 — Bootstrap: when no sCoin has been minted, mint 1:1.
    // Written as `||` not `prover::implies(...)` so Move's short-circuit
    // evaluation avoids evaluating the divisor-bearing branch when supply==0.
    ensures(supply != 0 || result == coin_amount);
    // P2 — Formula match: result == coin_amount * supply / (cash + debt - revenue).
    // Same short-circuit reason: when supply == 0, denom may also be 0 and
    // eager evaluation of the RHS would division-by-zero abort.
    ensures(
        supply == 0
            || (result as u128)
                == (coin_amount as u128) * (supply as u128)
                / ((cash as u128) + (debt as u128) - (revenue as u128)),
    );

    result
}

#[spec(prove, target = cdpm::spec_call_compute_expected_underlying_scallop)]
public fun spec_call_compute_expected_underlying_scallop_spec<T>(
    market: &Market,
    scoin_amount: u64,
): u64 {
    requires(cdpm::spec_scallop_market_sheet_exists<T>(market));

    let supply = cdpm::spec_scallop_market_supply<T>(market);
    let cash = cdpm::spec_scallop_market_cash<T>(market);
    let debt = cdpm::spec_scallop_market_debt<T>(market);
    let revenue = cdpm::spec_scallop_market_revenue<T>(market);

    // Function asserts supply > 0 (no bootstrap on redeem) and
    // cash + debt >= revenue. The cast bound mirrors the supply path.
    // Single `requires` with `&&` short-circuit so that when supply == 0 the
    // division `/ supply` in the cast bound is never eagerly evaluated. The
    // `<= U64_MAX` on `(cash + debt - revenue)` reflects Scallop's reserve
    // invariant (see compute_expected_scoin spec).
    requires(
        supply > 0
            && (cash as u128) + (debt as u128) >= (revenue as u128)
            && (cash as u128) + (debt as u128) - (revenue as u128) <= U64_MAX
            && (scoin_amount as u128)
                * ((cash as u128) + (debt as u128) - (revenue as u128))
                / (supply as u128) <= U64_MAX,
    );

    let result = cdpm::spec_call_compute_expected_underlying_scallop<T>(market, scoin_amount);

    // Formula: result == scoin_amount * (cash + debt - revenue) / supply.
    ensures(
        (result as u128)
            == (scoin_amount as u128)
                * ((cash as u128) + (debt as u128) - (revenue as u128))
                / (supply as u128),
    );

    result
}

// ----------------------------------------------------------------------------
// Kai `compute_expected_*` — DELIBERATELY NOT VERIFIED in this package.
//
// Rationale: `kai_vault::total_available_balance` (vault.move:301) aggregates
// `strategy_state.borrowed` across all registered strategies in a VecMap,
// surfacing a u64 sum that the prover sees as potentially overflowing. To
// `requires` away this abort path we would need to expose every
// `StrategyState.borrowed` field and prove their sum bounded — that involves
// reasoning over an unbounded VecMap, well beyond cdpm's verification scope
// (the strategies live in the Kai SAV package; correctness of their
// accounting is Kai's responsibility, not ours).
//
// The end-to-end property cdpm cares about — "the value cdpm records on the
// ticket equals what Kai actually pays out" — is verified upstream by the
// `kai_start_*_spec` ensures (`ticket.expected_yt > 0`, `ticket.yt_burned ==
// yt.value()`, etc.) plus the `kai_finish_*_spec` shortfall asserts. Together
// these guarantee that whatever `compute_expected_yt` / `compute_expected_
// underlying_kai` returns is faithfully passed through, even if the formula
// itself is verified by Kai upstream rather than us.
// ----------------------------------------------------------------------------
