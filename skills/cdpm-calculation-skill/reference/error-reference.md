# Error Reference

## Cetus DLMM SDK Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `EPriceIsZero` | Price parameter is 0 | Validate price before calculation |
| `ELiquidityOverflow` | Result exceeds u128 max | Reduce input amounts |
| `InvalidBinId` | Bin ID out of valid range | Check with `findMinMaxBinId()` |
| `LiquiditySupplyIsZero` | Attempting to remove from empty bin | Check liquidity before removal |
| `InvalidDeltaLiquidity` | Removing more than available | Validate against total liquidity |

## cdpm Move Errors (sources/cdpm.move)

These show up as Move abort codes from the `cdpm::cdpm` module when off-chain prediction disagrees with on-chain state. **The codes are SHARED between the Scallop and Kai SAV integrations** — they are not Scallop-only.

| Code | Constant | Cause | Off-chain mitigation |
|------|----------|-------|----------------------|
| 1001 | `ENotOwner` | Non-owner called an owner-only function (e.g. `user_get_position` / `user_get_and_return_position` — the only owner-only escape hatch, which extracts the Cetus DLMM `Position` object) | Check `pm.owner == sender` before signing |
| 1002 | `ENotAllow` | `assert_caller_authorized` failed for any of `scallop_start_*` / `kai_start_*`, or a `protocol_*` invariant broken | Verify caller is in `pm.agents` or `AccessList.allow` (and `pm.agents` is empty for the protocol path) |
| 1003 | `EInvalidFeeRate` | `admin_set_fee` rate `>` 30% | Cap `feeRateBp <= 3000` |
| 1004 | `ELendingNotEmpty` | `user_close_pm` while `pm.lending` is non-empty (any Scallop or Kai entry) | Drain every `ScallopVault<T>` AND every `KaiVault<T, YT>` via the full `*_start_redeem` → upstream `redeem`/`withdraw` → `*_finish_redeem` flow first (no wrapper-extract bypass exists) |
| 1005 | `ENoSuchVault` | `scallop_start_redeem` for an absent `T` entry, or `kai_start_redeem` for an absent `(T, YT)` entry | Confirm the requested vault entry exists in `pm.lending` (Scallop key = `type_name<T>`, Kai key = `type_name<YT>`) |
| 1006 | `EReserveEmpty` | Scallop reserve has zero supply or zero `(cash + debt - revenue)`, OR Kai vault `total_yt_supply == 0` | Scallop: run `accrue_interest_for_market` first; check the live balance sheet. Kai: bootstrap by supplying first or skip the vault. |
| 1007 | `EZeroExpected` | `scallop_start_*` / `kai_start_*` predicted output is 0 (input too small) | Increase the `amount` |
| 1008 | `EWrongPm` | `scallop_finish_*` / `kai_finish_*` ticket consumed against a different PM | Reuse the same `pm` object across `start_*` and `finish_*` |
| 1009 | `EAmountShortfall` | `finish_*` Coin value `<` ticket.expected (Scallop missing `accrue_interest_for_market`, OR Kai/Scallop full-drain hitting strategy-walker floor-div dust) | See **EAmountShortfall (1009) deep dive** below — mitigation differs per caller (user / protocol / agent). |
| 1010 | `ENoSuchBalance` | `withdraw_from_balance` / `withdraw_from_fee` for an absent type key | Confirm the bag entry for the requested type exists before signing |
| 1011 | `EStaleScallopState` | `scallop_start_supply` / `scallop_start_redeem` reached the cdpm boundary in a PTB whose Scallop per-asset `last_updated` (read via `borrow_dynamics::last_updated_by_type`) is older than `clock::timestamp_ms(clock) / 1000` — i.e. the caller did not invoke `accrue_interest::accrue_interest_for_market(version, market, clock)` earlier in the same PTB. | Make `accrue_interest::accrue_interest_for_market(version, market, clock)` PTB command 0 for every Scallop supply/redeem batch. |
| 1012 | `EWrongMarket` | `scallop_finish_supply` / `scallop_finish_redeem` was passed a `&Market` whose `object::id` does not match the `market_id` recorded on the ticket at `start_*` time. | Pass the same `Market` shared object across `start_*` and `finish_*` (re-use the same `tx.object(MARKET_ID)` handle in the PTB). |
| 1013 | `EWrongVault` | `kai_finish_supply` / `kai_finish_redeem` was passed a `&kai_vault::Vault<T,YT>` whose `object::id` does not match the `vault_id` recorded on the ticket at `start_*` time. | Pass the same `Vault<T,YT>` shared object across `start_*` and `finish_*`. |

