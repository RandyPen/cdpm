# Scallop Lending — Agent Operations

> **REQUIRED — every Scallop PTB starts with `accrue_interest_for_market`.**
> Any PTB that calls `scallop_start_supply` or `scallop_start_redeem` MUST have
> `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)`
> as **command 0**. cdpm enforces this on-chain: omitting the pre-step aborts at
> the cdpm boundary with `EStaleScallopState (1011)` before any balance is touched.
> The Scallop TS SDK helpers `scallopTx.deposit` / `depositQuick`
> (`sui-scallop-sdk/src/builders/coreBuilder.ts:139-148, 335-358`) do **NOT**
> inject this call — you must add it explicitly. There is no SDK shortcut and no
> optional path.

cdpm exposes a hot-potato lending integration with **Scallop** alongside Kai SAV. Agents authorized in `pm.agents` can drive supply / redeem against a Scallop `Market` exactly like they can against Kai, paying the same yield fee on interest. The same `assert_caller_authorized` gate inside `scallop_start_supply` / `scallop_start_redeem` admits **owner**, **agent**, or **whitelisted protocol bot in agents-empty mode**. `scallop_finish_*` only check `ticket.pm_id == object::id(pm)`.

This page is the agent-flavored counterpart to [`cdpm-user-sdk/reference/scallop-lending.md`](../../cdpm-user-sdk/reference/scallop-lending.md). It re-emphasizes (most critical first):

- **Pre-call accrual is mandatory; cdpm now enforces it.** Unlike Kai, Scallop's reserve is **not** auto-accruing per block. `scallop_start_supply` / `scallop_start_redeem` now take `&Clock` and assert `borrow_dynamics::last_updated_by_type(market.borrow_dynamics(), type<T>) == clock::timestamp_ms(clock) / 1000`. Omitting `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)` as command 0 aborts at the cdpm boundary with `EStaleScallopState (1011)` before any balance is touched. **This is non-negotiable for every Scallop PTB the agent signs.**
- **Canonical Market binding.** `start_*` records `market_id = object::id(market)` on the ticket; `scallop_finish_*` re-takes `&Market` and asserts the id matches, aborting with `EWrongMarket (1012)`. Reuse the same `tx.object(SCALLOP_MARKET_ID)` across `start_*` and `finish_*`.
- **Yield fee applies to agents.** `scallop_finish_redeem` computes `fee_amount = floor(max(0, redeemed − principal_portion) × fee_house.fee_rate / 10_000)` regardless of caller, so agent-driven Scallop redeems pay the same fee as owner / protocol redeems.
- **No escape hatch for lending.** cdpm does **not** expose a `user_extract_scallop_market_coin`-style wrapper-extraction function for anyone — neither agents nor the owner. If Scallop is unreachable (Version bump, paused market, etc.) the abort happens inside the inner `mint::mint` / `redeem::redeem` call before any cdpm `*_finish_*` command runs, so the hot-potato ticket is never consumed and `pm.lending` stays intact. Recovery is to retry the normal `scallop_start_redeem` → `redeem::redeem` → `scallop_finish_redeem` flow once Scallop ships an SDK update against the new Version; cdpm itself stays operational throughout.
- **Agents cannot short-change the vault.** `scallop_finish_supply` requires `Coin<MarketCoin<T>>` and asserts `actual >= ticket.expected_scoin`. `MarketCoin<T>` has only `drop` ability and no public constructor — the only way to obtain a non-zero `Coin<MarketCoin<T>>` is through Scallop's `protocol::mint::mint<T>`, so external code cannot mint a fake sCoin. The same defence applies on redeem (`Coin<T>` only comes out of `protocol::redeem::redeem<T>` after burning a real sCoin).

---

## Agent PTB Recipe: Supply

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

