# Scallop Lending — Protocol Operations

## Contents

- [Why a Protocol Tier Wants Scallop Alongside Kai](#why-a-protocol-tier-wants-scallop-alongside-kai)
- [Authoritative Signatures](#authoritative-signatures)
- [Protocol Supply](#protocol-supply)
- [Protocol Redeem (with yield-fee deduction)](#protocol-redeem-with-yield-fee-deduction)
- [Sizing Redemptions](#sizing-redemptions)
- [Protocol-Tier Permission Invariant](#protocol-tier-permission-invariant)
- [Trust Boundary](#trust-boundary)
- [Type-Pin Defense](#type-pin-defense)
- [Events](#events)
- [Error Cheat Sheet](#error-cheat-sheet)

## Why a Protocol Tier Wants Scallop Alongside Kai

Two dimensions of diversification:

1. **Underlying yield source.** Scallop is a money market (variable supply APY tied to utilization). Kai SAV aggregates strategies — leveraged supply on `kai_leverage::supply_pool`, vault-of-vaults on Scallop SAV strategies, etc. A protocol bot that periodically rebalances idle balance between the two diversifies the yield curve.
2. **Coexistence on a single PM.** The `pm.lending: Bag` keys Scallop entries by `type_name<T>` and Kai entries by `type_name<YT>`. A protocol bot can hold both `ScallopVault<USDC>` and `KaiVault<USDC, YUSDC>` simultaneously without bag collision.

The yield-fee math inside `scallop_redeem` is **identical** to `kai_redeem`:

```
principal_portion = floor(P_total × scoin_burned / S_total)
interest          = max(0, redeemed_amount − principal_portion)
fee_amount        = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance     = redeemed_amount − fee_amount
```

`fee_house.fee_rate` is shared across Scallop and Kai redeems. `admin_set_fee` caps it at `MAX_FEE_RATE = 5000` (50%); the default is `2000` (20%).

---

## Authoritative Signatures

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

Each is one `tx.moveCall`. `scallop_supply` pulls `amount` of underlying from `pm.balance[T]`, calls `protocol::mint::mint<T>`, and stores the resulting `Balance<MarketCoin<T>>` plus principal under `ScallopVault<T>` keyed by `type_name<T>` in `pm.lending`. `scallop_redeem` pulls `scoin_amount` of sCoin from `pm.lending`, calls `protocol::redeem::redeem<T>`, deducts the yield fee into `fee_house.fee[T]`, and routes the remaining underlying into `pm.balance[T]`.

`scoin_amount = u64::MAX` drains the vault entry: the helper clamps to the live `Balance<MarketCoin<T>>` value and removes the entry from `pm.lending`.

---

## Protocol Supply

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function protocolSupplyToScallop(
  client: SuiGrpcClient,
  protocolSigner: any,         // address in AccessList.allow AND pm.agents must be empty
  pmId: string,
  underlyingCoinType: string,
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
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer: protocolSigner, transaction: tx });
}
```

`amount` is clamped to the live `pm.balance[T]` value by the internal `withdraw_from_balance<T>` helper, so passing `u64::MAX` consumes the entire `pm.balance[T]` entry. Use an explicit sized `amount` only when you intentionally want to leave a residual.

Emits `ScallopSupplied { pm_id, coin_type, deposit_amount, market_coin_minted }`.

---

## Protocol Redeem (with yield-fee deduction)

`scallop_redeem` deducts `fee_amount = floor(interest × fee_house.fee_rate / 10_000)` from the interest portion before adding the rest to `pm.balance[T]`. Protocol callers pay the same yield fee as owner / agent.

```typescript
async function protocolRedeemFromScallop(
  client: SuiGrpcClient,
  protocolSigner: any,
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
      tx.pure.u64(scoinAmount),
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer: protocolSigner, transaction: tx });
}
```

Emits `ScallopRedeemed { pm_id, coin_type, market_coin_redeemed, redeemed_amount, principal_portion, interest, fee_amount }`.

---

## Sizing Redemptions

Protocol bots usually know "I need `K` underlying for the next operation" and must compute `scoin_amount` from that. `scallop_redeem` takes sCoin, not underlying.

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

Both use **ceiling division** because Scallop's redeem floors the underlying output. Asking for `floor(N)` risks receiving 1 unit fewer than the target. The full derivation, edge cases, and an iterative refinement helper (`scoinToBurnForTargetNet`) live in [`cdpm-calculation-skill/reference/scallop-lending-math.md`](../../cdpm-calculation-skill/reference/scallop-lending-math.md) section 7.

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

`scoinToBurnForTargetNet` may return `MAX_U64` when the `ScallopVault<T>` entry cannot satisfy `desiredNet`. Passing `MAX_U64` drains the entire vault and removes its entry from `pm.lending`; cap the burn at `wrapperRaw − LENDING_SAFE_MARGIN_WRAPPER_RAW` (recommended client-side default `100n` sCoin raw) when you want to keep the entry alive for the user-close flow.

Re-snapshot reserve and vault state right before signing — the reserve's `denom = cash + debt − revenue` moves with every Scallop interaction.

---

## Protocol-Tier Permission Invariant

The protocol-tier branch of `assert_caller_authorized` *only* fires when `pm.agents.is_empty()`. Once the owner authorizes any agent, the protocol tier is locked out until every agent is revoked. The same rule applies to `kai_supply` / `kai_redeem`.

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

The exit path from `pm.lending` is `scallop_redeem<T>`, which deducts the yield fee and lands the remainder in `pm.balance[T]`. If Scallop's internal `redeem::redeem` aborts (Version mismatch, paused market), `scallop_redeem` aborts as a whole — `pm.lending` stays intact, and the protocol bot retries once Scallop is healthy.

---

## Trust Boundary

cdpm imports `protocol::mint` and `protocol::redeem` and calls them inside `scallop_supply` / `scallop_redeem`. Every protocol-tier supply / redeem trusts the **Scallop team's upgrade-cap holder** to keep the inner Scallop modules honest: a malicious upgrade could arrange for `redeem::redeem` to over-deliver underlying to a particular caller, which cdpm cannot detect.

cdpm does **not** maintain an admin-side allowlist of acceptable Scallop `MarketCoin<T>` types — the `MarketCoin<T>` type pin is the only shape check. A protocol-tier bot operator who is uncomfortable with this trust assumption should:

1. Maintain its own off-chain whitelist of acceptable `T` (e.g. only USDC / USDT / SUI).
2. Refuse to drive `scallop_supply<T>` for any `T` outside that whitelist.
3. Encourage owners to authorize agents (which locks the protocol tier out of the same PM).

See `README` D-08 for the full trust-boundary discussion (the same paragraph covers the parallel Kai upgrade-cap assumption — see [`kai-lending.md`](./kai-lending.md)).

### Type-Pin Defense

`scallop_supply<T>` only ever stores `Balance<MarketCoin<T>>` into the `ScallopVault<T>` entry because the `MarketCoin<T>` type appears in the bag-value's struct field. `MarketCoin<T>` has no public constructor — the only way to obtain a non-zero balance is through Scallop's `protocol::mint::mint<T>`. Combined with cdpm's principal accounting, a protocol bot cannot short-change the vault by substituting a forged sCoin.

---

## Events

```typescript
interface ScallopSupplied {
  pm_id: string;
  coin_type: string;          // type_name<T>
  deposit_amount: u64;        // underlying transferred to Scallop
  market_coin_minted: u64;    // sCoin received and added to pm.lending
}

interface ScallopRedeemed {
  pm_id: string;
  coin_type: string;
  market_coin_redeemed: u64;  // sCoin burned
  redeemed_amount: u64;       // underlying received from Scallop, pre-fee
  principal_portion: u64;     // principal slice consumed by this redeem
  interest: u64;              // max(0, redeemed_amount − principal_portion)
  fee_amount: u64;            // protocol yield fee deducted from interest
}
```

Sui event envelopes already record `event.sender`, so the protocol address is observable without a separate `by` field.

---

## Error Cheat Sheet

| Code | Constant | Cause for a protocol bot |
|------|----------|---------------------------|
| 1002 | `ENotAllow` | Either: protocol address not in AccessList, or PM has at least one agent (protocol-tier locked out by the `assert_caller_authorized` union). Snapshot `pm.agents` and `access.allow` before each batch. |
| 1004 | `ELendingNotEmpty` | Owner attempted `user_close_pm` while the protocol bot still has a Scallop entry in `pm.lending`. Coordinate with the owner — drain via `scallop_redeem` before close. |
| 1005 | `ENoSuchVault` | `scallop_redeem<T>` for a `T` with no entry. Re-fetch `pm.lending` before sizing. |
| 1006 | `ENoSuchBalance` | `scallop_supply<T>` for a `T` with no balance entry in `pm.balance`. Fund `pm.balance[T]` first via `user_add_liquidity_to_balance` (owner) or by removing liquidity / collecting fees. |

External aborts that bubble up from Scallop itself (cdpm does not produce these) — typically a `protocol::version` mismatch after Scallop pushes an upgrade, or a `protocol::market` pause. When any of these hit, `scallop_supply` / `scallop_redeem` aborts before the PM mutation completes — PM state is intact. The protocol bot reschedules once Scallop is upgraded / unpaused.
