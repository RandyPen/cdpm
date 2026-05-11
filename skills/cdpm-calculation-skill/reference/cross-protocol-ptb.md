# Composing a Cross-Protocol PTB (cdpm + Scallop + Kai)

cdpm wraps both Scallop and Kai SAV with a hot-potato ticket pattern (`scallop_start_*` / `kai_start_*` returning a no-`drop` no-`store` no-`key` ticket that must be consumed by `*_finish_*` in the same PTB). Single-protocol PTB recipes for each side live in [`scallop-lending-math.md`](./scallop-lending-math.md) §10.5 and [`kai-lending-math.md`](./kai-lending-math.md) §10.5. **This page covers the bridge** — how a third-party developer composes cdpm raw `moveCall`s, Scallop SDK builders, and Kai SDK builders into a single Mysten `Transaction`, including the atomic Scallop ↔ Kai rebalance flow.

The two sub-pages cover the **what** of each SDK's builder surface; this page covers the **how** of putting them together.

---

## 1. Interop Fact: One Mysten `Transaction` Backs All Three

Both SDKs are built on top of Mysten's `Transaction` from `@mysten/sui/transactions`, and both expose entry points that accept an externally-supplied `Transaction`:

| Side | Entry point | Behavior |
|------|-------------|----------|
| Scallop | `scallopBuilder.createTxBlock(tx?: Transaction)` | If `tx` is a Mysten `Transaction`, it is *adopted* via `instanceof Transaction ? new SuiKitTxBlock(initTxBlock) : ...` (`sui-scallop-sdk/src/builders/coreBuilder.ts:483-488`). The returned `ScallopTxBlock` is a `Proxy` over `SuiKitTxBlock`, whose `.txBlock` field IS the same Mysten `Transaction` you handed in. |
| Kai | `vault.deposit(tx, balance)` / `vault.withdraw(tx, balance, strategies)` | `tx` is typed as Mysten `Transaction` directly (`kai-ts-sdk/src/vault/vault.ts:177,222`). Returns tx-result `Balance` arguments. |
| cdpm | raw `tx.moveCall({ target: \`${CDPM_PACKAGE}::cdpm::*\`, ... })` | cdpm has no published TS bindings; calls go straight on the Mysten `Transaction`. |

Because all three accept the same `Transaction` instance, you can interleave their move-calls in one PTB and submit it once. **This is mandatory**, not just an optimization: the cdpm hot-potato ticket has no `store`/`key`/`drop` and cannot survive across transactions. Two-transaction designs are categorically incompatible with cdpm's surface.

---

## 2. Approach Comparison

| Approach | Description | Atomicity | Gas | Upgrade resilience | Type safety | Dependency surface | Viable? |
|----------|-------------|-----------|-----|---------------------|-------------|--------------------|---------|
| **A. All raw `tx.moveCall`** | Hardcode `SCALLOP_VERSION_ID`, `SCALLOP_MARKET_ID`, `KAI_SAV_PACKAGE`, type tags; call `protocol::mint::mint` / `kai_sav::vault::deposit` directly. | ✓ | 1 PTB | ✗ — every Scallop/Kai upgrade requires a cdpm-side constant edit | Weak (string targets) | None | ✓ |
| **B. Mysten-rooted shared `Transaction`** *(recommended)* | `new Transaction()`; pass to `scallopBuilder.createTxBlock(tx)` *only if* the PTB needs Scallop; pass to `kaiVault.deposit/withdraw(tx, …)` *only if* it needs Kai; cdpm calls remain raw on `tx`. | ✓ | 1 PTB | ✓ — SDK absorbs inner-protocol upgrades | Medium (SDK methods typed; cdpm raw) | Both SDKs | ✓ |
| **C. Scallop-rooted** | `builder.createTxBlock()` (no tx arg) makes a fresh wrapper; reach the underlying Mysten `Transaction` via `scallopTx.txBlock` and pass that to Kai/cdpm. | ✓ | 1 PTB | ✓ | Medium | Both SDKs (Scallop init mandatory even when only Kai is touched) | ✓ but unnecessarily couples to Scallop lifecycle |
| **D. Two separate PTBs** | Send one tx to redeem from venue A, second tx to supply to venue B. | ✗ — cdpm ticket cannot cross tx boundaries | 2 PTB | ✓ | High | Both SDKs | ✗ violates cdpm hot-potato invariant |
| **E. Pure SDK end-to-end** | Use only `*Quick` (Scallop) / `vault.depositFromWallet` (Kai). | n/a | n/a | n/a | n/a | n/a | ✗ cdpm has no TS bindings; the cdpm calls must still be raw `moveCall` |

