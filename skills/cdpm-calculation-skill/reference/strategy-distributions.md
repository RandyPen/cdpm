# Strategy Distributions (Spot / Curve / BidAsk)

## Contents

- [Constants](#constants)
- [The `StrategyType` enum](#the-strategytype-enum)
- [Weight formulas](#weight-formulas)
- [Side semantics (which coin sits where)](#side-semantics-which-coin-sits-where)
- [Strategy intent — when to pick what](#strategy-intent-when-to-pick-what)
- [Edge case — `active_id` outside the range (single-sided liquidity)](#edge-case-active_id-outside-the-range-single-sided-liquidity)
- [Computing weights / amounts directly](#computing-weights-amounts-directly)
- [On-chain vs SDK-computed distribution (Cetus-direct only)](#on-chain-vs-sdk-computed-distribution-cetus-direct-only)
- [Binding to the cdpm contract](#binding-to-the-cdpm-contract)
- [Per-bin shares for rebalance scheduling](#per-bin-shares-for-rebalance-scheduling)
- [Cross-references](#cross-references)

## Constants

```ts
// packages/dlmm/src/types/constants.ts
export const DEFAULT_MAX_WEIGHT = 2000
export const DEFAULT_MIN_WEIGHT = 200
```

`MAX/MIN = 10`, so the heaviest bin in a `Curve` or `BidAsk` distribution holds ~10× the liquidity of the lightest bin in the same range. `Spot` ignores both constants and uses `w = 1`.

## The `StrategyType` enum

```ts
// packages/dlmm/src/types/dlmm.ts
export enum StrategyType {
  Spot,    // 0
  Curve,   // 1
  BidAsk,  // 2
}
```

These ordinals matter: they are what the cdpm Move contract sees on-chain and what `addLiquidityPayload({ use_bin_infos: false, ... })` sends as a `u8` to let the contract recompute the distribution itself.

## Weight formulas

Let `delta = |bin_id − active_id|`, `N_left = active_id − lower_bin_id`, `N_right = upper_bin_id − active_id`. For a bin on the left side, `diff_min_weight = (MAX − MIN) / N_left`; on the right side, `diff_max_weight = (MAX − MIN) / N_right`. Then:

| Strategy | `bin_id < active_id` | `bin_id == active_id` | `bin_id > active_id` |
|---|---|---|---|
| `Spot` | `1` | `1` | `1` |
| `Curve` | `MAX − diff_min_weight × delta` | `MAX` | `MAX − diff_max_weight × delta` |
| `BidAsk` | `MIN + diff_min_weight × delta` | `MIN` | `MIN + diff_max_weight × delta` |

ASCII view of `[active_id − 5, active_id + 5]`:

```
Spot       ▁▁▁▁▁▁▁▁▁▁▁    flat — equal liquidity per bin
Curve      ▁▂▄▆▇█▇▆▄▂▁    bell — peak at the active bin
BidAsk     █▇▆▄▂▁▂▄▆▇█    valley — peaks at the edges (away from active)
```

## Side semantics (which coin sits where)

This is consistent across all three strategies and is enforced by the SDK regardless of the requested weights:

- `bin_id < active_id` → bin holds **only coin B** (the quote / "bid" side).
- `bin_id > active_id` → bin holds **only coin A** (the base / "ask" side).
- `bin_id == active_id` → bin can hold both coins; the split is derived from the active bin's existing reserves (`active_bin_of_pool.amount_a / amount_b`).

If you ask for liquidity on the wrong side, the SDK silently allocates `0` to that bin — the next swap would otherwise sweep it instantly. The weight curves above describe **how much** to put in each bin, not which coin goes where.

## Strategy intent — when to pick what

- **Spot** — flat exposure across the range. Best for stable pairs (e.g. USDC/USDT), passive LPing, or when you have no directional view. Lowest IL profile when price drifts inside the range, but also the least fee-dense around the current price.
- **Curve** — concentration at the current price. Maximises fee capture when the pair trades in a tight band around `active_id`. Highest IL if price walks away — most of your liquidity is right where it gets re-balanced through.
- **BidAsk** — DCA-style "buy low / sell high". Heaviest fills at the far ends of the range, lightest at the active bin. Good for volatile pairs you expect to mean-revert, or for laying out limit-order-style ladders. Also the natural choice for **single-sided** positions (see edge case below).

## Edge case — `active_id` outside the range (single-sided liquidity)

When `active_id < lower_bin_id` you are providing only coin A above the current price; when `active_id > upper_bin_id` you are providing only coin B below it. In these cases `toWeightCurve` and `toWeightBidAsk` degenerate to monotone distributions (`weightUtils.ts:171-241`):

| Position vs market | `Curve` falls back to | `BidAsk` falls back to |
|---|---|---|
| Ask-only, `active_id < min_bin_id` | descending (`max − i + 1`, heavy near current price) | ascending (`i − min + 1`, heavy far from current price) |
| Bid-only, `active_id > max_bin_id` | ascending (heavy near current price) | descending (heavy far from current price) |

`Spot` stays uniform (`w = 1`) in every case.

Intuition: `Curve` keeps "concentration near the action" — even when the action is at one edge of your range, the heaviest bin is the one closest to `active_id`. `BidAsk` keeps "concentration at the extremes" — heaviest bin is the one farthest from `active_id`.

## Computing weights / amounts directly

Most users never call these — they pass `strategy_type` into `sdk.Position.calculateAddLiquidityInfo(...)` and the SDK runs them internally. But when you want to inspect a distribution before sending a tx (e.g. to render a per-bin chart for the user), the utilities are public:

```ts
import { WeightUtils, StrategyUtils, StrategyType } from '@cetusprotocol/dlmm-sdk'

// Raw per-bin weights — useful for visualisation.
const spotW   = WeightUtils.toWeightSpotBalanced(lower_bin_id, upper_bin_id)
const curveW  = WeightUtils.toWeightCurve(lower_bin_id, upper_bin_id, active_id)
const bidAskW = WeightUtils.toWeightBidAsk(lower_bin_id, upper_bin_id, active_id)
// → [{ bin_id, weight }, ...]

// Full BinLiquidityInfo (per-bin amount_a / amount_b / liquidity).
const info = StrategyUtils.toAmountsBothSideByStrategy(
  active_id, bin_step, lower_bin_id, upper_bin_id,
  amount_a, amount_b,
  StrategyType.BidAsk,            // Spot / Curve / BidAsk
  active_bin_of_pool,             // optional: { amount_a, amount_b } in active bin
)
```

### Auto-fill (single-sided amount)

When you only have `amount_a` (or only `amount_b`) and want the SDK to derive the matching amount of the other coin, use the auto-fill variant — same shape, the SDK solves for the missing leg:

```ts
const info = StrategyUtils.autoFillCoinByStrategy(
  active_id, bin_step,
  '10000000',                     // the amount you have
  /* fix_amount_a */ true,        // true = you fixed coin A, false = coin B
  lower_bin_id, upper_bin_id,
  StrategyType.Curve,
  active_bin_of_pool,
)
```

In normal SDK usage this is reached via `sdk.Position.calculateAddLiquidityInfo({ coin_amount, fix_amount_a, ... })` — same result, friendlier interface.

## On-chain vs SDK-computed distribution (Cetus-direct only)

`sdk.Position.addLiquidityPayload(...)` accepts a `use_bin_infos: boolean` flag:

- `use_bin_infos: false` — only `strategy_type` is sent on-chain; the Cetus pool recomputes the per-bin amounts itself. Smaller PTB.
- `use_bin_infos: true` — the pre-computed `BinLiquidityInfo` is sent in full. Lets you simulate and display the breakdown locally; PTB is bigger.

**This flag is irrelevant when the path goes through cdpm.** The cdpm Move entries below take pre-computed `(bins, amounts_a, amounts_b)` vectors only — there is no `strategy_type` argument on-chain, so the SDK distribution math always has to run off-chain. See the next section.

## Binding to the cdpm contract

`sources/cdpm.move` exposes four entry points that add liquidity to a `PositionManager`-owned `Position`. All four take the same parallel-vector shape:

```move
public fun user_deposit_liquidity<CoinTypeA, CoinTypeB>(
    record, pool, coin_a, coin_b,
    bins:      vector<u32>,
    amounts_a: vector<u64>,
    amounts_b: vector<u64>,
    config, versioned, clk, ctx,
)

public fun user_add_liquidity_to_position<CoinTypeA, CoinTypeB>(
    pm, pool, coin_a, coin_b,
    bins, amounts_a, amounts_b,
    config, versioned, clk, ctx,
)

public fun protocol_add_liquidity<CoinTypeA, CoinTypeB>(
    op, pm, pool, coin_a, coin_b,
    bins, amounts_a, amounts_b,
    config, versioned, clk, ctx,
)

public fun agent_add_liquidity<CoinTypeA, CoinTypeB>(
    pm, pool, coin_a, coin_b,
    bins, amounts_a, amounts_b,
    config, versioned, clk, ctx,
)
```

**The contract knows nothing about `StrategyType`.** Inside, all four call into a private `add_liquidity_private(...)` helper which forwards `(bins, amounts_a, amounts_b)` straight to `cetus_dlmm::pool::add_liquidity` (`cdpm.move:1218-1256`). That means:

1. Off-chain, the caller must pick a strategy and a bin range.
2. Off-chain, the SDK turns `(strategy_type, lower_bin_id, upper_bin_id, active_id, amount_a, amount_b)` into a `BinLiquidityInfo` (per-bin amounts).
3. Off-chain, the caller flattens `BinLiquidityInfo.bins[]` into the three parallel vectors.
4. PTB time, those vectors get pushed as `tx.pure.vector(...)` arguments to the cdpm Move call.

### Reference flow — strategy → cdpm PTB

```ts
import { Transaction } from '@mysten/sui/transactions'
import {
  CetusDlmmSDK,
  StrategyType,
  StrategyUtils,
  BinUtils,
} from '@cetusprotocol/dlmm-sdk'

const sdk = CetusDlmmSDK.createSDK({ env: 'mainnet' })

// 1) Pick a strategy + range.
const pool = await sdk.Pool.getPool(poolId)
const { active_id, bin_step, coin_type_a, coin_type_b } = pool

const lowerPrice = '0.99'
const upperPrice = '1.01'
const lower_bin_id = BinUtils.getBinIdFromPrice(lowerPrice, bin_step, true, 6, 6)
const upper_bin_id = BinUtils.getBinIdFromPrice(upperPrice, bin_step, true, 6, 6)

// 2) Read what's currently in the active bin (so the active-bin split is correct).
const active_bin_of_pool = await sdk.Position.getActiveBinIfInRange(
  pool.bin_manager.bin_manager_handle,
  lower_bin_id,
  upper_bin_id,
  active_id,
  bin_step,
)

// 3) Compute the distribution off-chain.
//    Either via the high-level SDK helper:
const bin_infos = await sdk.Position.calculateAddLiquidityInfo({
  pool_id: poolId,
  amount_a, amount_b,
  active_id, bin_step,
  lower_bin_id, upper_bin_id,
  active_bin_of_pool,
  strategy_type: StrategyType.BidAsk,    // Spot / Curve / BidAsk
})
//    …or via StrategyUtils directly when you want to skip the SDK layer:
// const bin_infos = StrategyUtils.toAmountsBothSideByStrategy(
//   active_id, bin_step, lower_bin_id, upper_bin_id,
//   amount_a, amount_b, StrategyType.BidAsk, active_bin_of_pool,
// )

// 4) Flatten into the three parallel vectors cdpm expects.
//    NB: bin_id is signed (i32) in the SDK but the Move type is u32.
//    The on-chain layout uses two's-complement, NOT a +BIN_BOUND offset —
//    Cetus's own SDK serialises with `BigInt.asUintN(32, BigInt(bin_id))`
//    (positionModule.ts:439-468). Mirror that here.
const toU32 = (n: number) => Number(BigInt.asUintN(32, BigInt(n)))

const bins      = bin_infos.bins.map(b => toU32(b.bin_id))
const amounts_a = bin_infos.bins.map(b => BigInt(b.amount_a))
const amounts_b = bin_infos.bins.map(b => BigInt(b.amount_b))

// 5) Build the cdpm PTB.
const tx = new Transaction()
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::user_add_liquidity_to_position`,
  typeArguments: [coin_type_a, coin_type_b],
  arguments: [
    tx.object(pmId),
    tx.object(poolId),
    tx.object(coinAObjectId),       // mut Coin<CoinTypeA>
    tx.object(coinBObjectId),       // mut Coin<CoinTypeB>
    tx.pure.vector('u32', bins),
    tx.pure.vector('u64', amounts_a),
    tx.pure.vector('u64', amounts_b),
    tx.object(globalConfigId),
    tx.object(versionedId),
    tx.object('0x6'),               // clock
  ],
})
```

`user_deposit_liquidity` (open new PM), `protocol_add_liquidity` (Op-gated) and `agent_add_liquidity` (delegated agent) take an analogous argument list — only the first few non-vector arguments differ. The `(bins, amounts_a, amounts_b)` triple is identical.

### Practical implications

- **No on-chain strategy enum** → the strategy choice is purely a UX/agent decision. cdpm cannot validate that the caller's distribution matches a declared strategy; it just consumes the vectors. Off-chain agents are free to invent custom shapes (e.g. mixed Curve+BidAsk, asymmetric ladders) by hand-crafting `(bins, amounts_a, amounts_b)` and skipping `StrategyUtils` entirely.
- **Side-rule still applies** → cdpm forwards to `cetus_dlmm::pool::add_liquidity`, which enforces the bid-vs-ask side-coin rule (coin B for bins below `active_id`, coin A above). Sending `amount_a > 0` to a bin with `bin_id < active_id` will revert in the Cetus layer, not in cdpm. Always derive the vectors from a `StrategyUtils` / `calculateAddLiquidityInfo` output rather than hand-rolling, unless you understand that constraint.
- **`bins` length cap** → both cdpm and the underlying Cetus pool inherit `MAX_BIN_PER_POSITION = 1000`. For wider ranges, split with `BinUtils.splitBinLiquidityInfo(bin_infos, start, end)` and emit one `user_deposit_liquidity` per chunk, or pre-open multiple `PositionManager`s.
- **`bin_id` signedness** → `tx.pure.vector('u32', [-1, 0, 1])` will error at PTB serialisation time. Always pre-cast with `Number(BigInt.asUintN(32, BigInt(bin_id)))`. Existing snippets in [Position Management](../../cdpm-user-sdk/reference/position-management.md) that pass raw `number[]` work only when every bin in the range is non-negative — beware near `bin_id = 0`.
- **`use_bin_infos` is a Cetus-only flag** → it only affects `sdk.Position.addLiquidityPayload(...)` (the Cetus-direct path). cdpm's own entries always behave as if `use_bin_infos: true`, since they take per-bin vectors and never the strategy enum.
- **Removal is symmetric** → `sdk.Position.calculateRemoveLiquidityInfo({ bins, ... })` → flatten → `cdpm::user_remove_liquidity` / `agent_remove_liquidity` (`cdpm.move:151+, 275+`). The same `bin_id → u32` two's-complement cast applies.

## Per-bin shares for rebalance scheduling

A rebalance scheduler that holds capital across (idle PM balance + Scallop sCoin + Kai YT + active position) needs more than the absolute per-bin amounts that `StrategyUtils` produces. Before each tick it has to ask: *"of the coin A I'm about to deposit, how much lands in each bin? what's the bid-side / ask-side total? how does it map to value at the active price?"* The strategy gives you the **shape**; the share table below turns that shape into the **fractions** you scale up or down by when redeeming from lending.

### Helper — `binShareTable(bin_infos, bin_step)`

Pure post-processing of a `BinLiquidityInfo`. No new SDK call, no on-chain reads. Pair it with `StrategyUtils.toAmountsBothSideByStrategy(...)` (or `sdk.Position.calculateAddLiquidityInfo(...)`):

```ts
import { d } from '@cetusprotocol/common-sdk'
import { BinUtils, type BinLiquidityInfo } from '@cetusprotocol/dlmm-sdk'
import Decimal from 'decimal.js'

type BinShareRow = {
  bin_id: number
  amount_a: string
  amount_b: string
  share_a: string        // amount_a / total_a, "0" if total_a == 0
  share_b: string        // amount_b / total_b, "0" if total_b == 0
  share_value: string    // bin_value_b / total_value_b, denominated in coin B
}

type BinShareTable = {
  total_a: string
  total_b: string
  total_value_b: string  // Σ (price_i · amount_a_i + amount_b_i)
  rows: BinShareRow[]
}

// price_i is the per-lamport price of bin i in coin B per coin A.
// Using `getPricePerLamportFromBinId` keeps decimals consistent with the
// amounts Cetus stores (raw lamports), so total_value_b stays integer-clean.
function binShareTable(
  info: BinLiquidityInfo,
  bin_step: number,
): BinShareTable {
  const total_a = d(info.amount_a)
  const total_b = d(info.amount_b)

  // L = price · a + b, summed and denominated in coin B.
  let total_value = d(0)
  const value_per_bin: Decimal[] = info.bins.map((b) => {
    const price = d(BinUtils.getPricePerLamportFromBinId(b.bin_id, bin_step))
    const v = price.mul(d(b.amount_a)).add(d(b.amount_b))
    total_value = total_value.add(v)
    return v
  })

  const safeRatio = (num: Decimal, den: Decimal) =>
    den.isZero() ? '0' : num.div(den).toString()

  const rows: BinShareRow[] = info.bins.map((b, i) => ({
    bin_id: b.bin_id,
    amount_a: b.amount_a,
    amount_b: b.amount_b,
    share_a: safeRatio(d(b.amount_a), total_a),
    share_b: safeRatio(d(b.amount_b), total_b),
    share_value: safeRatio(value_per_bin[i], total_value),
  }))

  return {
    total_a: total_a.toString(),
    total_b: total_b.toString(),
    total_value_b: total_value.toString(),
    rows,
  }
}
```

`Decimal` (via `d()` from `@cetusprotocol/common-sdk`) avoids the float drift that `Number(amount_a) / Number(total_a)` would produce on `u64`-scale lamport values. The same `d()` is used throughout `weightUtils.ts` and `strategyUtils.ts`, so the share output composes cleanly with anything else you build on top.

### Worked example — `Curve` over `[active_id − 3, active_id + 3]`

Inputs: stable pair (price ≈ 1, both decimals = 6), `bin_step = 2`, `amount_a = 1_000_000`, `amount_b = 1_000_000`. With `MAX_WEIGHT = 2000`, `MIN_WEIGHT = 200`, `Curve` produces a symmetric bell:

Coin-B weights are `[200, 800, 1400, 1000]` for bins `[−3, −2, −1, 0]` — `MAX − diff·delta` for the bid side (`diff = (2000−200)/3 = 600`), then the active bin gets half-`MAX` from `calculateActiveWeights`'s empty-active branch (`weightUtils.ts:594`, fires when the caller passes `active_bin_of_pool = { amount_a: '0', amount_b: '0' }`; if `active_bin_of_pool` is `undefined` the active bin is skipped entirely). This is also the bridge to the **Weight formulas** table near the top of this doc — there `Curve`'s active-bin weight is listed as `MAX = 2000`, which is the *base* before the half-split assigns `MAX/2` to coin B and `MAX/(2·p₀)` to coin A. Coin A here is the mirror image of coin B. The resulting share table:

| bin offset | amount_a   | amount_b   | share_a | share_b | share_value |
|-----------:|-----------:|-----------:|--------:|--------:|------------:|
|  −3 (bid)  |          0 |     58_800 |   0.0%  |   5.88% |      2.94%  |
|  −2 (bid)  |          0 |    235_300 |   0.0%  |  23.53% |     11.77%  |
|  −1 (bid)  |          0 |    411_800 |   0.0%  |  41.18% |     20.59%  |
|   0 (act)  |    294_100 |    294_100 |  29.41% |  29.41% |     29.41%  |
|  +1 (ask)  |    411_800 |          0 |  41.18% |   0.0%  |     20.59%  |
|  +2 (ask)  |    235_300 |          0 |  23.53% |   0.0%  |     11.77%  |
|  +3 (ask)  |     58_800 |          0 |   5.88% |   0.0%  |      2.94%  |
| **total**  |  1_000_000 |  1_000_000 | 100.0%  | 100.0%  |    100.0%   |

Two non-obvious things to take away from the per-coin columns:

- The **immediate neighbour** of the active bin holds the largest *single-coin* share (`41.18%` at bin ±1), not the active bin itself. That's the active-bin half-split at work — coin A and coin B each get only half of `MAX_WEIGHT` at the active bin, so the very next bin out beats it on a per-coin basis.
- In **value terms**, the active bin is still the heaviest at `29.41%` of `share_value`. That's the real concentration `Curve` delivers, and it's only visible once you collapse coin A and coin B into a single value column.

Switching to `Spot` would make every cell ≈ `14.3%`; switching to `BidAsk` would invert the bell so the edge bins dominate (`share_value` peaks at ±3) and the active bin shows the smallest share.

### Reading the table

- **Side rule shows up structurally.** Bid-side bins (`bin_id < active_id`) have `share_a == 0`, ask-side bins (`bin_id > active_id`) have `share_b == 0`. The active bin is the only one that can be non-zero in both columns.
- **Column sums.** `Σ share_a == 1`, `Σ share_b == 1`, `Σ share_value == 1`. **Per-row sums are not meaningful** — `share_a + share_b` for a single bin is just two unrelated fractions of two different totals.
- **`share_value` is the single number to compare across strategies.** It tells you what fraction of the *total deposited LP value* lives at each bin, which is what you actually care about when projecting fee accrual or IL.

### Coupling to lending — sizing the redeem

Once you have `total_a` / `total_b` from the share table, the gap vs. idle PM balance is what you redeem from lending:

```ts
const shortfall_a = max(0n, BigInt(table.total_a) - idleA)
const shortfall_b = max(0n, BigInt(table.total_b) - idleB)
```

Feed each non-zero shortfall to the existing inverse-sizing helpers — they tell you exactly how much sCoin / YT to burn so the post-fee underlying lands in `pm.balance[T]`:

- `scoinToBurnForTargetUnderlying(...)` → see [Scallop Lending Math §7](scallop-lending-math.md) — when coin A or B sits in `pm.lending` as Scallop sCoin.
- `ytToBurnForTargetUnderlying(...)` → see [Kai SAV Lending Math §7](kai-lending-math.md) — same idea for Kai YT.

If a redeem comes back short (e.g. Scallop `cash` is thin and you only got back 80% of `shortfall_a`), don't recompute the strategy — just **scale every row by 0.8** and re-flatten. The share columns make this trivial and the result is still a valid `Curve` / `BidAsk` / `Spot` distribution at smaller capital. cdpm has no on-chain `strategy_type` validation (see *Practical implications → No on-chain strategy enum* above), so this scaled-down vector goes straight into `user_add_liquidity_to_position` / `agent_add_liquidity` unchanged.

## Cross-references

- [Liquidity Calculation](liquidity-calculation.md) — the constant-sum `L = price·a + b` formula each per-bin amount feeds into.
- [Bin Price Calculations](bin-price-calculations.md) — converting between `bin_id`, Q64x64 price, and human-readable price (needed to choose `lower_bin_id` / `upper_bin_id`).
- [Position Management](position-management.md) — splitting a long bin range across multiple positions when it exceeds `MAX_BIN_PER_POSITION`.
