// CDPM Admin Emergency Return Unit Tests
//
// Exercises the admin escape-hatch surface (asset evacuation on the
// "upgrade incompatible" path): the `admin_force_return_*` /
// `admin_force_close_pm` functions plus `user_remove_record_entry`.
//
// These functions are gated by `&AdminCap` (structural: only the holder of
// the real AdminCap object can pass a reference) and always route assets to
// `pm.owner`. Tests construct throwaway AdminCap / Record / PM objects via
// the `#[test_only]` factories in `cdpm.move` (which the compiler strips
// from production — `AdminCap` / `Record` have module-private fields under
// Move 2024 field visibility, so external construction is impossible).
//
// The Scallop / Kai escape-hatch functions (`admin_force_return_scallop` /
// `admin_force_return_kai`) cross into `redeem::redeem` / the Kai vault
// withdrawal chain, so — like `scallop_redeem` / `kai_redeem` — they are not
// unit-tested here.

module cdpm::cdpm_admin_tests;

use cdpm::cdpm::{
    EBalanceNotEmpty,
    ENoPosition,
    ENoSuchRecordEntry,
    admin_force_close_pm,
    admin_force_return_balance,
    admin_force_return_fee,
    admin_force_return_position,
    test_only_add_record_entry,
    test_only_add_to_balance,
    test_only_add_to_fee,
    test_only_balance_value,
    test_only_destroy_admin_cap,
    test_only_destroy_pm,
    test_only_destroy_record,
    test_only_fee_value,
    test_only_new_admin_cap,
    test_only_new_pm,
    test_only_new_record,
    test_only_record_contains,
    user_remove_record_entry,
};
use sui::coin;

// Fake coin type for the plain balance / fee return tests.
public struct FakeCoin has drop {}

// ===========================================================================
// admin_force_return_balance / _fee — drain the bag to pm.owner
// ===========================================================================

#[test]
fun admin_force_return_balance_drains_balance() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = test_only_new_admin_cap(ctx);
    let mut pm = test_only_new_pm(ctx);

    let coin = coin::mint_for_testing<FakeCoin>(100, ctx);
    test_only_add_to_balance(&mut pm, coin);
    assert!(test_only_balance_value<FakeCoin>(&pm) == 100, 1);

    admin_force_return_balance<FakeCoin>(&admin_cap, &mut pm, ctx);
    assert!(test_only_balance_value<FakeCoin>(&pm) == 0, 2);

    test_only_destroy_pm(pm);
    test_only_destroy_admin_cap(admin_cap);
}

#[test]
fun admin_force_return_fee_drains_fee() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = test_only_new_admin_cap(ctx);
    let mut pm = test_only_new_pm(ctx);

    let coin = coin::mint_for_testing<FakeCoin>(50, ctx);
    test_only_add_to_fee(&mut pm, coin);
    assert!(test_only_fee_value<FakeCoin>(&pm) == 50, 1);

    admin_force_return_fee<FakeCoin>(&admin_cap, &mut pm, ctx);
    assert!(test_only_fee_value<FakeCoin>(&pm) == 0, 2);

    test_only_destroy_pm(pm);
    test_only_destroy_admin_cap(admin_cap);
}

// ===========================================================================
// admin_force_return_position — aborts when no Position is held
// ===========================================================================

#[test, expected_failure(abort_code = ENoPosition, location = cdpm::cdpm)]
fun admin_force_return_position_aborts_when_no_position() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = test_only_new_admin_cap(ctx);
    let mut pm = test_only_new_pm(ctx); // position is None
    admin_force_return_position(&admin_cap, &mut pm);
    // unreachable cleanup (satisfies non-drop resource consumption):
    test_only_destroy_pm(pm);
    test_only_destroy_admin_cap(admin_cap);
}

// ===========================================================================
// admin_force_close_pm — safety asserts + successful teardown
// ===========================================================================

#[test, expected_failure(abort_code = EBalanceNotEmpty, location = cdpm::cdpm)]
fun admin_force_close_pm_aborts_on_nonempty_balance() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = test_only_new_admin_cap(ctx);
    let mut pm = test_only_new_pm(ctx);

    let coin = coin::mint_for_testing<FakeCoin>(100, ctx);
    test_only_add_to_balance(&mut pm, coin);

    admin_force_close_pm(&admin_cap, pm);
    // unreachable cleanup (satisfies non-drop resource consumption):
    test_only_destroy_admin_cap(admin_cap);
}

#[test]
fun admin_force_close_pm_succeeds_when_empty() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = test_only_new_admin_cap(ctx);
    let pm = test_only_new_pm(ctx); // position None, bags empty

    admin_force_close_pm(&admin_cap, pm);

    test_only_destroy_admin_cap(admin_cap);
}

// ===========================================================================
// user_remove_record_entry — owner clears a stale index entry
// ===========================================================================

#[test]
fun user_remove_record_entry_removes_id() {
    let ctx = &mut tx_context::dummy();
    let pm_id = object::id_from_address(@0x0);

    let mut rec = test_only_new_record(ctx);
    test_only_add_record_entry(&mut rec, pm_id);
    assert!(test_only_record_contains(&rec, pm_id), 1);

    user_remove_record_entry(&mut rec, pm_id);
    assert!(!test_only_record_contains(&rec, pm_id), 2);

    test_only_destroy_record(rec);
}

#[test, expected_failure(abort_code = ENoSuchRecordEntry, location = cdpm::cdpm)]
fun user_remove_record_entry_aborts_on_absent_id() {
    let ctx = &mut tx_context::dummy();
    let pm_id = object::id_from_address(@0x0);

    let mut rec = test_only_new_record(ctx);
    user_remove_record_entry(&mut rec, pm_id);
    // unreachable cleanup (satisfies non-drop resource consumption):
    test_only_destroy_record(rec);
}