**A vs B vs C is the real choice** (D and E are categorically out).

- **A vs B**: identical at runtime; B wins on upgrade resilience and call-site readability. Scallop and Kai both ship frequent upgrades — Scallop has migrated `MarketCoin` / sCoin types and bumped market-package ids; Kai adds strategies and vault entries. With A you chase those changes manually in cdpm; with B the SDK absorbs them.
- **B vs C**: identical at runtime (same `Transaction` instance underneath). B is more decoupled — only construct a Scallop builder when the flow actually touches Scallop. C forces every caller to pay the Scallop init round-trip even for Kai-only flows.

**Recommendation: B — Mysten-rooted shared Transaction.**

---

## 3. Canonical Pattern

```typescript
import { Transaction } from '@mysten/sui/transactions';
import { Scallop } from '@scallop-io/sui-scallop-sdk';
import { VAULTS } from '@kunalabs-io/kai';

// Singletons — instantiate once at app boot, reuse across calls.
const scallop = new Scallop({ addressId: '67c44a103fe1b8c454eb9699', networkType: 'mainnet' });
const builder = await scallop.createScallopBuilder();
const query   = await scallop.createScallopQuery();

// Per-PTB — instantiate fresh.
const tx = new Transaction();
tx.setSender(senderAddress);                       // required before any *Quick method

// Mount Scallop side onto `tx` — only when the PTB needs Scallop.
const scallopTx = builder.createTxBlock(tx);       // adopts tx; same instance underneath

// Kai side takes plain Mysten Transaction directly.
const kaiVault  = VAULTS.suiUSDT;

// All cdpm calls are raw moveCall on `tx`.
// All Scallop inner calls go via scallopTx.deposit / scallopTx.withdraw.
// All Kai inner calls go via kaiVault.deposit(tx, …) / kaiVault.withdraw(tx, …).

await client.signAndExecuteTransaction({ signer, transaction: tx });
//                                                    ^^^ — NOT scallopTx
```

`scallopTx` is a `Proxy` wrapper; passing it to `signAndExecuteTransaction` would be rejected because the API checks for `Transaction`. Sign with the underlying `tx`. The Scallop convenience helper `scallopBuilder.signAndSendTxBlock(scallopTx)` exists and works because it unwraps `.txBlock` internally — pick whichever fits your call site.

---

## 4. Worked Examples

### 4.1 Single-Protocol Supply (Picker → Scallop)

```typescript
import { Transaction } from '@mysten/sui/transactions';

const tx = new Transaction();
tx.setSender(senderAddress);

const [coinT, ticket] = tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_start_supply`,
  typeArguments: [underlyingCoinType],
  arguments: [
    tx.object(ACCESS_LIST_ID),
    tx.object(pmId),
    tx.object(SCALLOP_MARKET_ID),
    tx.pure.u64(amount),
  ],
});

const scallopTx  = builder.createTxBlock(tx);
const coinMarket = scallopTx.deposit(coinT, 'usdc');   // wraps protocol::mint::mint, auto-accrues

tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_finish_supply`,
  typeArguments: [underlyingCoinType],
  arguments: [tx.object(pmId), ticket, coinMarket],
});

await client.signAndExecuteTransaction({ signer, transaction: tx });
```

### 4.2 Single-Protocol Supply (Picker → Kai)

No Scallop builder needed — Kai composes onto `tx` directly:

```typescript
const tx = new Transaction();
tx.setSender(senderAddress);

const [coinT, ticket] = tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_start_supply`,
  typeArguments: [T, YT],
  arguments: [
    tx.object(ACCESS_LIST_ID),
    tx.object(pmId),
    tx.object(KAI_VAULT_ID),
    tx.pure.u64(amount),
    tx.object('0x6'),
  ],
});

