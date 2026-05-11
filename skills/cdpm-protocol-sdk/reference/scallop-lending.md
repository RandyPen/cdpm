# Scallop Lending — Protocol Operations

> **REQUIRED — every Scallop PTB starts with `accrue_interest_for_market`.**
> Any PTB that calls `scallop_start_supply` or `scallop_start_redeem` MUST have
> `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)`
> as **command 0**. cdpm enforces this on-chain: omitting the pre-step aborts at
> the cdpm boundary with `EStaleScallopState (1011)` before any balance is touched.
> The Scallop TS SDK helpers `scallopTx.deposit` / `depositQuick`
> (`sui-scallop-sdk/src/builders/coreBuilder.ts:139-148, 335-358`) do **NOT**
> inject this call — you must add it explicitly. There is no SDK shortcut and no
> optional path. This applies to **every** Scallop touch from a protocol bot,
> agent, or owner.

cdpm exposes a hot-potato lending integration with **Scallop** alongside Kai SAV. The same protocol-tier authorization rules that apply to Kai apply to Scallop: a whitelisted protocol bot may drive `scallop_start_supply` / `scallop_start_redeem` against a `Market` only when `pm.agents` is empty. The gate inside `assert_caller_authorized` is the union `is_owner || is_agent || (is_in_access_list && pm.agents.is_empty())`.

`scallop_finish_*` only check `ticket.pm_id == object::id(pm)`. A correctly-shaped PTB therefore enforces protocol-tier access on the start side and binds the ticket to the same PM on the finish side.

---

## Why a Protocol Tier Wants Scallop Alongside Kai

Two dimensions of diversification:

1. **Underlying yield source.** Scallop is a money market (variable supply APY tied to utilization). Kai SAV aggregates strategies — leveraged supply on `kai_leverage::supply_pool`, vault-of-vaults on Scallop SAV strategies, etc. A protocol bot that periodically rebalances idle balance between the two diversifies the yield curve.
2. **Coexistence on a single PM.** The `pm.lending: Bag` keys Scallop entries by `type_name<T>` and Kai entries by `type_name<YT>`. A protocol bot can hold both `ScallopVault<USDC>` and `KaiVault<USDC, YUSDC>` simultaneously without bag collision.

The yield-fee math inside `scallop_finish_redeem` is **identical** to `kai_finish_redeem`:

```
interest      = max(0, redeemed_amount − principal_portion)
fee_amount    = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance = redeemed_amount − fee_amount
```

`fee_house.fee_rate` is shared across Scallop and Kai redeems. `admin_set_fee` caps it at `MAX_FEE_RATE = 3000` (30%); the default is `2000` (20%).

---

## Pre-Call Accrual Is Mandatory

Unlike Kai (which auto-accrues via `tlb::max_withdrawable` inside `total_available_balance`), Scallop needs the **first** PTB command to be `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)`. **cdpm now enforces this**: `scallop_start_supply` / `scallop_start_redeem` take `&Clock` and assert `borrow_dynamics::last_updated_by_type(market.borrow_dynamics(), type<T>) == clock::timestamp_ms(clock) / 1000`. Omitting the pre-step aborts at the cdpm boundary with `EStaleScallopState (1011)` before any balance is touched.

`scallop_finish_*` additionally re-take `&Market` and assert `object::id(market) == ticket.market_id`, aborting with `EWrongMarket (1012)` on mismatch. Pass the same `tx.object(SCALLOP_MARKET_ID)` handle across `start_*` and `finish_*`.

---

## Protocol PTB Recipe: Supply

Authoritative signatures:

```move
public fun scallop_start_supply<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    market: &Market,
    clock: &Clock,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<T>, ScallopSupplyTicket<T>);

public fun scallop_finish_supply<T>(
    pm: &mut PositionManager,
    market: &Market,
    ticket: ScallopSupplyTicket<T>,
    scoin: Coin<MarketCoin<T>>,
);
```

