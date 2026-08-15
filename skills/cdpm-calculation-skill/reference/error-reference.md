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

These are the abort codes from the `cdpm::cdpm` module. They are **shared** between the Scallop and Kai SAV integrations — they are not Scallop-only.

| Code | Constant | Cause | Off-chain mitigation |
|------|----------|-------|----------------------|
| 1001 | `ENotOwner` | Non-owner called an owner-only function (e.g. `user_add_liquidity_to_position`, `user_remove_liquidity_from_position`, `user_collect_fee`, `user_collect_reward`, `user_remove_liquidity_from_balance`, `user_withdraw_fee`, `user_insert_agent`, `user_remove_agent`, `user_close_pm`, `user_add_liquidity_to_balance`) | Check `pm.owner == sender` before signing |
| 1002 | `ENotAllow` | `assert_caller_authorized` failed for `scallop_supply` / `scallop_redeem` / `kai_supply` / `kai_redeem`, or a `protocol_*` / `agent_*` access invariant broken | Verify caller is in `pm.agents` or `AccessList.allow` (and `pm.agents` is empty for the protocol path) |
| 1003 | `EInvalidFeeRate` | `admin_set_fee` rate `>` 50% (`MAX_FEE_RATE = 5000` bp) | Cap `feeRateBp <= 5000` |
| 1004 | `ELendingNotEmpty` | `user_close_pm` while `pm.lending` is non-empty (any Scallop or Kai entry) | Drain every `ScallopVault<T>` via `scallop_redeem` and every `KaiVault<T, YT>` via `kai_redeem` first |
| 1005 | `ENoSuchVault` | `scallop_redeem` for an absent `T` entry, or `kai_redeem` for an absent `(T, YT)` entry | Confirm the requested vault entry exists in `pm.lending` (Scallop key = `type_name<T>`, Kai key = `type_name<YT>`) |
| 1006 | `ENoSuchBalance` | `withdraw_from_balance` / `withdraw_from_fee` for an absent type key (e.g. `user_remove_liquidity_from_balance`, `user_withdraw_fee`, `protocol_transfer_fee_to_balance`, `agent_transfer_fee_to_balance`, or any path that pulls a `Coin<T>` from `pm.balance` / `pm.fee` when no such entry exists) | Confirm the bag entry for the requested type exists before signing |
| 1007 | `EPositionHasRewards` | `user_close_pm` / `agent_destroy_position` while the Cetus `PositionInfo.rewards_owned` vector has a non-zero entry | Call `user_collect_reward<…, RewardType>` for each reward type until all entries are 0 before closing |
| 1008 | `EBalanceNotEmpty` | `user_close_pm` while `pm.balance` is non-empty | Withdraw every `Balance<T>` entry via `user_remove_liquidity_from_balance<T>` first |
| 1009 | `EFeeNotEmpty` | `user_close_pm` while `pm.fee` is non-empty | Withdraw every `Balance<T>` entry from `pm.fee` via `user_withdraw_fee<T>` (or transfer to balance via `protocol_transfer_fee_to_balance` / `agent_transfer_fee_to_balance` and then drain) first |
| 1010 | `EPositionAlreadyExists` | `agent_create_position` while `pm.position` is already `Some` | Destroy the current position (`agent_destroy_position`) before creating a new one |
| 1011 | `ENoPosition` | Any position-accessing operation (`user_*_from_position`, `protocol_remove_liquidity` / `protocol_collect_*`, agent equivalents, `agent_destroy_position`) while `pm.position` is `None` | Create a position first (`agent_create_position` / `user_deposit_liquidity`), or read `pm.pool_id` to confirm the PM is bound to the expected pool |
| 1012 | `EWrongPool` | `agent_create_position` called with a pool that does not match the PM's bound `pool_id` | Read `pm.pool_id` (top-level field) and pass exactly that pool |

## `user_close_pm` preconditions

`user_close_pm` enforces drain conditions before destructuring the PM. Its
behavior is **dual-mode** depending on `pm.position` (`Option<Position>`):

- **`Some` (position active)** — the reward-residual check below applies,
  then `pool::close_position` + `pool::destroy_close_position_cert` run and
  the residual `Balance<CoinTypeA>` / `Balance<CoinTypeB>` are transferred to
  the sender.
- **`None` (position already destroyed)** — the Cetus close is skipped; the
  PM is drained and closed as-is.

The four drain conditions:

1. `pm.balance` is empty (`EBalanceNotEmpty = 1008`).
2. `pm.fee` is empty (`EFeeNotEmpty = 1009`).
3. `pm.lending` is empty (`ELendingNotEmpty = 1004`).
4. Every entry in the Cetus `PositionInfo.rewards_owned` vector is zero
   (`EPositionHasRewards = 1007`) — only checked when `pm.position` is
   `Some`.

The diagnostics fire in that order. After all four assertions pass,
`user_close_pm` emits `PositionManagerClosed`.

## Caller-side dust handling in `*_redeem`

`scallop_redeem` and `kai_redeem` compose the full lending-side redemption inside a single move-call. The redeemed underlying lands directly in `pm.balance[T]`; there is no caller-supplied coin to validate against an off-chain prediction. Off-chain `predictScallopRedeem` / `predictKaiWithdraw` are used to **size** the burn (sCoin or YT amount), but they are not enforced at the cdpm boundary — a prediction shortfall surfaces as a smaller `pm.balance[T]` increment rather than an abort.

The principal split (`pull_from_scallop_lending` / `pull_from_kai_lending`) and the yield-fee accounting are exact:

- `principal_portion` is `floor(total_principal × want / total_share)` on partial pulls and `total_principal` on a full drain.
- `interest = max(0, redeemed_amount − principal_portion)` and `fee_amount = floor(interest × fee_house.fee_rate / 10_000)` are computed against the live `redeemed_amount` returned by the upstream protocol — no snapshot mismatch is possible.

## Type-pin notes

- **Scallop**: the sCoin type is structurally pinned to `MarketCoin<T>` by the type system. There is no separate `S` generic, so a forged sCoin variant cannot be passed in — `Coin<MarketCoin<T>>` is the only accepted type, and `MarketCoin` has only `drop` ability with no public constructor (the only path to a non-zero `Coin<MarketCoin<T>>` is Scallop's `mint`).
- **Kai SAV**: `Coin<YT>` is type-pinned to `kai_sav::vault::Vault<T, YT>`, whose `TreasuryCap` is held privately by the vault module. External code cannot mint a forged `Coin<YT>`, and `kai_sav::vault::new` is `public(package)` so a forged `Vault<T, EvilYT>` cannot be passed to `kai_supply` either.