const balanceT  = tx.moveCall({
  target: '0x2::coin::into_balance', typeArguments: [T], arguments: [coinT],
});
const balanceYT = kaiVault.deposit(tx, balanceT);
const coinYT    = tx.moveCall({
  target: '0x2::coin::from_balance', typeArguments: [YT], arguments: [balanceYT],
});

tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_finish_supply`,
  typeArguments: [T, YT],
  arguments: [tx.object(pmId), ticket, coinYT],
});

await client.signAndExecuteTransaction({ signer, transaction: tx });
```

### 4.3 Atomic Rebalance: Scallop → Kai (one PTB)

The whole point of sharing a `Transaction`: redeem from Scallop and supply to Kai in one shot. Either both legs commit or neither does — atomic by Move/PTB semantics.

```typescript
const tx = new Transaction();
tx.setSender(senderAddress);
const scallopTx = builder.createTxBlock(tx);

// === Leg 1: redeem from Scallop. Net underlying lands in pm.balance[T] ===
const [coinMarket, redeemTicket] = tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_start_redeem`,
  typeArguments: [T],
  arguments: [
    tx.object(ACCESS_LIST_ID), tx.object(pmId),
    tx.object(SCALLOP_MARKET_ID),
    tx.pure.u64(scoinAmount),                      // sized via §7 inverse helpers
  ],
});
const coinT = scallopTx.withdraw(coinMarket, 'usdc');     // tx-result Coin<T>
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_finish_redeem`,
  typeArguments: [T],
  arguments: [tx.object(pmId), tx.object(FEE_HOUSE_ID), redeemTicket, coinT],
});
//   pm.balance[T] is now incremented by the post-fee underlying.

// === Leg 2: supply that same underlying into Kai ===
const [coinT2, supplyTicket] = tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_start_supply`,
  typeArguments: [T, YT],
  arguments: [
    tx.object(ACCESS_LIST_ID), tx.object(pmId),
    tx.object(KAI_VAULT_ID),
    tx.pure.u64(supplyAmount),                     // typically the redeemed-and-fee'd amount
    tx.object('0x6'),
  ],
});
const balanceT  = tx.moveCall({
  target: '0x2::coin::into_balance', typeArguments: [T], arguments: [coinT2],
});
const balanceYT = kaiVault.deposit(tx, balanceT);
const coinYT    = tx.moveCall({
  target: '0x2::coin::from_balance', typeArguments: [YT], arguments: [balanceYT],
});
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_finish_supply`,
  typeArguments: [T, YT],
  arguments: [tx.object(pmId), supplyTicket, coinYT],
});

await client.signAndExecuteTransaction({ signer, transaction: tx });
```

Properties:

- **Atomicity**: any abort along the chain (e.g., Scallop pause, Kai TVL cap, prediction shortfall) reverts the whole PTB. The redeem leg's `scallop_finish_redeem` already settled `pm.balance[T]` mid-PTB, but PTB rollback puts everything back as if the tx never ran.
- **Sizing the Kai supply leg**: the simplest design uses the predicted `toBalance` from `predictRedeem` (Scallop §6) as `supplyAmount`. Two effects can leave the live redeem 1-2 underlying above the prediction: per-step floor rounding inside `compute_expected_underlying_scallop` (at most 1 unit, see Scallop §7.2) and `balance_sheet` advance between off-chain prediction and on-chain execution (the pre-flight `accrue_interest_for_market` minimizes but does not eliminate this — see Scallop §8). The residual stays in `pm.balance[T]` and is not catastrophic. To capture the residual atomically, dev-inspect `pm.balance[T]` after a simulated redeem and feed that exact figure into `kai_start_supply`'s `amount`; alternatively, accept the small idle leak and re-park on the next rebalance cycle.
- **Yield-fee**: paid once on the Scallop side at redeem; the supply leg incurs no fee (cdpm fees only on redeem). Net: one fee per round trip.

### 4.4 Atomic Rebalance: Kai → Scallop