4 commands (accrual prefix + 3 main):

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::scallop_start_supply<T>(access, pm, market, clock, amount)       → (coin_t, ticket)
3. protocol::mint::mint<T>(version, market, coin_t, clock)                → coin_market<T>
4. cdpm::scallop_finish_supply<T>(pm, market, ticket, coin_market)
```

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function protocolSupplyToScallop(
  client: SuiGrpcClient,
  protocolSigner: any,         // address must be in AccessList AND pm.agents must be empty
  pmId: string,
  underlyingCoinType: string,
  amount: bigint,
) {
  const tx = new Transaction();

  // REQUIRED PTB[0] — cdpm asserts EStaleScallopState (1011) without this.
  // NOT injected by scallopTx.deposit / depositQuick.
  tx.moveCall({
    target: `${SCALLOP_PROTOCOL}::accrue_interest::accrue_interest_for_market`,
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.object('0x6'),
    ],
  });

  const [coinT, ticket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::scallop_start_supply`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(SCALLOP_MARKET_ID),
      tx.object('0x6'),
      tx.pure.u64(amount),
    ],
  });

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

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::scallop_finish_supply`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(pmId),
      tx.object(SCALLOP_MARKET_ID),
      ticket,
      coinMarket,
    ],
  });

  return await client.signAndExecuteTransaction({ signer: protocolSigner, transaction: tx });
}
```

---

## Protocol PTB Recipe: Redeem (with yield-fee deduction)

Same freshness rule applies. Redeem deducts the protocol yield fee from the **interest portion only**, never from principal — the deduction lives entirely in `scallop_finish_redeem`.

Authoritative signatures:

```move
public fun scallop_start_redeem<T>(
    access: &AccessList,
    pm: &mut PositionManager,
    market: &Market,
    clock: &Clock,
    market_coin_amount: u64,
    ctx: &mut TxContext,
): (Coin<MarketCoin<T>>, ScallopRedeemTicket<T>);

public fun scallop_finish_redeem<T>(
    pm: &mut PositionManager,
    market: &Market,
    fee_house: &mut FeeHouse,
    ticket: ScallopRedeemTicket<T>,
    underlying: Coin<T>,
    ctx: &mut TxContext,
);
```

4 commands:

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::scallop_start_redeem<T>(access, pm, market, clock, scoin_amount) → (coin_market, ticket)
3. protocol::redeem::redeem<T>(version, market, coin_market, clock)       → coin_t
4. cdpm::scallop_finish_redeem<T>(pm, market, fee_house, ticket, coin_t)
```

```typescript
async function protocolRedeemFromScallop(
  client: SuiGrpcClient,
  protocolSigner: any,
  pmId: string,
  underlyingCoinType: string,
  scoinAmount: bigint,
) {
  const tx = new Transaction();

  // REQUIRED PTB[0] — cdpm asserts EStaleScallopState (1011) without this.
  // NOT injected by scallopTx.deposit / depositQuick.
  tx.moveCall({
    target: `${SCALLOP_PROTOCOL}::accrue_interest::accrue_interest_for_market`,
    arguments: [
      tx.object(SCALLOP_VERSION_ID),
      tx.object(SCALLOP_MARKET_ID),
      tx.object('0x6'),
    ],
  });

  const [coinMarket, ticket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::scallop_start_redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(SCALLOP_MARKET_ID),
      tx.object('0x6'),
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
    target: `${CDPM_PACKAGE}::cdpm::scallop_finish_redeem`,
    typeArguments: [underlyingCoinType],
    arguments: [
      tx.object(pmId),
      tx.object(SCALLOP_MARKET_ID),
      tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
      ticket,
      coinT,
    ],
  });

  return await client.signAndExecuteTransaction({ signer: protocolSigner, transaction: tx });
}
```

### Sizing Redemptions Before Calling `scallop_start_redeem`

Protocol bots, like agents, usually know "I need `K` underlying for the next operation" and must compute `market_coin_amount` from that. `scallop_start_redeem` takes sCoin, not underlying.

- **Pre-fee target** — I need at least `K` underlying out of Scallop, ignoring fee:

  ```
  scoin_to_burn = ceil(K × supply / denom)            // denom = cash + debt − revenue
  ```

- **Post-fee target** — I want `K` net to land in `pm.balance[T]` after the yield fee. Closed-form (interest-exists branch, `p > π`):

  ```
  Let r = fee_rate / 10000, π = P_vault / S_vault, p = denom / supply
  scoin_to_burn ≈ ceil(K / (p × (1 − r) + r × π))
  ```

  No-interest branch (`p <= π`): `scoin_to_burn = ceil(K × supply / denom)` (fee is zero).

Both use **ceiling division** because cdpm's prediction floors. Asking for `floor(N)` risks receiving 1 unit fewer than the target. The full derivation, edge cases (no-interest branch, vault drain, socialized loss), and an iterative refinement helper (`scoinToBurnForTargetNet`) live in [`cdpm-calculation-skill/reference/scallop-lending-math.md`](../../cdpm-calculation-skill/reference/scallop-lending-math.md) section 7.

```typescript
import {
  scoinToBurnForTargetUnderlying,
  scoinToBurnForTargetNet,
} from './scallop-lending-math';

