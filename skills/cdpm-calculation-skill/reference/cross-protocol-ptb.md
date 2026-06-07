# Composing a Cross-Protocol PTB (cdpm + Scallop + Kai)

## Contents

- [1. Interop Fact: One Mysten `Transaction` Backs All Three](#1-interop-fact-one-mysten-transaction-backs-all-three)
- [2. Approach Comparison](#2-approach-comparison)
- [3. Canonical Pattern](#3-canonical-pattern)
- [4. Worked Examples](#4-worked-examples)
- [5. Caveats](#5-caveats)
- [6. SDK File Reference](#6-sdk-file-reference)
- [7. Cross-Reference](#7-cross-reference)

## 1. Interop Fact: One Mysten `Transaction` Backs All Three

Both SDKs are built on top of Mysten's `Transaction` from `@mysten/sui/transactions`, and both expose entry points that accept an externally-supplied `Transaction`:

| Side | Entry point | Behavior |
|------|-------------|----------|
| Scallop | `scallopBuilder.createTxBlock(tx?: Transaction)` | If `tx` is a Mysten `Transaction`, it is adopted via `instanceof Transaction ? new SuiKitTxBlock(initTxBlock) : ...` (`sui-scallop-sdk/src/builders/coreBuilder.ts:483-488`). The returned `ScallopTxBlock` is a `Proxy` over `SuiKitTxBlock`, whose `.txBlock` field IS the same Mysten `Transaction` you handed in. |
| Kai | `vault.deposit(tx, balance)` / `vault.withdraw(tx, balance, strategies)` | `tx` is typed as Mysten `Transaction` directly (`kai-ts-sdk/src/vault/vault.ts:177,222`). Returns tx-result `Balance` arguments. |
| cdpm | raw `tx.moveCall({ target: \`${CDPM_PACKAGE}::cdpm::*\`, ... })` | cdpm has no published TS bindings; calls go straight on the Mysten `Transaction`. |

Because all three accept the same `Transaction` instance, you can interleave their move-calls in one PTB and submit it once. The four cdpm lending entries — `scallop_supply`, `scallop_redeem`, `kai_supply`, `kai_redeem` — are each a single `tx.moveCall` that composes the full lending leg internally, so the cdpm side contributes one move-call per lending action regardless of how many upstream calls it wraps.

---

## 2. Approach Comparison

| Approach | Description | Atomicity | Gas | Upgrade resilience | Type safety | Dependency surface | Viable? |
|----------|-------------|-----------|-----|---------------------|-------------|--------------------|---------|
| **A. All raw `tx.moveCall`** | Hardcode `SCALLOP_VERSION_ID`, `SCALLOP_MARKET_ID`, `KAI_VAULT_ID`, type tags; call `cdpm::scallop_supply` / `cdpm::kai_redeem` etc. directly. | ✓ | 1 PTB | Requires a cdpm-side constant edit whenever Scallop / Kai bump their object ids | Weak (string targets) | None | ✓ |
| **B. Mysten-rooted shared `Transaction`** *(recommended for off-cdpm composition)* | `new Transaction()`; pass to `scallopBuilder.createTxBlock(tx)` only if the PTB also needs Scallop SDK helpers outside the cdpm lending entries; pass to `kaiVault.deposit/withdraw(tx, …)` only for off-cdpm Kai composition; cdpm lending calls remain raw on `tx`. | ✓ | 1 PTB | SDK absorbs inner-protocol upgrades for any non-cdpm calls | Medium (SDK methods typed; cdpm raw) | Both SDKs | ✓ |
| **C. Scallop-rooted** | `builder.createTxBlock()` (no tx arg) makes a fresh wrapper; reach the underlying Mysten `Transaction` via `scallopTx.txBlock` and pass that to Kai/cdpm. | ✓ | 1 PTB | Same as B | Medium | Both SDKs | ✓ but unnecessarily couples to Scallop lifecycle |
| **D. Pure SDK end-to-end** | Use only `*Quick` (Scallop) / `vault.depositFromWallet` (Kai). | n/a | n/a | n/a | n/a | n/a | cdpm has no TS bindings; the cdpm calls must still be raw `moveCall` |

A and B are both fine. A is simpler when the only non-cdpm calls are inner protocol moves cdpm already wraps (e.g. `scallop_supply` internally invokes `mint::mint`, so a PTB that just supplies needs no Scallop SDK builder at all). B is worth it when the same PTB also performs *non-cdpm* Scallop or Kai actions — e.g. routing a wallet swap through Scallop in addition to a cdpm `kai_redeem`.

---

## 3. Canonical Pattern

### 3.0 Install the SDKs

Both SDKs are published to npm. Install alongside Mysten's `@mysten/sui` (required by both; pin to a single major across the dep tree — see §5 for the `instanceof Transaction` pitfall):

```bash
# bun
bun add @scallop-io/sui-scallop-sdk @kunalabs-io/kai @mysten/sui

# npm
npm install @scallop-io/sui-scallop-sdk @kunalabs-io/kai @mysten/sui

# pnpm
pnpm add @scallop-io/sui-scallop-sdk @kunalabs-io/kai @mysten/sui

# yarn
yarn add @scallop-io/sui-scallop-sdk @kunalabs-io/kai @mysten/sui
```

The Kai package may also appear as `@kunalabs-io/kai-sdk` in older snippets — they refer to the same library. cdpm itself ships no TS bindings; the cdpm `moveCall` targets are issued directly against the Mysten `Transaction` so no additional install is needed for the cdpm side.

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

// Mount Scallop side onto `tx` — only when the PTB needs Scallop SDK helpers
// outside cdpm's wrapped calls (e.g. a wallet-side swap).
const scallopTx = builder.createTxBlock(tx);       // adopts tx; same instance underneath

// Kai vault entry for off-cdpm composition.
const kaiVault  = VAULTS.suiUSDT;

await client.signAndExecuteTransaction({ signer, transaction: tx });
//                                                    ^^^ — NOT scallopTx
```

`scallopTx` is a `Proxy` wrapper; passing it to `signAndExecuteTransaction` would be rejected because the API checks for `Transaction`. Sign with the underlying `tx`. The Scallop convenience helper `scallopBuilder.signAndSendTxBlock(scallopTx)` exists and works because it unwraps `.txBlock` internally — pick whichever fits your call site.

---

## 4. Worked Examples

### 4.1 Single-Protocol Supply (Picker → Scallop)

A Scallop supply is one `tx.moveCall`. `scallop_supply` pulls the underlying out of `pm.balance`, calls `protocol::mint::mint` (which runs Scallop's internal `accrue_interest_for_market` as its first step), and joins the resulting `Balance<MarketCoin<T>>` into `pm.lending` under bag key `type_name<T>`.

```typescript
import { Transaction } from '@mysten/sui/transactions';

const tx = new Transaction();
tx.setSender(senderAddress);

tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_supply`,
  typeArguments: [underlyingCoinType],
  arguments: [
    tx.object(ACCESS_LIST_ID),
    tx.object(pmId),
    tx.object(SCALLOP_VERSION_ID),
    tx.object(SCALLOP_MARKET_ID),
    tx.pure.u64(amount),
    tx.object('0x6'),
  ],
});

await client.signAndExecuteTransaction({ signer, transaction: tx });
```

### 4.2 Single-Protocol Supply (Picker → Kai)

A Kai supply is one `tx.moveCall`. `kai_supply` pulls the underlying out of `pm.balance`, calls `kai_vault::deposit`, and joins the resulting `Balance<YT>` into `pm.lending` under bag key `type_name<YT>`.

```typescript
const tx = new Transaction();
tx.setSender(senderAddress);

tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_supply`,
  typeArguments: [T, YT],
  arguments: [
    tx.object(ACCESS_LIST_ID),
    tx.object(pmId),
    tx.object(KAI_VAULT_ID),
    tx.pure.u64(amount),
    tx.object('0x6'),
  ],
});

await client.signAndExecuteTransaction({ signer, transaction: tx });
```

### 4.3 Atomic Rebalance: Scallop → Kai (one PTB)

Redeem from Scallop and supply to Kai in one shot. Either both legs commit or neither does — atomic by Move / PTB semantics.

```typescript
const tx = new Transaction();
tx.setSender(senderAddress);

// === Leg 1: redeem from Scallop. Net underlying lands in pm.balance[T] ===
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_redeem`,
  typeArguments: [T],
  arguments: [
    tx.object(ACCESS_LIST_ID),
    tx.object(pmId),
    tx.object(FEE_HOUSE_ID),
    tx.object(SCALLOP_VERSION_ID),
    tx.object(SCALLOP_MARKET_ID),
    tx.pure.u64(scoinAmount),    // sized via predictScallopRedeem (scallop-lending-math.md §7)
    tx.object('0x6'),
  ],
});

// === Leg 2: supply that same underlying into Kai ===
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_supply`,
  typeArguments: [T, YT],
  arguments: [
    tx.object(ACCESS_LIST_ID),
    tx.object(pmId),
    tx.object(KAI_VAULT_ID),
    tx.pure.u64(supplyAmount),
    tx.object('0x6'),
  ],
});

await client.signAndExecuteTransaction({ signer, transaction: tx });
```

Properties:

- **Atomicity**: any abort along the chain (e.g. Scallop pause, Kai TVL cap) reverts the whole PTB. The redeem leg's effect on `pm.balance[T]` is fully rolled back together with the supply leg.
- **Sizing the Kai supply leg.** Use `predictScallopRedeem` (from `scallop-lending-math.md` §3) to estimate the post-fee underlying that will land in `pm.balance[T]`, then size `kai_supply`'s `amount` against that prediction minus a small margin. Concrete options:
  1. **Conservative size.** Set `supplyAmount = floor(predicted.toBalance) − margin` (a few raw is plenty). The residual stays in `pm.balance[T]` and supplies on the next rebalance cycle.
  2. **`MAX_U64` drain sentinel.** Pass `tx.pure.u64(MAX_U64)` as `kai_supply`'s `amount`. `withdraw_from_balance<T>` inside cdpm clamps to the live bag value and removes the entry, so the post-redeem balance — whatever it actually came out to — flows into `kai_supply` in full. No dev-inspect round trip needed.
  3. **Dev-inspect the residual.** Dev-inspect `pm.balance[T]` after a simulated redeem and feed that exact figure into `kai_supply`'s `amount`. Useful when you want a numeric assertion in the off-chain sanity check before signing.
- **Yield-fee**: paid once on the Scallop side at redeem; the supply leg incurs no fee (cdpm fees only on redeem). Net: one fee per round trip.

### 4.4 Atomic Rebalance: Kai → Scallop

Mirror of §4.3 — redeem from Kai, then supply to Scallop.

```typescript
const tx = new Transaction();
tx.setSender(senderAddress);

// === Leg 1: redeem from Kai. Net underlying lands in pm.balance[T] ===
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_redeem`,
  typeArguments: [T, ST, YT],
  arguments: [
    tx.object(ACCESS_LIST_ID),
    tx.object(pmId),
    tx.object(FEE_HOUSE_ID),
    tx.object(KAI_VAULT_ID),
    tx.object(KAI_STRATEGY_ID),
    tx.object(KAI_SUPPLY_POOL_ID),
    tx.pure.u64(ytAmount),       // sized via predictKaiWithdraw (kai-lending-math.md §7)
    tx.object('0x6'),
  ],
});

// === Leg 2: supply that same underlying into Scallop ===
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::scallop_supply`,
  typeArguments: [T],
  arguments: [
    tx.object(ACCESS_LIST_ID),
    tx.object(pmId),
    tx.object(SCALLOP_VERSION_ID),
    tx.object(SCALLOP_MARKET_ID),
    tx.pure.u64(supplyAmount),
    tx.object('0x6'),
  ],
});

await client.signAndExecuteTransaction({ signer, transaction: tx });
```

The same three sizing options from §4.3 apply: size against `predictKaiWithdraw(...).toBalance − margin`, use `MAX_U64` to drain `pm.balance[T]`, or dev-inspect.

### 4.5 Redeem → Cetus Add-Liquidity (Composition with Dust Prediction)

A common pattern: redeem from a lending venue, then deploy the freed underlying into a Cetus DLMM position via `protocol_add_liquidity` or `agent_add_liquidity`. The redeem result lands in `pm.balance[T]`; the add-liquidity call pulls back out of `pm.balance` to fund the liquidity bins.

The risk: `predictScallopRedeem` and `predictKaiWithdraw` floor the predicted underlying. The realized `redeemed_amount` can be a few raw lower (Kai dust budget ≈ 2 raw × strategies drawn; Scallop typically exact). If the add-liquidity leg requests more than what actually lands, `withdraw_from_balance<T>` inside cdpm hits the underlying `0x2::balance::split` ENotEnough abort.

Mitigation pattern (Kai → add-liquidity):

```typescript
// 1. Off-chain: predict the underlying that will land in pm.balance[T].
const predicted = predictKaiRedeem(vaultSnapshot, pmSnapshot, ytAmount, feeRateBp);

// 2. Clamp the deploy amount to a guaranteed lower bound.
const REDEEM_REALIZED_SAFETY_MARGIN_RAW = 3n;   // env-tunable; covers single-strategy dust
const realized = predicted.toBalance > REDEEM_REALIZED_SAFETY_MARGIN_RAW
  ? predicted.toBalance - REDEEM_REALIZED_SAFETY_MARGIN_RAW
  : 0n;
const deployT = available + realized;            // available = pre-existing pm.balance[T]

// 3. PTB: kai_redeem, then add-liquidity sized against `deployT`.
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_redeem`,
  typeArguments: [T, ST, YT],
  arguments: [
    tx.object(ACCESS_LIST_ID), tx.object(pmId), tx.object(FEE_HOUSE_ID),
    tx.object(KAI_VAULT_ID), tx.object(KAI_STRATEGY_ID), tx.object(KAI_SUPPLY_POOL_ID),
    tx.pure.u64(ytAmount), tx.object('0x6'),
  ],
});
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::protocol_add_liquidity`,
  typeArguments: [CoinTypeA, CoinTypeB],
  arguments: [
    tx.object(ACCESS_LIST_ID), tx.object(pmId), tx.object(POOL_ID),
    tx.pure.u64(deployTSplitA),   // <= deployT for the T side
    tx.pure.u64(otherSideAmount),
    /* bins, amounts_a, amounts_b */
    tx.object(CETUS_GLOBAL_CONFIG_ID), tx.object(CETUS_VERSIONED_ID), tx.object('0x6'),
  ],
});
```

The same shape works with Scallop (`predictScallopRedeem` for `predicted.toBalance`). For Scallop, the realized amount typically matches the prediction exactly (single floor-div shared with upstream), so a 1-raw margin is usually enough. For Kai, size the margin against the number of strategies in the vault: ≤2-strategy vaults need ≤2 raw of margin; a 3-raw default is comfortable across all current mainnet SAVs.

### 4.6 Harvest → Supply (Composition)

`protocol_collect_fee` and `agent_collect_fee` route the Cetus-side gross collected fees through `take_fee` (which skims the `fee_house.fee_rate` cut into `FeeHouse`) and the residual into `pm.fee`. Moving that residual into a lending supply takes a `protocol_transfer_fee_to_balance` (or `agent_transfer_fee_to_balance`) intermediate move-call, then `scallop_supply` / `kai_supply` pulls it out of `pm.balance`:

```typescript
// 1. Harvest Cetus fees — the protocol cut goes to FeeHouse, the rest to pm.fee.
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::protocol_collect_fee`,
  typeArguments: [CoinTypeA, CoinTypeB],
  arguments: [
    tx.object(ACCESS_LIST_ID), tx.object(FEE_HOUSE_ID),
    tx.object(pmId), tx.object(POOL_ID),
    tx.object(CETUS_GLOBAL_CONFIG_ID), tx.object(CETUS_VERSIONED_ID),
  ],
});

// 2. Pull the user portion of the T-side fee out of pm.fee into pm.balance.
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::protocol_transfer_fee_to_balance`,
  typeArguments: [T],
  arguments: [
    tx.object(ACCESS_LIST_ID), tx.object(pmId),
    tx.pure.u64(MAX_U64),     // drain the pm.fee[T] entry
  ],
});