Mirror of §4.3 — start with `kai_start_redeem` + `vault.withdraw(tx, balanceYT, kaiVault.getStrategies())`, end with `scallop_start_supply` + `scallopTx.deposit(coinT, 'usdc')`. Strategy-walk caveats from `kai-lending-math.md` §10.5 still apply (registered walkers run unconditionally).

```typescript
const tx = new Transaction();
tx.setSender(senderAddress);
const scallopTx = builder.createTxBlock(tx);

// === Leg 1: redeem from Kai. Net underlying lands in pm.balance[T] ===
const [coinYT, redeemTicket] = tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_start_redeem`,
  typeArguments: [T, YT],
  arguments: [
    tx.object(ACCESS_LIST_ID), tx.object(pmId),
    tx.object(KAI_VAULT_ID),
    tx.pure.u64(ytAmount),                         // sized via Kai §7 inverse helpers
    tx.object('0x6'),
  ],
});
const balanceYT = tx.moveCall({
  target: '0x2::coin::into_balance', typeArguments: [YT], arguments: [coinYT],
});
const balanceT  = kaiVault.withdraw(tx, balanceYT, kaiVault.getStrategies());
const coinT     = tx.moveCall({
  target: '0x2::coin::from_balance', typeArguments: [T], arguments: [balanceT],
});
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_finish_redeem`,
  typeArguments: [T, YT],
  arguments: [tx.object(pmId), tx.object(FEE_HOUSE_ID), redeemTicket, coinT],
});

// === Leg 2: supply that same underlying into Scallop ===
const [coinT2, supplyTicket] = tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_start_supply`,
  typeArguments: [T],
  arguments: [
    tx.object(ACCESS_LIST_ID), tx.object(pmId),
    tx.object(SCALLOP_MARKET_ID),
    tx.pure.u64(supplyAmount),
  ],
});
const coinMarket = scallopTx.deposit(coinT2, 'usdc');
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_finish_supply`,
  typeArguments: [T],
  arguments: [tx.object(pmId), supplyTicket, coinMarket],
});

await client.signAndExecuteTransaction({ signer, transaction: tx });
```

### 4.5 Periodic Harvest — Realize Interest, Crystallize Service Fee, Re-Park

**Use case.** A PM has had funds parked in Scallop (or Kai) for a long time and the lending entry has earned non-trivial interest. With cdpm's design the yield-fee is taken **only on redeem** (`scallop_finish_redeem` / `kai_finish_redeem`), so unrealized interest sits inside the lending vault and only gets fee-taxed when the user finally withdraws. A periodic *harvest* drains the entry, lets cdpm crystallize the service fee on the accumulated interest, and immediately re-parks the post-fee underlying — refreshing the principal cost-basis and locking the protocol's fee accrual into `fee_house.fee[T]`.

Why a protocol bot or agent would harvest:

- **Smooths fee accrual.** Without harvests, fees realize in one large hit at user-redeem; periodic harvests turn that into a steady stream into `fee_house.fee[T]`.
- **Resets cost basis.** After harvest, `pm.lending` holds a fresh entry whose `principal` matches the just-supplied amount. Subsequent partial redeems pay fee only on interest accrued since this point.
- **Optionally switches venue.** Combined with the picker (§10.4), a harvest can migrate funds to whichever venue currently pays the higher net APY — see the cross-venue note at the end.

**Pattern (3 logical steps in one PTB):**

1. Drain the lending entry with `MAX_U64` as the `scoin_amount` (Scallop) or `yt_amount` (Kai). cdpm's `pull_from_*_lending` triggers the full-drain branch when `want_amount >= stored_balance` (so any value at or above the stored balance works; `MAX_U64` is the defensive default that survives off-chain/on-chain skew). The branch removes the bag entry from `pm.lending`.
2. cdpm `*_finish_redeem` deducts yield-fee from `interest = redeemed_amount − principal_portion` (where `principal_portion` equals the entire stored principal because we drained), credits the post-fee underlying to `pm.balance[T]`, accrues `fee_amount` to `fee_house.fee[T]`.
3. cdpm `*_start_supply` + inner SDK builder `deposit` re-park the predicted post-fee underlying as a fresh principal.

