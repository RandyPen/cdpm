# Scallop Lending (Idle Funds)

`PositionManager` exposes a hot-potato lending API that lets the **owner** (and authorized agents / whitelisted protocol bots) park unused balance into Scallop and earn yield while the position is idle.

The on-chain shape:

```move
use protocol::reserve::MarketCoin;

public struct PositionManager has key {
    id: UID,
    owner: address,
    agents: VecSet<address>,
    position: Option<Position>,
    balance: Bag,
    fee: Bag,
    lending: Bag,                 // <— keyed by `type_name<T>`, value = ScallopVault<T>
}

public struct ScallopVault<phantom T> has store {
    scoin: Balance<MarketCoin<T>>, // Scallop sCoin (yield-bearing market coin)
    principal: u64,                // Original underlying deposited (for yield accounting)
}
```

There is **at most one vault per underlying type T**. The sCoin type is structurally pinned to `MarketCoin<T>` by the type system — there is no separate `S` generic, so a fake-sCoin variant simply cannot be passed in.

---

## Hot-Potato API Overview

The four entry points come in two pairs that must be glued together inside one PTB:

| Phase    | cdpm function | Returns / consumes                                          |
|----------|------------------------|----------------------------------------------------|
| Supply   | `start_supply<T>`      | `(Coin<T>, SupplyTicket<T>)`                       |
| Supply   | `finish_supply<T>`     | consumes `SupplyTicket<T>` + `Coin<MarketCoin<T>>` |
| Redeem   | `start_redeem<T>`      | `(Coin<MarketCoin<T>>, RedeemTicket<T>)`           |
| Redeem   | `finish_redeem<T>`     | consumes `RedeemTicket<T>` + `Coin<T>`             |

`SupplyTicket<T>` and `RedeemTicket<T>` have **no `drop` ability**. The only way to discharge them is by calling the matching `finish_*`. If you forget, the PTB aborts.

Authorization for `start_supply` / `start_redeem` is checked by `assert_caller_authorized`: caller must be **owner**, **an authorized agent**, or **a whitelisted protocol bot AND the PM has no agents**.

`finish_supply` / `finish_redeem` only verify that `ticket.pm_id == object::id(pm)`; the auth check happens on the start side.

---

## PTB Recipe: Supply

The first command of any supply PTB **MUST** be `protocol::accrue_interest::accrue_interest_for_market`. cdpm reads `balance_sheet` view-only — it does not bump Scallop's accrual itself, and a stale `balance_sheet` would make `compute_expected_scoin` predict a higher mint than Scallop actually delivers, tripping `EAmountShortfall (1009)` inside `finish_supply`.

Required PTB order:

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::start_supply<T>(access, pm, market, amount)              → (coin_t, ticket)
3. protocol::mint::mint<T>(version, market, coin_t, clock)        → coin_market<T>
4. cdpm::finish_supply<T>(pm, ticket, coin_market)
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

  // 1. Bump Scallop accrual so the on-chain balance_sheet is fresh.
  tx.moveCall({
    target: `${SCALLOP_PROTOCOL}::accrue_interest::accrue_interest_for_market`,
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.object('0x6'),
    ],
  });

  // 2. Withdraw underlying from pm.balance and emit a SupplyTicket.
  const [coinT, ticket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::start_supply`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(SCALLOP_MARKET_ID),
      tx.pure.u64(amount),
    ],
  });

  // 3. Hand the underlying to Scallop, receive Coin<MarketCoin<T>>.
  const [coinMarket] = tx.moveCall({
    target: `${SCALLOP_PROTOCOL}::mint::mint`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      coinT,
      tx.object('0x6'),
    ],
  });

  // 4. Burn the SupplyTicket by depositing the sCoin into pm.lending.
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::finish_supply`,
    typeArguments: [underlyingCoinType],
    arguments: [tx.object(pmId), ticket, coinMarket],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

Important properties:

- `start_supply` decreases `pm.balance[T]` by `amount` and stores `principal` for later yield accounting.
- `finish_supply` requires `coinMarket.value() >= ticket.expected_scoin`; otherwise it aborts with `EAmountShortfall (1009)`. Combined with the `Coin<MarketCoin<T>>` type pin (the only way to obtain a non-zero `Coin<MarketCoin<T>>` is through Scallop's `mint`, since `MarketCoin` has only `drop` and no public constructor), an agent cannot short-change the vault with a fake sCoin or a smaller real one.
- The first supply for a given `T` creates a fresh `ScallopVault<T>`; subsequent supplies of the same `T` add to it.

---

## PTB Recipe: Redeem (with yield-fee deduction)

Same accrual rule applies. Redeem deducts the protocol yield fee from the **interest portion only**, never from principal. The fee math lives entirely in `finish_redeem`:

```
interest         = max(0, redeemed_amount − principal_portion)
fee_amount       = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance    = redeemed_amount − fee_amount
```

`principal_portion` is the slice of stored principal proportional to the burned scoin: `principal_portion = floor(P_total × scoin_burned / S_total)` (see `pull_from_lending`).

Required PTB order:

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::start_redeem<T>(access, pm, market, scoin_amount)            → (coin_market, ticket)
3. protocol::redeem::redeem<T>(version, market, coin_market, clock)   → coin_t
4. cdpm::finish_redeem<T>(pm, fee_house, ticket, coin_t)
```

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
    target: `${SCALLOP_PROTOCOL}::accrue_interest::accrue_interest_for_market`,
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.object('0x6'),
    ],
  });

  const [coinMarket, ticket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::start_redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(SCALLOP_MARKET_ID),
      tx.pure.u64(scoinAmount),
    ],
  });

  const [coinT] = tx.moveCall({
    target: `${SCALLOP_PROTOCOL}::redeem::redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      coinMarket,
      tx.object('0x6'),
    ],
  });

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::finish_redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(pmId),
      tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
      ticket,
      coinT,
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

