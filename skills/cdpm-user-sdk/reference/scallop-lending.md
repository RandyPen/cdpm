# Scallop Lending (Idle Funds)

## Contents

- [API Overview](#api-overview)
- [PTB Recipe: Supply](#ptb-recipe-supply)
- [PTB Recipe: Redeem (with yield-fee deduction)](#ptb-recipe-redeem-with-yield-fee-deduction)
- [Exit Path](#exit-path)
- [Closing a PositionManager With Active Vaults](#closing-a-positionmanager-with-active-vaults)
- [Events](#events)
- [Error Cheat Sheet](#error-cheat-sheet)

## API Overview

Two single-MoveCall entry points, one per direction:

| Phase  | cdpm function          | Effect |
|--------|------------------------|--------|
| Supply | `scallop_supply<T>`    | Splits `amount` `Coin<T>` out of `pm.balance[T]`, calls `protocol::mint::mint<T>`, stores the resulting `Balance<MarketCoin<T>>` and principal into `pm.lending` under key `type_name<T>`. |
| Redeem | `scallop_redeem<T>`    | Pulls (a slice of) `Balance<MarketCoin<T>>` from `pm.lending`, calls `protocol::redeem::redeem<T>`, splits the protocol yield-fee off the interest portion into `FeeHouse`, deposits the net underlying back into `pm.balance[T]`. |

Authorization on both is `assert_caller_authorized`: caller must be **owner**, **an authorized agent**, or **a whitelisted protocol bot AND the PM has no agents**.

Each function is one `tx.moveCall`. cdpm itself calls `protocol::mint::mint` / `protocol::redeem::redeem`, and Scallop's `accrue_interest_for_market` is invoked as the first step inside those two functions — so the balance-sheet read after the inner call is fresh by construction. No external `accrue_interest_for_market` command is needed in the PTB.

---

## PTB Recipe: Supply

Authoritative signature:

```move
public fun scallop_supply<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    version: &ScallopVersion,
    market: &mut Market,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);
```

PTB shape (1 command):

```
cdpm::scallop_supply<T>(access, pm, scallop_version, scallop_market, amount, clock)
```

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function userSupplyToScallop(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  underlyingCoinType: string,    // e.g. '0x...::usdc::USDC'
  amount: bigint,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::scallop_supply`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.pure.u64(amount),
      tx.object('0x6'),                  // Clock
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Important properties:

- `scallop_supply` decreases `pm.balance[T]` by `amount` (using `withdraw_from_balance<T>`; the resulting `Coin<T>` value is recorded as `principal`).
- The first supply for a given `T` creates a fresh `ScallopVault<T>` under bag key `type_name<T>`; subsequent supplies of the same `T` join the new `Balance<MarketCoin<T>>` and add to `principal`.
- The `Coin<MarketCoin<T>>` returned by Scallop never leaves the contract; it is converted into `Balance<MarketCoin<T>>` and stored. External code cannot forge `Coin<MarketCoin<T>>` because `MarketCoin`'s constructor lives inside Scallop.
- `amount = 0` is a no-op (the inner `withdraw_from_balance<T>` short-circuits to `coin::zero<T>` and `mint` returns a zero `Coin<MarketCoin<T>>` which `add_to_scallop_lending` accepts).

---

## PTB Recipe: Redeem (with yield-fee deduction)

Redeem deducts the protocol yield fee from the **interest portion only**, never from principal. The fee math lives inside `scallop_redeem`:

```
interest         = max(0, redeemed_amount − principal_portion)
fee_amount       = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance    = redeemed_amount − fee_amount
```

`principal_portion` is the slice of stored principal proportional to the burned scoin: `principal_portion = floor(P_total × scoin_burned / S_total)` (see `pull_from_scallop_lending`).

Authoritative signature:

```move
public fun scallop_redeem<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    version: &ScallopVersion,
    market: &mut Market,
    scoin_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);
```

PTB shape (1 command):

```
cdpm::scallop_redeem<T>(access, pm, fee_house, scallop_version, scallop_market, scoin_amount, clock)
```

`scoin_amount = u64::MAX` is a sentinel meaning *drain the entire `ScallopVault<T>` entry from `pm.lending`* — `pull_from_scallop_lending` clamps `want_amount` to the stored scoin balance and removes the bag entry.

```typescript
async function userRedeemFromScallop(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  underlyingCoinType: string,
  scoinAmount: bigint,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::scallop_redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.pure.u64(scoinAmount),          // u64::MAX = 0xffffffffffffffffn drains the entry
      tx.object('0x6'),                  // Clock
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

The post-fee underlying lands back in `pm.balance[T]`; withdraw it with `user_remove_liquidity_from_balance<T>`.

### Sizing Redemptions

`scallop_redeem` takes a `scoin_amount` (sCoin), but most callers think in terms of *underlying they need*. Two inverses cover the realistic cases:

- **Pre-fee target.** I want at least `K` underlying out of Scallop, fee aside. `scoin_to_burn = ceil(K × supply / denom)` where `denom = cash + debt − revenue`.
- **Post-fee target.** I want at least `K` net underlying credited to `pm.balance[T]` after the yield fee. The closed form is `N ≈ ceil(K / (p × (1 − r) + r × π))` when there is interest (the typical case `p > π`), where `p = denom / supply`, `π = principal / scoinTotal`, `r = fee_rate / 10000`.

Both formulas use **ceiling** division — Scallop floors the actual underlying delivered, so flooring `N` would risk receiving 1 unit fewer than `K`. Cross-link: the full derivation, edge cases (no-interest branch, vault drain, socialized loss), and an iterative refinement helper live in [`cdpm-calculation-skill/reference/scallop-lending-math.md`](../../cdpm-calculation-skill/reference/scallop-lending-math.md) section 7.

```typescript
import {
  scoinToBurnForTargetUnderlying,
  scoinToBurnForTargetNet,
} from './scallop-lending-math'; // your local copy

// "Give me 100 underlying out of Scallop, fee aside."
const nPreFee = scoinToBurnForTargetUnderlying(
  reserveSnapshot,
  100_000_000n,             // K, in underlying base units
  vaultSnapshot.scoinTotal,
);

// "Credit at least 100 underlying to pm.balance after the yield fee."
const nPostFee = scoinToBurnForTargetNet(
  reserveSnapshot,
  vaultSnapshot,
  100_000_000n,             // K
  2_000n,                   // 2000 bp = 20%
);

// Feed it straight into scallop_redeem.
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_redeem`,
  typeArguments: [underlyingCoinType],
  arguments: [
    tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
    tx.object(pmId),
    tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
    tx.object(SCALLOP_VERSION_ID),
    tx.object(SCALLOP_MARKET_ID),
    tx.pure.u64(nPostFee),               // sentinel MAX_U64 drains the entry
    tx.object('0x6'),
  ],
});
```

If the helper returns `MAX_U64` it means the vault cannot satisfy your target; passing `MAX_U64` to `scallop_redeem` drains the entire vault and returns whatever Scallop pays out.

---

## Exit Path

cdpm exposes no function that hands `MarketCoin<T>` out to the caller. The only exit is:

```
scallop_redeem<T> → pm.balance[T] → user_remove_liquidity_from_balance<T>
```

A raw `Coin<MarketCoin<T>>` outside cdpm is only redeemable back through Scallop's `redeem`, and the principal counter that protocol-fee math depends on lives inside `ScallopVault<T>`. If Scallop is unreachable (Version bump, paused market, etc.), the abort happens inside the inner `mint::mint` / `redeem::redeem` call and `pm.lending` stays intact. Retry once Scallop ships an SDK update against the new Version; cdpm itself stays operational throughout.

The Cetus DLMM `Position` is the only object cdpm cannot recover from upstream breakage in-band, and that one case is handled by the owner-only `user_get_position` / `user_get_and_return_position` extraction documented in [`position-management.md`](./position-management.md).

---

## Closing a PositionManager With Active Vaults

`user_close_pm` asserts `bag::is_empty(&pm.lending)` (`ELendingNotEmpty = 1004`). The same assertion covers both Scallop and Kai entries — redeem every entry of either flavor before close. For every Scallop `T` vault, call `scallop_redeem<T>` with `scoin_amount = u64::MAX`; the post-fee underlying lands in `pm.balance[T]` and is then withdrawn with `user_remove_liquidity_from_balance<T>(u64::MAX)`. For every Kai `(T, YT)` entry, call `kai_redeem<T, ST, YT>` with `yt_amount = u64::MAX` — see [`kai-lending.md`](./kai-lending.md).

`user_close_pm` also asserts:
- `bag::is_empty(&pm.balance)` (`EBalanceNotEmpty = 1008`) — drain every `pm.balance[T]` first.
- `bag::is_empty(&pm.fee)` (`EFeeNotEmpty = 1009`) — drain every `pm.fee[T]` first.
- Every `PositionInfo.rewards_owned[i] == 0` (`EPositionHasRewards = 1007`) — call `user_collect_reward<A, B, R>` for every reward type on the pool first.

---

## Events

```typescript
interface ScallopSupplied {
  pm_id: string;
  coin_type: string;          // type_name<T>
  deposit_amount: u64;        // underlying transferred to Scallop
  market_coin_minted: u64;    // sCoin received (Coin<MarketCoin<T>>)
}

interface ScallopRedeemed {
  pm_id: string;
  coin_type: string;
  market_coin_redeemed: u64;  // sCoin burned
  redeemed_amount: u64;       // underlying received from Scallop (pre-fee)
  principal_portion: u64;     // principal slice consumed by this redeem
  interest: u64;              // redeemed_amount − principal_portion
  fee_amount: u64;            // protocol fee taken from interest
}
```

> Events carry `coin_type = type_name<T>` and not a separate `scoin_type`, because the sCoin type is always `MarketCoin<T>` and fully determined by `coin_type`. Events do not carry a sender field; Sui event envelopes already record the transaction sender — reach for `event.sender` if you need to distinguish owner / agent / protocol callers.

---

## Error Cheat Sheet

| Code | Constant | When |
|------|----------|------|
| 1001 | `ENotOwner` | Non-owner called an owner-only entry (Scallop lending itself exposes no owner-only entry; this code does not surface from `scallop_supply` / `scallop_redeem`). |
| 1002 | `ENotAllow` | `scallop_supply` / `scallop_redeem` failed `assert_caller_authorized` (caller is not owner, not in `pm.agents`, and either not in `access.allow` or `pm.agents` is non-empty). |
| 1004 | `ELendingNotEmpty` | `user_close_pm` while `pm.lending` is non-empty (any Scallop or Kai entry). |
| 1005 | `ENoSuchVault` | `scallop_redeem` for an absent Scallop `T` entry. The Kai counterpart shares this code for absent `(T, YT)` entries — see `kai-lending.md`. |
| 1006 | `ENoSuchBalance` | `scallop_supply` ran with `amount > 0` but `pm.balance` has no `Balance<T>` entry to draw from. Deposit `Coin<T>` into the PM with `user_add_liquidity_to_balance<T>` first. |
