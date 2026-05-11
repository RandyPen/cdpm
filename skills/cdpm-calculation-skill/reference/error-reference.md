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

These show up as Move abort codes from the `cdpm::cdpm` module when off-chain prediction disagrees with on-chain state.

| Code | Constant | Cause | Off-chain mitigation |
|------|----------|-------|----------------------|
| 1001 | `ENotOwner` | Non-owner called an owner-only function (e.g. `user_extract_market_coin`) | Check `pm.owner == sender` before signing |
| 1002 | `ENotAllow` | `assert_caller_authorized` failed (or `protocol_*` invariant broken) | Verify caller is in `pm.agents` or `AccessList.allow` (and `pm.agents` is empty for protocol path) |
| 1003 | `EInvalidFeeRate` | `admin_set_fee` rate `>` 30% | Cap `feeRateBp <= 3000` |
| 1004 | `ELendingNotEmpty` | `user_close_pm` while `pm.lending` is non-empty | Drain every `ScallopVault<T>` first |
| 1005 | `ENoSuchVault` | `start_redeem` / `user_extract_market_coin` for an absent T entry | Confirm the vault exists in `pm.lending` |
| 1006 | `EReserveEmpty` | Scallop reserve has zero supply or zero `(cash + debt - revenue)` | Run `accrue_interest_for_market` first; check the live balance sheet |
| 1007 | `EZeroExpected` | `start_*` predicted output is 0 (input too small) | Increase the `amount` |
| 1008 | `EWrongPm` | `finish_*` ticket consumed against a different PM | Reuse the same `pm` object across `start_*` and `finish_*` |
| 1009 | `EAmountShortfall` | `finish_*` Coin value `<` ticket.expected | Always run `accrue_interest_for_market` as the first PTB command |

Note: the sCoin type is structurally pinned to `MarketCoin<T>` by the type system. There is no separate `S` generic any more, so a fake-sCoin variant cannot be passed in — `Coin<MarketCoin<T>>` is the only accepted type, and `MarketCoin` has only `drop` ability with no public constructor (the only path to a non-zero `Coin<MarketCoin<T>>` is Scallop's `mint`).