async function protocolRedeemForTargetNet(
  client: SuiGrpcClient,
  protocolSigner: any,
  pmId: string,
  underlyingCoinType: string,
  desiredNet: bigint,
  feeRateBp: bigint,
  reserveSnapshot: ScallopReserveSnapshot,
  pmScallopVault: ScallopPmVaultSnapshot,
) {
  const scoinAmount = scoinToBurnForTargetNet(
    reserveSnapshot, pmScallopVault, desiredNet, feeRateBp,
  );

  return protocolRedeemFromScallop(
    client, protocolSigner, pmId,
    underlyingCoinType, scoinAmount,
  );
}
```

`scoinToBurnForTargetNet` returns `MAX_U64` when the `ScallopVault<T>` entry cannot satisfy `desiredNet`; passing that value to `scallop_start_redeem` drains the entry and removes its bag entry from `pm.lending`. Always re-snapshot reserve and vault state *after* the `accrue_interest_for_market` command and before sizing — stale snapshots predict a higher `denom` than the live reserve and can leave the bot 1-2 underlying short.

---

## Protocol-Tier Permission Invariant

The protocol-tier branch of `assert_caller_authorized` *only* fires when `pm.agents.is_empty()`. Once the owner authorizes any agent, the protocol tier is locked out until every agent is revoked. This is the same rule Kai uses; it applies to both `scallop_start_supply` and `scallop_start_redeem`.

```typescript
async function validateProtocolScallopOperation(
  client: SuiGrpcClient,
  accessListId: string,
  pmId: string,
  protocolAddress: string,
): Promise<{ valid: boolean; reason?: string }> {
  const { response: accessList } = await client.getObject({
    id: accessListId,
    include: { content: true },
  });
  const allowed = accessList?.content?.fields?.allow || [];
  if (!allowed.includes(protocolAddress)) {
    return { valid: false, reason: 'Not in AccessList' };
  }

  const { response: pm } = await client.getObject({
    id: pmId,
    include: { content: true },
  });
  const agents = pm?.content?.fields?.agents || [];
  if (agents.length > 0) {
    return { valid: false, reason: 'Position has active agents' };
  }

  return { valid: true };
}
```

**No wrapper-extract escape for lending.** cdpm exposes no `user_extract_scallop_market_coin`-style function for anyone — not for protocol bots, not for the owner. If Scallop is impaired, no caller can rescue raw `Coin<MarketCoin<T>>` from `pm.lending`. The only exit is the full redeem flow (`scallop_start_redeem` → `redeem::redeem` → `scallop_finish_redeem`); if Scallop's `redeem::redeem` aborts (Version bump, paused market, etc.), the cdpm hot-potato ticket is never consumed, `pm.lending` stays intact, and recovery is to retry the normal flow once Scallop ships an SDK update against the new Version.

---

## Trust Boundary

cdpm imports only the read-only / hot-potato surface of Scallop (`protocol::market`, `protocol::reserve`, `x::wit_table`). It does **not** import `protocol::mint`, `protocol::redeem`, or `protocol::accrue_interest` — those are composed by the caller PTB. Even so, every protocol-tier supply/redeem still trusts the **Scallop team's upgrade-cap holder** to keep the inner Scallop modules honest: if a malicious upgrade ever made `mint::mint` short-deliver `Coin<MarketCoin<T>>`, cdpm's `EAmountShortfall (1009)` would refuse the supply, but a malicious upgrade could equally arrange for `redeem::redeem` to *over-deliver* to a particular caller, which cdpm cannot detect (the ticket only checks `>= expected`).

cdpm does **not** maintain an admin-side allowlist of acceptable Scallop `MarketCoin<T>` types — the `Coin<MarketCoin<T>>` type pin is the only shape check. A protocol-tier bot operator who is uncomfortable with this trust assumption should:

1. Maintain its own off-chain whitelist of acceptable `T` (e.g. only USDC / USDT / SUI).
2. Refuse to drive `scallop_start_supply<T>` for any `T` outside that whitelist.
3. Encourage owners to authorize agents (which automatically locks the protocol tier out of the same PM).

See `README` D-08 for the full trust-boundary discussion (the same paragraph covers the parallel Kai upgrade-cap assumption — see [`kai-lending.md`](./kai-lending.md)).

### Type-Pin Defense

`scallop_finish_supply<T>` takes `scoin: Coin<MarketCoin<T>>` directly. `MarketCoin<T>` has only `drop` ability and no public constructor — the only way to obtain a non-zero `Coin<MarketCoin<T>>` is through Scallop's `protocol::mint::mint<T>`. Combined with `assert!(scoin_amount >= ticket.expected_scoin, EAmountShortfall)`, a protocol bot cannot short-change the vault by substituting a forged or smaller real sCoin. The same defense applies on the redeem side: the underlying `Coin<T>` only comes out of `protocol::redeem::redeem<T>` after burning a real `Coin<MarketCoin<T>>`.

---

## Events Emitted by Protocol Scallop Operations

Identical event types as user/agent paths — Sui event envelopes already record `event.sender`, so the protocol address is observable without a separate `by` field.

```typescript
interface ScallopSupplied {
  pm_id: string;
  coin_type: string;          // type_name<T> — sCoin type is always MarketCoin<T>
  deposit_amount: u64;        // underlying transferred to Scallop
  market_coin_minted: u64;    // sCoin received and added to pm.lending
}