## EAmountShortfall (1009) deep dive

`*_finish_redeem` asserts `redeemed_amount >= ticket.expected_underlying`.
`expected_underlying` is computed at `*_start_redeem` time from a price-per-
share snapshot (`compute_expected_underlying_scallop` /
`compute_expected_underlying_kai` in cdpm.move). The actual `redeemed_amount`
comes from the upstream Scallop `redeem::redeem` or Kai's
`kai_leverage_supply_pool::withdraw → vault::redeem_withdraw_ticket` chain.
The two protocols differ:

- **Kai** applies floor-div *per strategy step*, so cumulative dust is
  O(strategies × 1 raw) — ≈ 2-3 raw for current single-strategy mainnet
  vaults. On full drain (`yt_amount = u64::MAX`) the assert trips
  reliably.
- **Scallop** uses the same single u128 floor-div formula that cdpm uses
  in `compute_expected_underlying_scallop`, on the same balance-sheet
  snapshot within the PTB. Result: `redeemed_amount == expected_underlying`
  exactly, no observed dust. The defensive cap is still applied for parity
  with Kai and as a forward-compatibility hedge.

See `kai-lending-math.md` / `scallop-lending-math.md` §9.1 for details.

Mitigation is caller-specific:

| Caller | Strategy | Reference |
|---|---|---|
| **User close-PM** | PTB inserts `0x2::coin::join(coinT, topup)` between the redeem chain and `*_finish_redeem`. The top-up (~30 raw underlying) is folded into `redeemed_amount`, so `interest = redeemed - principal` includes it and the service fee is taken on the inflated interest — fee NOT bypassed. | `cdpm-user-sdk/reference/kai-lending.md`, `scallop-lending.md`, `workflows.md` |
| **Protocol (worker)** | NEVER pass `u64::MAX`. Cap burn at `min(neededWrapper, entry.wrapperRaw − LENDING_SAFE_MARGIN_WRAPPER_RAW)` (default 100 wrapper raw). Residual dust stays in `pm.lending` and is reclaimed when the user closes the PM. | `cdpm-protocol-sdk/reference/kai-lending.md`, `scallop-lending.md` |
| **Agent** | Same as protocol. | `cdpm-agent-sdk/reference/kai-lending.md`, `scallop-lending.md`, `error-handling.md` |

The Scallop branch additionally requires `accrue_interest_for_market` as PTB
command 0 (separately enforced by `EStaleScallopState` 1011). That's a
distinct concern from the floor-div dust above and applies to both partial
and full redeems.

## Type-pin notes

- **Scallop**: the sCoin type is structurally pinned to `MarketCoin<T>` by the type system. There is no separate `S` generic, so a fake-sCoin variant cannot be passed in — `Coin<MarketCoin<T>>` is the only accepted type, and `MarketCoin` has only `drop` ability with no public constructor (the only path to a non-zero `Coin<MarketCoin<T>>` is Scallop's `mint`).
- **Kai SAV**: `Coin<YT>` is type-pinned to `kai_sav::vault::Vault<T, YT>`, whose `TreasuryCap` is held privately by the vault module. External code cannot mint a forged `Coin<YT>`, and `kai_sav::vault::new` is `public(package)` so a fake `Vault<T, EvilYT>` cannot be passed to `kai_start_supply` either.
