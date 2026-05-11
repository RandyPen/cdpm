# Error Reference

## Cetus DLMM SDK Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `EPriceIsZero` | Price parameter is 0 | Validate price before calculation |
| `ELiquidityOverflow` | Result exceeds u128 max | Reduce input amounts |
| `InvalidBinId` | Bin ID out of valid range | Check with `findMinMaxBinId()` |
| `LiquiditySupplyIsZero` | Attempting to remove from empty bin | Check liquidity before removal |
| `InvalidDeltaLiquidity` | Removing more than available | Validate against total liquidity |

## cdpm Move Errors (sources/cdpm.move:28-36)

These show up as Move abort codes from the `cdpm::cdpm` module when off-chain prediction disagrees with on-chain state. **The codes are SHARED between the Scallop and Kai SAV integrations** — they are not Scallop-only.

| Code | Constant | Cause | Off-chain mitigation |
|------|----------|-------|----------------------|
| 1001 | `ENotOwner` | Non-owner called an owner-only function (e.g. `user_extract_scallop_market_coin` or `user_extract_kai_yt`) | Check `pm.owner == sender` before signing |
| 1002 | `ENotAllow` | `assert_caller_authorized` failed for any of `scallop_start_*` / `kai_start_*`, or a `protocol_*` invariant broken | Verify caller is in `pm.agents` or `AccessList.allow` (and `pm.agents` is empty for the protocol path) |
| 1003 | `EInvalidFeeRate` | `admin_set_fee` rate `>` 30% | Cap `feeRateBp <= 3000` |
| 1004 | `ELendingNotEmpty` | `user_close_pm` while `pm.lending` is non-empty (any Scallop or Kai entry) | Drain every `ScallopVault<T>` AND every `KaiVault<T, YT>` first |
| 1005 | `ENoSuchVault` | `scallop_start_redeem` / `user_extract_scallop_market_coin` for an absent `T` entry, or `kai_start_redeem` / `user_extract_kai_yt` for an absent `(T, YT)` entry | Confirm the requested vault entry exists in `pm.lending` (Scallop key = `type_name<T>`, Kai key = `type_name<YT>`) |
| 1006 | `EReserveEmpty` | Scallop reserve has zero supply or zero `(cash + debt - revenue)`, OR Kai vault `total_yt_supply == 0` | Scallop: run `accrue_interest_for_market` first; check the live balance sheet. Kai: bootstrap by supplying first or skip the vault. |
| 1007 | `EZeroExpected` | `scallop_start_*` / `kai_start_*` predicted output is 0 (input too small) | Increase the `amount` |
| 1008 | `EWrongPm` | `scallop_finish_*` / `kai_finish_*` ticket consumed against a different PM | Reuse the same `pm` object across `start_*` and `finish_*` |
| 1009 | `EAmountShortfall` | `finish_*` Coin value `<` ticket.expected | Scallop: run `accrue_interest_for_market` as the first PTB command. Kai: re-snapshot `total_available_balance` immediately before signing. |

Type-pin notes:

- **Scallop**: the sCoin type is structurally pinned to `MarketCoin<T>` by the type system. There is no separate `S` generic, so a fake-sCoin variant cannot be passed in — `Coin<MarketCoin<T>>` is the only accepted type, and `MarketCoin` has only `drop` ability with no public constructor (the only path to a non-zero `Coin<MarketCoin<T>>` is Scallop's `mint`).
- **Kai SAV**: `Coin<YT>` is type-pinned to `kai_sav::vault::Vault<T, YT>`, whose `TreasuryCap` is held privately by the vault module. External code cannot mint a forged `Coin<YT>`, and `kai_sav::vault::new` is `public(package)` so a fake `Vault<T, EvilYT>` cannot be passed to `kai_start_supply` either.