#### In-place Scallop harvest

```typescript
const MAX_U64 = (1n << 64n) - 1n;

// === Off-chain prediction: how much underlying will land in pm.balance[T]
//     after the drain leg. We size the supply leg to this exact figure. ===
//
// reserve / vault snapshots come from §1 + §8 of scallop-lending-math.md;
// re-snapshot AFTER a dev-inspect of accrue_interest_for_market for freshness.
const drain = predictRedeem(reserve, vault, vault.scoinTotal, feeRateBp);
const reSupplyAmount = drain.toBalance;          // post-fee underlying

const tx = new Transaction();
tx.setSender(senderAddress);                     // owner / agent / protocol
const scallopTx = builder.createTxBlock(tx);

// 0. Pre-flight accrual. The inner protocol::redeem::redeem already calls
//    accrue_all_interests, so this command is NOT required for redeem
//    correctness — it's needed for prediction freshness so that
//    `reSupplyAmount = drain.toBalance` is a tight floor matching the live
//    balance_sheet at execution time. Skip and you may leak 1-2 underlying
//    into pm.balance[T] residual instead of into the re-park leg.
tx.moveCall({
  target: `${SCALLOP_PROTOCOL}::accrue_interest::accrue_interest_for_market`,
  arguments: [
    tx.object(SCALLOP_VERSION_ID),
    tx.object(SCALLOP_MARKET_ID),
    tx.object('0x6'),
  ],
});

// === Leg 1: DRAIN. MAX_U64 sentinel → entire ScallopVault<T> entry removed
//     from pm.lending; principal_portion = entire stored principal. ===
const [coinMarket, redeemTicket] = tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_start_redeem`,
  typeArguments: [T],
  arguments: [
    tx.object(ACCESS_LIST_ID), tx.object(pmId),
    tx.object(SCALLOP_MARKET_ID),
    tx.pure.u64(MAX_U64),                        // ← drain sentinel
  ],
});
const coinT = scallopTx.withdraw(coinMarket, 'usdc');
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_finish_redeem`,
  typeArguments: [T],
  arguments: [tx.object(pmId), tx.object(FEE_HOUSE_ID), redeemTicket, coinT],
});
//   After leg 1:
//     pm.lending[type_name<T>]      removed
//     pm.balance[T]                += redeemed_amount − fee_amount
//     fee_house.fee[T]              += fee_amount         (= interest × fee_rate / 10000)

// === Leg 2: RE-PARK. Fresh principal = reSupplyAmount. ===
const [coinT2, supplyTicket] = tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_start_supply`,
  typeArguments: [T],
  arguments: [
    tx.object(ACCESS_LIST_ID), tx.object(pmId),
    tx.object(SCALLOP_MARKET_ID),
    tx.pure.u64(reSupplyAmount),                 // exact, predicted
  ],
});
const coinMarket2 = scallopTx.deposit(coinT2, 'usdc');
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_finish_supply`,
  typeArguments: [T],
  arguments: [tx.object(pmId), supplyTicket, coinMarket2],
});
//   After leg 2:
//     pm.lending[type_name<T>]      reborn with principal = reSupplyAmount
//     pm.balance[T]                -= reSupplyAmount
//                                   (residual 1-2 underlying remains as future harvest)

await client.signAndExecuteTransaction({ signer, transaction: tx });
```

#### In-place Kai harvest

The shape is identical — substitute `kai_start_redeem<T,YT>(MAX_U64)` for the drain, `vault.withdraw(tx, balanceYT, kaiVault.getStrategies())` (auto strategy walk, see kai-lending-math.md §10.5) for the inner withdraw, and `vault.deposit` for the re-park inner deposit. The `Coin ↔ Balance` plumbing follows §4.2 / §4.4. cdpm fee math is identical across both venues — `kai_finish_redeem` deducts the same `fee_rate` from `interest` and accrues to the same `fee_house.fee[T]`.