async function agentSupplyToScallop(
  client: SuiGrpcClient,
  agentSigner: any,
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

  return await client.signAndExecuteTransaction({ signer: agentSigner, transaction: tx });
}
```

`scallop_start_supply` decreases `pm.balance[T]` by `amount` and stores `principal` for later yield accounting under the bag key `type_name<T>`. The first supply for a given `T` creates a fresh `ScallopVault<T>` entry; subsequent supplies of the same `T` add to it.

**`MAX_U64` is a "drain whatever's there" sentinel.** `scallop_start_supply` pulls the underlying via the internal `withdraw_from_balance<T>` helper (`cdpm.move:1271-1286`), which clamps `amount >= balance_amount` and removes the bag entry; the post-clamp `coin.value()` is what feeds `compute_expected_scoin`. So passing `tx.pure.u64(MAX_U64)` consumes the entire `pm.balance[T]` entry, and the only remaining abort path is `EZeroExpected (1007)` if the entry is empty / dust. This mirrors `protocol_transfer_fee_to_balance`, which uses the same sentinel today (the helper has identical clamp logic in `withdraw_from_fee`, `cdpm.move:1301-1316`). Prefer the sentinel for atomic-rebalance flows where you'd otherwise have to dev-inspect the redeem residual and refeed it as `amount`. Use an explicit sized `amount` only when you intentionally want to leave a residual in `pm.balance[T]`.

**Don't accidentally re-supply your own redeem proceeds.** A common agent bug: redeem from Scallop, then immediately re-supply the post-fee underlying back into the same market. Each round trip pays a yield fee on the interest portion, so churn is expensive. Track time-since-last-redeem and amortize.

---

## Agent PTB Recipe: Redeem (with yield-fee deduction)

Same freshness rule applies. Redeem deducts the protocol yield fee from the **interest portion only**, never from principal. The fee math lives entirely in `scallop_finish_redeem` (mirrors `kai_finish_redeem`):

```
interest      = max(0, redeemed_amount − principal_portion)
fee_amount    = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance = redeemed_amount − fee_amount
```

`principal_portion` is the slice of stored principal proportional to the burned scoin: `principal_portion = floor(P_total × scoin_burned / S_total)` (see `pull_from_scallop_lending`).

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
async function agentRedeemFromScallop(
  client: SuiGrpcClient,
  agentSigner: any,
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

  return await client.signAndExecuteTransaction({ signer: agentSigner, transaction: tx });
}
```

### Sizing Redemptions Before Calling `scallop_start_redeem`

Agent bots typically know "I need `K` underlying to fund a rebalance" and must compute `market_coin_amount` from that. `scallop_start_redeem` takes sCoin, not underlying, so the bot has to invert `compute_expected_underlying_scallop` (and the yield-fee deduction) before signing.

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

Both use **ceiling division** because cdpm's prediction floors. The full derivation, edge cases (no-interest branch, vault drain, socialized loss), and an iterative refinement helper (`scoinToBurnForTargetNet`) live in [`cdpm-calculation-skill/reference/scallop-lending-math.md`](../../cdpm-calculation-skill/reference/scallop-lending-math.md) section 7.

```typescript
import {
  scoinToBurnForTargetUnderlying,
  scoinToBurnForTargetNet,
} from './scallop-lending-math';

async function agentRedeemForTargetNet(
  client: SuiGrpcClient,
  agentSigner: any,
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

  return agentRedeemFromScallop(
    client, agentSigner, pmId,
    underlyingCoinType, scoinAmount,
  );
}
```

The closed-form approximation is occasionally off-by-one due to per-step floors inside `scallop_finish_redeem`; the iterative helper bumps `N` upward by 1 sCoin until forward simulation confirms `>= desiredNet`. Re-snapshot the reserve and vault state *just after* the `accrue_interest_for_market` command and just before signing — utilization-driven `denom` shifts every block, and stale snapshots can leave the bot 1-2 underlying short.

### Don't Full-Drain a Lending Entry