interface ScallopRedeemed {
  pm_id: string;
  coin_type: string;
  market_coin_redeemed: u64;  // sCoin burned
  redeemed_amount: u64;       // underlying received from Scallop, pre-fee
  principal_portion: u64;     // principal slice consumed by this redeem
  interest: u64;              // redeemed_amount − principal_portion (≥ 0)
  fee_amount: u64;            // protocol yield fee deducted from interest
}
```

cdpm emits no extraction event for Scallop lending — there is no wrapper-extract function. `ScallopRedeemed` is the only exit-related Scallop event and is emitted by `scallop_finish_redeem` once the underlying lands in `pm.balance`.

---

## Error Cheat Sheet (protocol-flavored)

| Code | Constant | Most likely cause for a protocol bot |
|------|----------|---------------------------------------|
| 1002 | `ENotAllow` | Either: protocol address not in AccessList, or PM has at least one agent (protocol-tier locked out). Snapshot `pm.agents` and `access.allow` before each batch. |
| 1004 | `ELendingNotEmpty` | Owner attempted `user_close_pm` while the protocol bot still has a Scallop entry in `pm.lending`. Coordinate with owner — drain via the full redeem flow before close (no wrapper-extract bypass exists). |
| 1005 | `ENoSuchVault` | `scallop_start_redeem` for a `T` with no entry. Re-fetch `pm.lending` before sizing. |
| 1006 | `EReserveEmpty` | Scallop reserve has zero supply or zero `(cash+debt-revenue)`. Run the accrual prefix and re-check; if still degenerate, skip this market. |
| 1007 | `EZeroExpected` | Amount too small for the current reserve ratio. Increase amount; for low-utilization markets, batch multiple PMs into one supply. |
| 1008 | `EWrongPm` | Hot-potato ticket consumed against a different PM. Bug in batch construction — assert `pmId` consistency across all four cdpm move-calls in the batch. |
| 1009 | `EAmountShortfall` | Stale Scallop accrual or reserve state moved between snapshot and signing. Always run `accrue_interest_for_market` as command 0 of the batch; for large redeems, size with a small margin via `scoinToBurnForTargetNet`. |
| 1011 | `EStaleScallopState` | `scallop_start_*` reached cdpm without `accrue_interest::accrue_interest_for_market(version, market, clock)` earlier in the same PTB second. cdpm enforces freshness — fix by making the accrue command 0 of every Scallop batch. |
| 1012 | `EWrongMarket` | `scallop_finish_*` received a `&Market` whose id ≠ ticket.market_id. Reuse the same `tx.object(SCALLOP_MARKET_ID)` handle across `start_*` and `finish_*`. |

External aborts that bubble up from Scallop itself (cdpm does not produce these) — typically a `protocol::version` mismatch after Scallop pushes an upgrade, or a `protocol::market` pause. When any of these hit, the cdpm hot-potato ticket is never consumed (the abort happens inside the inner Scallop move-call before `scallop_finish_*` runs), so the PM state is intact. The protocol bot reschedules once Scallop is upgraded / unpaused; cdpm offers no wrapper-extract bypass for either owner or protocol bot.
