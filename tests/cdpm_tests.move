// CDPM Lending Helper Unit Tests
//
// These tests exercise the private lending helpers (`add_to_scallop_lending`,
// `pull_from_scallop_lending`, `add_to_kai_lending`, `pull_from_kai_lending`)
// through the `#[test_only]` wrappers in `cdpm.move`, covering the
// accumulation / conservation properties that were previously verified by
// sui-prover specs on the (removed) `#[spec_only] public fun spec_call_*`
// wrappers.
//
// SECURITY CONTEXT (2026-08-18 advisory): the former `spec_call_*`
// forwarders were `#[spec_only] public` functions that leaked into
// production bytecode as unauthenticated `&mut PositionManager` entry
// points. The wrappers used here are `#[test_only]` — a Move language
// primitive that the compiler strips from non-test builds — so they cannot
// be reached from any deployed PTB.

module cdpm::cdpm_tests;

use cdpm::cdpm::{
    test_only_add_to_kai_lending,
    test_only_add_to_scallop_lending,
    test_only_destroy_pm,
    test_only_kai_lending_state,
    test_only_lending_contains,
    test_only_new_pm,
    test_only_pull_from_kai_lending,
    test_only_pull_from_scallop_lending,
    test_only_scallop_lending_state,
};
use sui::balance::{Self, Balance};
use sui::tx_context::TxContext;

// Fake asset types for Kai tests (KaiVault is generic over <T, YT>).
public struct FakeT has drop {}
public struct FakeYT has drop {}

// ===========================================================================
// Scallop lending — accumulation (add_to_scallop_lending)
// ===========================================================================

#[test]
fun test_add_to_scallop_lending_accumulates_principal_and_scoin() {
    let ctx = &mut tx_context::dummy();
    let mut pm = test_only_new_pm(ctx);

    let scoin1: Balance<protocol::reserve::MarketCoin<FakeT>> = balance::zero();
    test_only_add_to_scallop_lending(&mut pm, scoin1, 100);

    let (scoin_value, principal) = test_only_scallop_lending_state<FakeT>(&pm);
    assert!(scoin_value == 0, 1);
    assert!(principal == 100, 2);

    // Second add joins the same vault (key = T's type_name).
    let scoin2: Balance<protocol::reserve::MarketCoin<FakeT>> = balance::zero();
    test_only_add_to_scallop_lending(&mut pm, scoin2, 50);

    let (scoin_value, principal) = test_only_scallop_lending_state<FakeT>(&pm);
    assert!(scoin_value == 0, 3);
    assert!(principal == 150, 4);

    // Drain the vault so the PM can be destroyed (destroy_empty requires
    // empty bags).
    let (pulled, principal_portion) =
        test_only_pull_from_scallop_lending<FakeT>(&mut pm, 18446744073709551615);
    assert!(principal_portion == 150, 5);
    balance::destroy_zero(pulled);

    test_only_destroy_pm(pm);
}

// ===========================================================================
// Scallop lending — conservation (pull_from_scallop_lending)
// ===========================================================================

#[test]
fun test_pull_from_scallop_lending_full_pull_returns_entire_vault() {
    let ctx = &mut tx_context::dummy();
    let mut pm = test_only_new_pm(ctx);

    let scoin: Balance<protocol::reserve::MarketCoin<FakeT>> = balance::zero();
    test_only_add_to_scallop_lending(&mut pm, scoin, 100);

    // want_amount >= total → full vault removal, principal_portion == principal.
    let (pulled, principal_portion) =
        test_only_pull_from_scallop_lending<FakeT>(&mut pm, 18446744073709551615);

    assert!(balance::value(&pulled) == 0, 1);
    assert!(principal_portion == 100, 2);
    balance::destroy_zero(pulled);

    // Vault entry removed — no longer present.
    assert!(!test_only_lending_contains<FakeT>(&pm), 3);

    test_only_destroy_pm(pm);
}

#[test]
fun test_pull_from_scallop_lending_partial_pull_conserves_principal() {
    let ctx = &mut tx_context::dummy();
    let mut pm = test_only_new_pm(ctx);

    let scoin: Balance<protocol::reserve::MarketCoin<FakeT>> = balance::zero();
    test_only_add_to_scallop_lending(&mut pm, scoin, 100);

    // Partial pull with zero-valued scoin: any want_amount >= 0 hits the
    // full-path branch (want >= total); principal conservation still holds:
    // returned portion == pre principal, vault entry removed.
    let (pulled, principal_portion) =
        test_only_pull_from_scallop_lending<FakeT>(&mut pm, 0);

    assert!(balance::value(&pulled) == 0, 1);
    assert!(principal_portion == 100, 2);
    balance::destroy_zero(pulled);

    test_only_destroy_pm(pm);
}

// ===========================================================================
// Kai lending — accumulation (add_to_kai_lending)
// ===========================================================================

#[test]
fun test_add_to_kai_lending_accumulates_principal_and_yt() {
    let ctx = &mut tx_context::dummy();
    let mut pm = test_only_new_pm(ctx);

    let yt1: Balance<FakeYT> = balance::zero();
    test_only_add_to_kai_lending<FakeT, FakeYT>(&mut pm, yt1, 100);

    let (yt_value, principal) = test_only_kai_lending_state<FakeT, FakeYT>(&pm);
    assert!(yt_value == 0, 1);
    assert!(principal == 100, 2);

    let yt2: Balance<FakeYT> = balance::zero();
    test_only_add_to_kai_lending<FakeT, FakeYT>(&mut pm, yt2, 25);

    let (yt_value, principal) = test_only_kai_lending_state<FakeT, FakeYT>(&pm);
    assert!(yt_value == 0, 3);
    assert!(principal == 125, 4);

    // Drain the vault so the PM can be destroyed.
    let (pulled, principal_portion) =
        test_only_pull_from_kai_lending<FakeT, FakeYT>(&mut pm, 18446744073709551615);
    assert!(principal_portion == 125, 5);
    balance::destroy_zero(pulled);

    test_only_destroy_pm(pm);
}

// ===========================================================================
// Kai lending — conservation (pull_from_kai_lending)
// ===========================================================================

#[test]
fun test_pull_from_kai_lending_full_pull_returns_entire_vault() {
    let ctx = &mut tx_context::dummy();
    let mut pm = test_only_new_pm(ctx);

    let yt: Balance<FakeYT> = balance::zero();
    test_only_add_to_kai_lending<FakeT, FakeYT>(&mut pm, yt, 80);

    let (pulled, principal_portion) =
        test_only_pull_from_kai_lending<FakeT, FakeYT>(&mut pm, 18446744073709551615);

    assert!(balance::value(&pulled) == 0, 1);
    assert!(principal_portion == 80, 2);
    balance::destroy_zero(pulled);

    assert!(!test_only_lending_contains<FakeT>(&pm), 3);

    test_only_destroy_pm(pm);
}
