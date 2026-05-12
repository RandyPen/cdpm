# Strategy Distributions (Spot / Curve / BidAsk)

When you call `sdk.Position.calculateAddLiquidityInfo({ ..., strategy_type })` the SDK turns your `(amount_a, amount_b, lower_bin_id, upper_bin_id, active_id)` into a per-bin breakdown by first computing a **weight** for every bin in the range, then prorating the amounts. The shape of that weight curve is the strategy.

This page documents the three built-in strategies — what they look like, the exact weight formula, when to use each, and the edge cases. All numbers below come from `cetus-sdk-v2/packages/dlmm/src/utils/weightUtils.ts` and `strategyUtils.ts`.

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

## Cross-references

- [Liquidity Calculation](liquidity-calculation.md) — the constant-sum `L = price·a + b` formula each per-bin amount feeds into.
- [Bin Price Calculations](bin-price-calculations.md) — converting between `bin_id`, Q64x64 price, and human-readable price (needed to choose `lower_bin_id` / `upper_bin_id`).
- [Position Management](position-management.md) — splitting a long bin range across multiple positions when it exceeds `MAX_BIN_PER_POSITION`.