**Agents must NOT pass `scoinAmount = MAX_U64` to `scallop_start_redeem`.** Scallop's upstream `protocol::redeem::redeem` uses the same single floor-div formula as cdpm's `compute_expected_underlying_scallop`, so in the common case the redeemed amount equals `expected_underlying` exactly — but full drain still leaves no margin if Scallop ever changes the rounding, and the same defensive cap applies for parity with Kai (where dust is real). The PM-state-machine side has another reason: leaving a small wrapper residual lets the owner's close-PM flow handle the final cleanup uniformly across both protocols.

Cap at `wrapperRaw − LENDING_SAFE_MARGIN_WRAPPER_RAW` (recommended client-side default `100n` sCoin raw) via the same `capRedeemBurnRaw` helper shown in [`cdpm-agent-sdk/reference/kai-lending.md`](./kai-lending.md#dont-full-drain-a-lending-entry) — it is protocol-agnostic. The residual sCoin is reclaimed by the owner's close-PM flow, which carries a small `coin::join` top-up. See [`cdpm-calculation-skill/reference/scallop-lending-math.md` §9.1](../../cdpm-calculation-skill/reference/scallop-lending-math.md#91-full-drain-dust-and-the-lending_safe_margin_wrapper_raw-floor) for the math.

---

## When to Call `scallop_start_supply` vs Leave Funds Idle

Yield-vs-gas tradeoff:

- **Supply when** the idle balance is large enough that the projected interest over the expected idle window exceeds the round-trip gas (4 commands per direction, ~6 commands total counting the matching redeem). For Sui mainnet this is usually a few hundred USDC at 5%+ supply APY held for >12 hours.
- **Stay idle when** the position is about to be rebalanced (next add/remove liquidity is queued in <1 hour) — the round-trip yield will not cover the supply+redeem gas.
- **Always supply** when `pm.balance[T]` accumulates accidentally from `protocol_transfer_fee_to_balance` and is not earmarked for an immediate use; even a few hours of yield are pure upside vs holding.

Agents that auto-supply should batch the accrual prefix + supply into **one** PTB to reduce gas overhead vs sending the accrual as a standalone tx.

---

## Pre-Flight: `accrue_interest_for_market` Snapshot Timing

cdpm's `compute_expected_scoin` / `compute_expected_underlying_scallop` are pure functions of `balance_sheet`. The protocol-tier and agent-tier off-chain SDKs both compute predictions from a snapshot of `Market` taken via `client.getObject`. If the snapshot was taken several blocks ago, the on-chain `balance_sheet` will have moved (interest accrued, utilization shifted) and the off-chain prediction will be off.

The fix is **two-step**:

1. PTB command 1 is always `accrue_interest_for_market` — this guarantees the on-chain `balance_sheet` matches the timestamp embedded in `clock` at execution time.
2. Off-chain, take the `Market` snapshot **after** the simulated accrue_interest (e.g. by `dryRunTransactionBlock` of just the accrue_interest command) and use it for sizing the next supply/redeem.

Skipping step 2 is fine for small amounts (a 1-2 unit shortfall is easily absorbed). For redeems aiming for `desiredNet >= 100 USDC`, always size after a fresh accrual snapshot.

---

## Failure Modes

| Code | Constant | Trigger | Recovery |
|------|----------|---------|----------|
| 1001 | `ENotOwner` | Agent attempted an owner-only function (e.g. `user_get_position` / `user_get_and_return_position`). | Escalate to owner. |
| 1002 | `ENotAllow` | Agent address removed from `pm.agents` between scheduling and signing. | Re-check `pm.agents` before retry. |
| 1005 | `ENoSuchVault` | `scallop_start_redeem` for a `T` that has never been supplied (or was fully drained). | Snapshot `pm.lending` before sizing. |
| 1006 | `EReserveEmpty` | Scallop reserve degenerate — zero supply or zero `cash+debt−revenue`. | Run the accrue prefix and re-check; if still degenerate, this market is unusable. |
| 1007 | `EZeroExpected` | Amount too small — `coin_amount × supply < denom` (supply) or `scoin_amount × denom < supply` (redeem). | Increase amount, or wait for the reserve to grow. |
| 1008 | `EWrongPm` | Hot-potato ticket consumed against a different PM. | Re-check the `pmId` you signed against. |
| 1009 | `EAmountShortfall` | Most common: agent passed `scoinAmount = MAX_U64` (full drain) — `protocol::redeem::redeem` floor-div dust trips the assert. Other: missing `accrue_interest_for_market` as command 0, or reserve state shifted between snapshot and signing. | Cap burn at `wrapperRaw − LENDING_SAFE_MARGIN_WRAPPER_RAW` (leave residual for owner close-PM); ALSO always run `accrue_interest_for_market` as PTB command 0; re-snapshot reserve just before sizing. |
| 1011 | `EStaleScallopState` | `scallop_start_*` reached cdpm without `accrue_interest_for_market` earlier in the same PTB second. | Make `accrue_interest::accrue_interest_for_market(version, market, clock)` PTB command 0 of every Scallop batch — cdpm enforces this. |
| 1012 | `EWrongMarket` | `scallop_finish_*` received a `&Market` whose id ≠ ticket.market_id. | Reuse the same `tx.object(SCALLOP_MARKET_ID)` handle across `start_*` and `finish_*`. |

External aborts (from Scallop itself, not cdpm): `protocol::version` mismatch after a Scallop upgrade, or a `protocol::market` pause. When these hit, the cdpm hot-potato ticket is never consumed (the abort happens inside the inner Scallop move-call before `scallop_finish_*` runs), so the PM state is intact. Pause Scallop ops on this market until upstream is healthy; once Scallop ships an SDK update against the new Version, retry the normal `scallop_start_redeem` → `redeem::redeem` → `scallop_finish_redeem` flow. cdpm offers no in-protocol bypass — there is no wrapper-extract escape for either owner or agent.

---

## Choosing Between Scallop and Kai for the Same `T`

Both integrations can hold the same underlying `T` simultaneously (the bag keys differ — `type_name<T>` for Scallop, `type_name<YT>` for Kai). When an agent has a free choice of where to park USDC:

| Factor | Prefer Scallop | Prefer Kai |
|--------|----------------|------------|
| Pre-flight gas | Adds 1 command (accrue_interest, **mandatory** — cdpm enforces freshness) | No accrual prefix |
| Redeem complexity | 1 inner call (`redeem::redeem`) | N+2 inner calls (strategy walk + `redeem_withdraw_ticket`) |
| Yield curve | Money-market APY (utilization-driven) | Aggregated strategies (often higher net of fees) |
| Withdrawal liquidity | Limited by `cash` (instant if available) | Limited by `total_available_balance` minus locked strategy capital |
| Failure surface | Scallop pause / version bump / `EStaleScallopState` if accrue is skipped | Kai admin disabling withdrawals, strategy losses, rate limits |

Default heuristic: if Kai has a `Vault<T, YT>` available for the underlying, prefer Kai for **long-idle balance** (>1 day expected hold) because the strategy diversification usually pays off. Prefer Scallop for **short-idle balance** (<1 day) because the redeem path is shorter. For mid-sized rebalances, split 50/50 across both — the bag-key disambiguation makes coexistence cost nothing.

Cross-reference: the agent-flavored Kai page is [`kai-lending.md`](./kai-lending.md). The yield-fee deduction is identical across both; the same `fee_house.fee_rate` knob covers both integrations.

---

## Event Subscription

Agents should subscribe to the Scallop-lending events alongside Kai's:

```typescript
interface ScallopSupplied {
  pm_id: string;
  coin_type: string;
  deposit_amount: u64;
  market_coin_minted: u64;
}

interface ScallopRedeemed {
  pm_id: string;
  coin_type: string;
  market_coin_redeemed: u64;
  redeemed_amount: u64;
  principal_portion: u64;
  interest: u64;
  fee_amount: u64;
}
```

cdpm emits no extraction event for Scallop lending — there is no wrapper-extract function. The only exit-related event on the Scallop side is `ScallopRedeemed`, emitted by `scallop_finish_redeem` once the underlying lands in `pm.balance`.