// 3. Supply that amount into Kai (or Scallop).
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_supply`,
  typeArguments: [T, YT],
  arguments: [
    tx.object(ACCESS_LIST_ID), tx.object(pmId), tx.object(KAI_VAULT_ID),
    tx.pure.u64(MAX_U64),     // drain the pm.balance[T] entry just credited
    tx.object('0x6'),
  ],
});
```

Note that `protocol_collect_fee` already takes its protocol cut; `kai_supply` and `scallop_supply` do not charge a deposit-side fee. The only fee in the round trip is the protocol cut at harvest.

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

4. **`*Quick` SDK helpers source from the wallet.** `depositQuick` / `withdrawQuick` build coins from the signer's wallet, not from `pm.balance`. They have no role inside a cdpm lending leg — `scallop_supply` / `kai_supply` already pull from `pm.balance` and `scallop_redeem` / `kai_redeem` already credit to `pm.balance`. Use `*Quick` only for direct wallet-to-Scallop operations *outside* cdpm.

5. **Re-snapshot inputs before signing.** Both protocols' state (`balance_sheet` for Scallop, `total_available_balance` for Kai) move every block. The picker (`scallop-lending-math.md` §10.4) and the sizing helpers (`§7` in either lending-math file) rely on snapshots; for a rebalance PTB that does both a redeem and a supply, take a single snapshot just before signing and reuse it across both legs to keep the predictions internally consistent.