```typescript
// `kaiVaultSnapshot` is a KaiVaultSnapshot (off-chain {totalAvailable, ytSupply})
// from kai-lending-math.md §1; `kaiVault` (defined at §3) is the SDK helper
// `VAULTS.suiUSDT` that exposes the move-call builders. The two are distinct
// objects.
const drain = predictKaiRedeem(kaiVaultSnapshot, pmKaiVault, pmKaiVault.ytInPm, feeRateBp);
const reSupplyAmount = drain.toBalance;

// Leg 1: drain Kai (MAX_U64 → entire KaiVault<T,YT> entry removed) ----------
const [coinYT, redeemTicket] = tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_start_redeem`,
  typeArguments: [T, YT],
  arguments: [
    tx.object(ACCESS_LIST_ID), tx.object(pmId),
    tx.object(KAI_VAULT_ID), tx.pure.u64(MAX_U64), tx.object('0x6'),
  ],
});
const balanceYT = tx.moveCall({
  target: '0x2::coin::into_balance', typeArguments: [YT], arguments: [coinYT],
});
const balanceT = kaiVault.withdraw(tx, balanceYT, kaiVault.getStrategies());
const coinT = tx.moveCall({
  target: '0x2::coin::from_balance', typeArguments: [T], arguments: [balanceT],
});
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_finish_redeem`,
  typeArguments: [T, YT],
  arguments: [tx.object(pmId), tx.object(FEE_HOUSE_ID), redeemTicket, coinT],
});

// Leg 2: re-park into Kai -----------------------------------------------------
const [coinT2, supplyTicket] = tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_start_supply`,
  typeArguments: [T, YT],
  arguments: [
    tx.object(ACCESS_LIST_ID), tx.object(pmId),
    tx.object(KAI_VAULT_ID), tx.pure.u64(reSupplyAmount), tx.object('0x6'),
  ],
});
const balanceT2 = tx.moveCall({
  target: '0x2::coin::into_balance', typeArguments: [T], arguments: [coinT2],
});
const balanceYT2 = kaiVault.deposit(tx, balanceT2);
const coinYT2 = tx.moveCall({
  target: '0x2::coin::from_balance', typeArguments: [YT], arguments: [balanceYT2],
});
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_finish_supply`,
  typeArguments: [T, YT],
  arguments: [tx.object(pmId), supplyTicket, coinYT2],
});
```

#### Cross-venue harvest

The harvest pattern composes with the picker. Drain the current venue, query `pickSupplyVenue` (Scallop §10.4) for the best supply destination as of harvest time, and route the re-park leg accordingly:

- If the picker says **same venue**: identical to the in-place harvest above.
- If the picker says **the other venue**: this is exactly §4.3 (Scallop → Kai) or §4.4 (Kai → Scallop) with the `scoinAmount` / `ytAmount` set to `MAX_U64`. The Kai or Scallop side that becomes the *destination* uses §4.3 / §4.4's leg 2; the *source* uses leg 1 with the drain sentinel.
- If the picker says **idle**: skip the re-park leg; let the post-fee underlying sit in `pm.balance[T]` until APYs improve.

The decision must be resolved off-chain *before* assembling the PTB — Move PTBs do not branch. A harvest scheduler typically runs `pickSupplyVenue` immediately before signing each scheduled harvest; if either venue's APY changes between scheduling and signing the worst case is one extra harvest cycle paying the wrong-venue fee, never a stuck position.

#### Caveats specific to harvest

