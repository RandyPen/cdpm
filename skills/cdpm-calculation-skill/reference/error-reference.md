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
| 1009 | `EAmountShortfall` | `finish_*` Coin value falls short of `ticket.expected` by more than `REDEEM_DUST_TOLERANCE_RAW = 4` raw. Floor-div dust up to 4 raw is auto-tolerated on-chain. Real-world causes: Scallop missing `accrue_interest_for_market` (large gap); or a future ≥3-strategy Kai vault whose dust exceeds 4 raw. | See **EAmountShortfall (1009) deep dive** below. |
| 1010 | `ENoSuchBalance` | `withdraw_from_balance` / `withdraw_from_fee` for an absent type key | Confirm the bag entry for the requested type exists before signing |
| 1011 | `EStaleScallopState` | `scallop_start_supply` / `scallop_start_redeem` reached the cdpm boundary in a PTB whose Scallop per-asset `last_updated` (read via `borrow_dynamics::last_updated_by_type`) is older than `clock::timestamp_ms(clock) / 1000` — i.e. the caller did not invoke `accrue_interest::accrue_interest_for_market(version, market, clock)` earlier in the same PTB. | Make `accrue_interest::accrue_interest_for_market(version, market, clock)` PTB command 0 for every Scallop supply/redeem batch. |
| 1012 | `EWrongMarket` | `scallop_finish_supply` / `scallop_finish_redeem` was passed a `&Market` whose `object::id` does not match the `market_id` recorded on the ticket at `start_*` time. | Pass the same `Market` shared object across `start_*` and `finish_*` (re-use the same `tx.object(MARKET_ID)` handle in the PTB). |
| 1013 | `EWrongVault` | `kai_finish_supply` / `kai_finish_redeem` was passed a `&kai_vault::Vault<T,YT>` whose `object::id` does not match the `vault_id` recorded on the ticket at `start_*` time. | Pass the same `Vault<T,YT>` shared object across `start_*` and `finish_*`. |

## EAmountShortfall (1009) deep dive

`*_finish_redeem` enforces `redeemed_amount + REDEEM_DUST_TOLERANCE_RAW >= ticket.expected_underlying`
(`REDEEM_DUST_TOLERANCE_RAW = 4`). `expected_underlying` is computed at
`*_start_redeem` time from a price-per-share snapshot
(`compute_expected_underlying_scallop` / `compute_expected_underlying_kai`).
The actual `redeemed_amount` comes from the upstream Scallop `redeem::redeem`
or Kai's `kai_leverage_supply_pool::withdraw → vault::redeem_withdraw_ticket`
chain. The two protocols differ:

- **Kai** floors twice per strategy in the strategy withdraw (muldiv +
  redeem_lossy), so dust ≈ 2 raw × (strategies actually drawn). Current
  single-strategy mainnet SAVs ⟹ ≤2 raw — well within the on-chain
  tolerance. Dust is constant in principal and independent of transaction
  history (withdraw-then-redeposit does not accumulate it).
- **Scallop** uses the same single u128 floor-div formula that cdpm uses
  in `compute_expected_underlying_scallop`, on the same balance-sheet
  snapshot within the PTB. Result: `redeemed_amount == expected_underlying`
  exactly in the common case — no observed dust.

See `kai-lending-math.md` / `scallop-lending-math.md` §9.1 for details.

Realistic causes when 1009 still trips today:

| Cause | Symptom | Fix |
|---|---|---|
| Scallop missing `accrue_interest_for_market` as PTB command 0 | Large gap, far beyond 4 raw | Add the accrue command; also enforced separately by `EStaleScallopState (1011)` |
| Vault state moved between snapshot and signing | Random small failures | Re-snapshot just before signing |
| Future ≥3-strategy Kai vault whose dust exceeds 4 raw | Rare; would be reproducible per-vault | Optional `coin::join` topup of `(observedDust − 4)` raw between start_redeem and finish_redeem |

Capping the burn (`min(neededWrapper, entry.wrapperRaw − LENDING_SAFE_MARGIN_WRAPPER_RAW)`,
default 100 wrapper raw) is still recommended on partial redeems — it
leaves a residual entry in `pm.lending` so the bag key survives — but it is
no longer needed *for the 1009 dust concern* (handled on-chain).

## Type-pin notes

- **Scallop**: the sCoin type is structurally pinned to `MarketCoin<T>` by the type system. There is no separate `S` generic, so a fake-sCoin variant cannot be passed in — `Coin<MarketCoin<T>>` is the only accepted type, and `MarketCoin` has only `drop` ability with no public constructor (the only path to a non-zero `Coin<MarketCoin<T>>` is Scallop's `mint`).
- **Kai SAV**: `Coin<YT>` is type-pinned to `kai_sav::vault::Vault<T, YT>`, whose `TreasuryCap` is held privately by the vault module. External code cannot mint a forged `Coin<YT>`, and `kai_sav::vault::new` is `public(package)` so a fake `Vault<T, EvilYT>` cannot be passed to `kai_start_supply` either.