6. **Dust margins on redeem → add-liquidity.** When composing `*_redeem` with a downstream `*_add_liquidity` in the same PTB, clamp the deploy size to `floor(predicted.toBalance) − margin` rather than `predicted.toBalance` itself. Kai single-strategy SAVs need ≤2 raw of margin; 3 raw is a safe default. Scallop typically realizes the prediction exactly; 1 raw of margin is sufficient. See `kai-lending-math.md` §9.1 and `scallop-lending-math.md` §9.1.

---

## 6. SDK File Reference

For readers who want to verify the interop claims against the SDK source:

- `sui-scallop-sdk/src/builders/coreBuilder.ts:483-488` — `createTxBlock(initTxBlock?)` adoption logic (`instanceof Transaction ? new SuiKitTxBlock(initTxBlock) : ...`).
- `sui-scallop-sdk/src/builders/index.ts:35-52` — `newScallopTxBlock` wraps `coreTxBlock` in a `Proxy`.
- `sui-scallop-sdk/src/types/builder/core.ts:41-50` — `deposit(coin: SuiObjectArg, poolCoinName: string) => TransactionResult` and `withdraw` declarations.
- `sui-scallop-sdk/document/builder.md:114-132` — official "Compatibility with @mysten/sui Transaction" example mixing Scallop and raw `splitCoins` / `transferObjects` in one PTB.
- `kai-ts-sdk/src/vault/vault.ts:177` — `deposit(tx: Transaction, balance: TransactionObjectInput): TransactionResult`.
- `kai-ts-sdk/src/vault/vault.ts:222` — `withdraw(tx: Transaction, balance: TransactionObjectInput, strategies: WithdrawableStrategy[]): TransactionResult`.
- `@scallop-io/sui-kit/dist/libs/suiTxBuilder/index.d.ts:6-8` — `class SuiTxBlock { txBlock: Transaction; constructor(transaction?: Transaction); }`. The `.txBlock` field is the public escape hatch back to Mysten.

---

## 7. Cross-Reference

- Scallop-side rate query and granular builders: [`scallop-lending-math.md` §10](./scallop-lending-math.md#10-reading-live-supply-apy-off-chain-scallop-vs-kai-picker)
- Kai-side rate query: [`kai-lending-math.md` §10](./kai-lending-math.md#10-reading-live-vault-apy-off-chain-supply-side-half-of-the-picker)
- Cross-protocol supply picker (`pickSupplyVenue`): [`scallop-lending-math.md` §10.4](./scallop-lending-math.md#104-decision-recipe--scallop-vs-kai-supply-picker)
- Inverse-sizing helpers (which feed the redeem leg of §4.3 / §4.4): `scallop-lending-math.md` §7, `kai-lending-math.md` §7.
- Operational raw-`tx.moveCall` recipes: `cdpm-user-sdk/reference/{scallop,kai}-lending.md`, `cdpm-agent-sdk/reference/{scallop,kai}-lending.md`, `cdpm-protocol-sdk/reference/{scallop,kai}-lending.md`.