- **Authorization.** `scallop_start_*` / `kai_start_*` require owner / authorized agent / whitelisted protocol bot (when `pm.agents.is_empty()`). The most natural harvest driver is a protocol bot on PMs without agents, or an agent on PMs that authorize one. The owner can always run harvest manually.
- **Who pays gas, who collects fee.** The harvest gas is paid by the signing entity (agent / protocol bot / owner); the crystallized yield-fee accrues to `fee_house.fee[T]`, which is owned by the cdpm protocol's admin tier — not the harvest signer. From the **user's** vantage no harvest is required: their fee bill on a single big redeem at exit is identical to the sum of fees crystallized by intermediate harvests. Harvest is therefore an operation paid for and consumed by the **fee recipient** (or a bot operating on their behalf), not by the user. Tune cadence accordingly: at 5% APR and 20% fee rate, the bot operator's break-even is `gas_cost / (apr / 365 × fee_rate)`; a position smaller than that on a daily cadence loses gas faster than it crystallizes fee. Larger positions or weekly cadences shift the math the other way.
- **Predicted vs live residual.** `reSupplyAmount = drain.toBalance` is the floor of the post-fee underlying. The live redeem may pay 1-2 units more (per `scallop-lending-math.md` §7.2 for Scallop and `kai-lending-math.md` §10.5 for Kai's `muldiv_round_up`); the residual stays in `pm.balance[T]` and is collected on the next harvest. This is benign.
- **Drain sentinel and `user_close_pm`.** Inside the PTB after leg 1 with `MAX_U64`, the harvested key has been removed from `pm.lending`. If this PM has *no other* lending entries (Scallop or Kai), `bag::is_empty(&pm.lending)` is now true and `user_close_pm`'s `ELendingNotEmpty (1004)` would pass at this mid-PTB point — but PTBs do not branch and `user_close_pm` is not part of the harvest. Leg 2 immediately repopulates the bag; if leg 2 aborts the whole PTB rolls back, restoring the entry. PMs with multiple lending keys retain their other entries throughout.
- **Atomicity matters less for security, more for state hygiene.** `user_remove_liquidity_from_balance` is owner-only (`pm.owner == ctx.sender()` is hard-asserted) — splitting harvest into two PTBs does **not** open a window for an unauthorized third party to drain the inter-tx residue. The real reasons to keep harvest atomic are: (a) gas amortization (one base fee, one storage rebate split), (b) rate snapshot freshness across the redeem and supply legs (separate PTBs would re-snapshot in between, leaking into a different `balance_sheet` at the supply side), and (c) avoiding owner-vs-bot front-running races where the owner could intercept the post-redeem residue before the bot's re-park goes through. Always one PTB.

---

## 5. Caveats

1. **Sign with `tx`, not `scallopTx`.** `client.signAndExecuteTransaction({ transaction: ... })` expects a Mysten `Transaction`; the Scallop Proxy wrapper would be rejected. Either sign `tx` directly, or use `scallopBuilder.signAndSendTxBlock(scallopTx)` (which unwraps internally).

2. **Call `tx.setSender(addr)` early.** The Scallop `*Quick` builders read `txBlock.blockData.sender` to source coins from the wallet; without a sender set you get a runtime error. Even if your PTB doesn't currently use a `*Quick` method, set it preemptively — the cost is zero and it future-proofs against a later edit that adds an escape-path call.

3. **Pin `@mysten/sui` to a single major across the dependency tree.** `coreBuilder.ts:484` does `initTxBlock instanceof Transaction` to decide whether to adopt. If the cdpm app, `@scallop-io/sui-scallop-sdk`, and `@kunalabs-io/kai` end up with different transitively-installed copies of `@mysten/sui`, there will be **two `Transaction` classes** and the `instanceof` check will silently fall through — `createTxBlock(tx)` will discard your tx and create a fresh internal one, breaking the shared-PTB invariant. Add to your app's `package.json`:

   ```jsonc
   {
     "resolutions": { "@mysten/sui": "<exact-version>" },   // for Yarn / pnpm
     "overrides":   { "@mysten/sui": "<exact-version>" }    // for npm / Bun
   }
   ```

   Verify with `npm ls @mysten/sui` (or `pnpm why @mysten/sui`) that only one copy resolves.

4. **Don't pass `*Quick` outputs into cdpm hot-potato finishes.** `*Quick` methods (`depositQuick`, `withdrawQuick`) source coins from the **wallet**, not from cdpm. They are useful for the *escape* path (e.g., owner extracts sCoin via `user_extract_scallop_market_coin<T>`, then calls `withdrawQuick`), but feeding their output into `scallop_finish_*` would either short-change the PM (if the `*Quick` output is too small) or breach cdpm's principal accounting.

5. **Re-snapshot inputs before signing.** Both protocols' state (`balance_sheet` for Scallop, `total_available_balance` for Kai) move every block. The picker (`scallop-lending-math.md` §10.4) and the sizing helpers (§7 in either file) rely on snapshots; for a rebalance PTB that does both a redeem and a supply, take a *single* snapshot just before signing and reuse it across both legs to keep the predictions internally consistent.

---

## 6. When to Reach for Approach A Instead

Approach B (recommended) is the default. Approach A (all raw `tx.moveCall`) is still appropriate in three cases:

- **Audit/review surface minimization.** A code reviewer reading the cdpm app expects Move-call shapes that mirror the contract's Move source. The SDK builders abstract this. For a security-conscious team, the explicit raw form is easier to verify.
- **Avoiding the dependency footprint.** If the cdpm app is a library or a tightly size-constrained build target (e.g., extension or wallet plugin), pulling in two SDKs may be unwelcome. The hosted REST address bundle (`https://sui.apis.scallop.io/addresses/{addressId}`) plus hand-rolled cdpm/Scallop/Kai move-calls keeps deps to zero.
- **CI-detectable upgrade signals.** With raw `tx.moveCall` and pinned `SCALLOP_VERSION_ID`, an upgrade by Scallop *will* break the cdpm app's tests — which is sometimes desired (you want to know about the upgrade and audit it before rolling forward). With the SDK, upgrades absorb silently into a published SDK version bump; you opt in to upgrades by bumping the SDK, not by editing constants.

For most teams, B is correct. The operational PTB recipes in `cdpm-user-sdk/reference/*.md`, `cdpm-agent-sdk/reference/*.md`, and `cdpm-protocol-sdk/reference/*.md` currently demonstrate **A** for clarity; both shapes are valid and either can be used at the call site.

---

## 7. SDK File Reference

For readers who want to verify the interop claims against the SDK source:

- `sui-scallop-sdk/src/builders/coreBuilder.ts:483-488` — `createTxBlock(initTxBlock?)` adoption logic (`instanceof Transaction ? new SuiKitTxBlock(initTxBlock) : ...`).
- `sui-scallop-sdk/src/builders/index.ts:35-52` — `newScallopTxBlock` wraps `coreTxBlock` in a `Proxy`.
- `sui-scallop-sdk/src/types/builder/core.ts:41-50` — `deposit(coin: SuiObjectArg, poolCoinName: string) => TransactionResult` and `withdraw` declarations.
- `sui-scallop-sdk/document/builder.md:114-132` — official "Compatibility with @mysten/sui Transaction" example mixing Scallop and raw `splitCoins` / `transferObjects` in one PTB.
- `kai-ts-sdk/src/vault/vault.ts:177` — `deposit(tx: Transaction, balance: TransactionObjectInput): TransactionResult`.
- `kai-ts-sdk/src/vault/vault.ts:222` — `withdraw(tx: Transaction, balance: TransactionObjectInput, strategies: WithdrawableStrategy[]): TransactionResult`.
- `@scallop-io/sui-kit/dist/libs/suiTxBuilder/index.d.ts:6-8` — `class SuiTxBlock { txBlock: Transaction; constructor(transaction?: Transaction); }`. The `.txBlock` field is the public escape hatch back to Mysten.

---

## 8. Cross-Reference

- Scallop-side rate query and granular builders: [`scallop-lending-math.md` §10](./scallop-lending-math.md#10-reading-live-supply-apy-off-chain-scallop-vs-kai-picker)
- Kai-side rate query and granular builders: [`kai-lending-math.md` §10](./kai-lending-math.md#10-reading-live-vault-apy-off-chain-supply-side-half-of-the-picker)
- Cross-protocol supply picker (`pickSupplyVenue`): [`scallop-lending-math.md` §10.4](./scallop-lending-math.md#104-decision-recipe--scallop-vs-kai-supply-picker)
- Inverse-sizing helpers (which feed the redeem leg of §4.3): `scallop-lending-math.md` §7, `kai-lending-math.md` §7.
- Operational raw-`tx.moveCall` recipes (Approach A): `cdpm-user-sdk/reference/{scallop,kai}-lending.md`, `cdpm-agent-sdk/reference/{scallop,kai}-lending.md`, `cdpm-protocol-sdk/reference/{scallop,kai}-lending.md`.