The post-fee underlying lands back in `pm.balance[T]`; you can withdraw it later with `user_remove_liquidity_from_balance`.

---

## Owner-Only Escape: Extract Raw sCoin

If Scallop ever becomes unreachable (paused, package upgrade frozen, etc.), the **owner** can still pull the raw `Coin<MarketCoin<T>>` out of the vault without touching any Scallop object:

```move
public fun user_extract_market_coin<T>(
    pm: &mut PositionManager,
    market_coin_amount: u64,
    ctx: &mut TxContext,
): Coin<MarketCoin<T>>
```

```typescript
async function userExtractMarketCoin(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  underlyingCoinType: string,
  scoinAmount: bigint,
) {
  const tx = new Transaction();

  const [coinMarket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_extract_market_coin`,
    typeArguments: [underlyingCoinType],
    arguments: [tx.object(pmId), tx.pure.u64(scoinAmount)],
  });

  tx.transferObjects([coinMarket], signer.toSuiAddress());
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

- Auth: `pm.owner == ctx.sender()` only — agents and protocol bots **cannot** call this.
- No yield fee is taken (the interest is still riding inside the sCoin), but the principal accounting is updated proportionally.
- The owner can then redeem the sCoin directly via Scallop, off the cdpm path.

---

## Closing a PositionManager With Active Vaults

`user_close_pm` now asserts `bag::is_empty(&pm.lending)` (`ELendingNotEmpty = 1004`). Before calling it you must, for every `T` vault, either:

1. `finish_redeem` the entire `scoin` balance back into underlying; or
2. `user_extract_market_coin` to pull the sCoin out to your wallet.

Either path leaves `pm.lending` empty, after which `user_close_pm` succeeds.

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

interface MarketCoinExtracted {
  pm_id: string;
  coin_type: string;
  market_coin_amount: u64;
  principal_removed: u64;
}
```

> Events no longer carry a separate `scoin_type` field — the sCoin type is always `MarketCoin<T>`, fully determined by `coin_type`. The events also do **not** carry a `by` field; Sui event envelopes already record the transaction sender, reach for `event.sender` if you need to distinguish owner / agent / protocol callers.

---

## Error Cheat Sheet

| Code | Constant | When |
|------|----------|------|
| 1001 | `ENotOwner` | `user_extract_market_coin` called by non-owner |
| 1002 | `ENotAllow` | `start_supply` / `start_redeem` failed `assert_caller_authorized` |
| 1004 | `ELendingNotEmpty` | `user_close_pm` while `pm.lending` is non-empty |
| 1005 | `ENoSuchVault` | `start_redeem` / `user_extract_market_coin` for an absent (T) entry |
| 1006 | `EReserveEmpty` | Scallop reserve has zero supply or zero `(cash+debt−revenue)` |
| 1007 | `EZeroExpected` | `start_supply` / `start_redeem` would yield 0 — amount too small |
| 1008 | `EWrongPm` | `finish_*` ticket consumed against a different PositionManager |
| 1009 | `EAmountShortfall` | `finish_*` Coin value `<` ticket.expected (stale accrual or Scallop slippage) |
