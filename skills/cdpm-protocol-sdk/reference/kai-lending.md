# Kai SAV Lending — Protocol Operations

## Contents

- [Why a Protocol Tier Wants Kai Alongside Scallop](#why-a-protocol-tier-wants-kai-alongside-scallop)
- [Authoritative Signatures](#authoritative-signatures)
- [Protocol Supply](#protocol-supply)
- [Protocol Redeem (with yield-fee deduction)](#protocol-redeem-with-yield-fee-deduction)
- [Sizing Redemptions](#sizing-redemptions)
- [Protocol-Tier Permission Invariant](#protocol-tier-permission-invariant)
- [Events](#events)
- [Error Cheat Sheet](#error-cheat-sheet)

## Why a Protocol Tier Wants Kai Alongside Scallop

Two dimensions of diversification:

1. **Underlying yield source.** Scallop is a money market (variable supply APY tied to utilization). Kai SAV aggregates strategies — leveraged supply on `kai_leverage::supply_pool`, vault-of-vaults on Scallop SAV strategies, etc. A protocol bot that periodically rebalances idle balance between the two diversifies the yield curve.
2. **Coexistence on a single PM.** The `pm.lending: Bag` keys Scallop entries by `type_name<T>` and Kai entries by `type_name<YT>`. A protocol bot can hold both `ScallopVault<USDC>` and `KaiVault<USDC, YUSDC>` simultaneously without bag collision.

The yield-fee math inside `kai_redeem` is **identical** to `scallop_redeem`:

```
principal_portion = floor(P_total × yt_burned / YT_total)
interest          = max(0, redeemed_amount − principal_portion)
fee_amount        = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance     = redeemed_amount − fee_amount
```

`fee_house.fee_rate` is shared across Scallop and Kai redeems. `admin_set_fee` caps it at `MAX_FEE_RATE = 5000` (50%); the default is `2000` (20%).

---

## Authoritative Signatures

```move
public fun kai_supply<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &mut kai_vault::Vault<T, YT>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);

public fun kai_redeem<T, ST, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    fee_house: &mut FeeHouse,
    vault: &mut kai_vault::Vault<T, YT>,
    strategy: &mut klsp::Strategy<T, ST>,
    supply_pool: &mut SupplyPool<T, ST>,
    yt_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
);
```

Each is one `tx.moveCall`. `kai_supply` pulls `amount` of underlying from `pm.balance[T]`, calls `kai_vault::deposit<T, YT>`, and stores the resulting `Balance<YT>` plus principal under `KaiVault<T, YT>` keyed by `type_name<YT>` in `pm.lending`.

`kai_redeem` is generic over the supply-pool strategy `<T, ST>`. cdpm walks the production Kai withdrawal flow internally:

```
kai_vault::withdraw<T, YT>          // mints a WithdrawTicket
  → klsp::withdraw<T, ST, YT>       // strategy-side draw against SupplyPool<T, ST>
  → kai_vault::redeem_withdraw_ticket<T, YT>   // settles to underlying
```

The yield fee is deducted into `fee_house.fee[T]` and the remainder is added to `pm.balance[T]`. `yt_amount = u64::MAX` drains the `KaiVault<T, YT>` entry from `pm.lending`.

---

## Protocol Supply

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function protocolSupplyToKai(
  client: SuiGrpcClient,
  protocolSigner: any,         // address in AccessList.allow AND pm.agents must be empty
  pmId: string,
  underlyingCoinType: string,
  ytCoinType: string,
  vaultObjectId: string,
  amount: bigint,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_supply`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(vaultObjectId),
      tx.pure.u64(amount),
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer: protocolSigner, transaction: tx });
}
```

`amount` is clamped to the live `pm.balance[T]` value by the internal `withdraw_from_balance<T>` helper, so passing `u64::MAX` consumes the entire `pm.balance[T]` entry. Use an explicit sized `amount` only when you intentionally want to leave a residual.

Emits `KaiSupplied { pm_id, coin_type, yt_type, deposit_amount, yt_minted }`.

---

## Protocol Redeem (with yield-fee deduction)

`kai_redeem` requires four object handles besides the cdpm shared objects:

- `vaultObjectId` — the `kai_vault::Vault<T, YT>` shared object.
- `strategyObjectId` — a `klsp::Strategy<T, ST>` attached to the vault.
- `supplyPoolObjectId` — the matching `kai_leverage::supply_pool::SupplyPool<T, ST>`.
- `feeHouseId` — cdpm's `FeeHouse` shared object.

```typescript
async function protocolRedeemFromKai(
  client: SuiGrpcClient,
  protocolSigner: any,
  pmId: string,
  underlyingCoinType: string,
  stCoinType: string,
  ytCoinType: string,
  vaultObjectId: string,
  strategyObjectId: string,
  supplyPoolObjectId: string,
  ytAmount: bigint,
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_redeem`,
    typeArguments: [underlyingCoinType, stCoinType, ytCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
      tx.object(vaultObjectId),
      tx.object(strategyObjectId),
      tx.object(supplyPoolObjectId),
      tx.pure.u64(ytAmount),
      tx.object('0x6'),
    ],
  });

  return await client.signAndExecuteTransaction({ signer: protocolSigner, transaction: tx });
}
```

Emits `KaiRedeemed { pm_id, coin_type, yt_type, yt_burned, redeemed_amount, principal_portion, interest, fee_amount }`.

---

## Sizing Redemptions

Protocol bots usually know "I need `K` underlying for the next operation" and must compute `yt_amount` from that. `kai_redeem` takes YT, not underlying.

- **Pre-fee target** — I need at least `K` underlying out of Kai, ignoring fee:

  ```
  yt_to_burn = ceil(K × yt_supply / total_available_balance)
  ```

- **Post-fee target** — I want `K` net to land in `pm.balance[T]` after the yield fee. Closed-form (interest-exists branch):

  ```
  yt_to_burn ≈ ceil(K × 10000 × yt_supply × YT_in_pm
                    / ((10000 − r_bp) × total_available × YT_in_pm + r_bp × yt_supply × P_in_pm))
  ```

Both use **ceiling division** because the underlying delivery floors. Asking for `floor(N)` risks receiving 1 unit fewer than the target. The full derivation, edge cases, and an iterative refinement helper (`ytToBurnForTargetNet`) live in [`cdpm-calculation-skill/reference/kai-lending-math.md`](../../cdpm-calculation-skill/reference/kai-lending-math.md) section 7.

```typescript
import {
  ytToBurnForTargetUnderlying,
  ytToBurnForTargetNet,
} from './kai-lending-math';

async function protocolRedeemForTargetNet(
  client: SuiGrpcClient,
  protocolSigner: any,
  pmId: string,
  underlyingCoinType: string,
  stCoinType: string,
  ytCoinType: string,
  vaultObjectId: string,
  strategyObjectId: string,
  supplyPoolObjectId: string,
  desiredNet: bigint,
  feeRateBp: bigint,
  vaultSnapshot: KaiVaultSnapshot,
  pmKaiVault: KaiPmVaultSnapshot,
) {
  const ytAmount = ytToBurnForTargetNet(
    vaultSnapshot, pmKaiVault, desiredNet, feeRateBp,
  );

  return protocolRedeemFromKai(
    client, protocolSigner, pmId,
    underlyingCoinType, stCoinType, ytCoinType,
    vaultObjectId, strategyObjectId, supplyPoolObjectId,
    ytAmount,
  );
}
```

`ytToBurnForTargetNet` may return `MAX_U64` when the `KaiVault<T, YT>` entry cannot satisfy `desiredNet`. Passing `MAX_U64` drains the entire entry; cap the burn at `wrapperRaw − LENDING_SAFE_MARGIN_WRAPPER_RAW` (default 100 YT) when you want to keep the entry alive for the user-close flow. The residual is reclaimed when the user closes the PM.

```typescript
const LENDING_SAFE_MARGIN_WRAPPER_RAW = 100n;

function capRedeemBurnRaw(exact: bigint, wrapperRaw: bigint): bigint | null {
  if (wrapperRaw <= LENDING_SAFE_MARGIN_WRAPPER_RAW) return null;
  const safeMax = wrapperRaw - LENDING_SAFE_MARGIN_WRAPPER_RAW;
  return exact >= safeMax ? safeMax : exact;
}

// usage at the call site
const exact = ytToBurnForTargetUnderlying(vaultSnapshot, desiredUnderlying);
const burn  = capRedeemBurnRaw(exact, BigInt(entry.wrapperRaw));
if (burn === null) return;  // entry too small to safely redeem
tx.moveCall({
  target: `${CDPM_PACKAGE}::cdpm::kai_redeem`,
  typeArguments: [underlyingCoinType, stCoinType, ytCoinType],
  arguments: [..., tx.pure.u64(burn.toString()), ...],
});
```

Re-snapshot vault state right before signing — Kai's `total_available_balance` ticks every block as time-locked profit unlocks.

---

## Protocol-Tier Permission Invariant

The protocol-tier branch of `assert_caller_authorized` *only* fires when `pm.agents.is_empty()`. Once the owner authorizes any agent, the protocol tier is locked out until every agent is revoked. The same rule applies to `scallop_supply` / `scallop_redeem`.

```typescript
async function validateProtocolKaiOperation(
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

The exit path from `pm.lending` is `kai_redeem<T, ST, YT>`, which walks the full vault withdrawal flow, deducts the yield fee, and lands the remainder in `pm.balance[T]`. If any leg of the internal walk aborts (Kai vault paused, supply-pool rate limit, strategy mismatch), `kai_redeem` aborts as a whole — `pm.lending` stays intact, and the protocol bot retries once Kai is healthy.

---

## Events

```typescript
interface KaiSupplied {
  pm_id: string;
  coin_type: string;       // type_name<T>
  yt_type: string;         // type_name<YT>
  deposit_amount: u64;
  yt_minted: u64;
}

interface KaiRedeemed {
  pm_id: string;
  coin_type: string;
  yt_type: string;
  yt_burned: u64;
  redeemed_amount: u64;
  principal_portion: u64;
  interest: u64;
  fee_amount: u64;
}
```

Sui event envelopes already record `event.sender`, so the protocol address is observable without a separate `by` field.

---

## Error Cheat Sheet

| Code | Constant | Cause for a protocol bot |
|------|----------|---------------------------|
| 1002 | `ENotAllow` | Either: protocol address not in AccessList, or PM has at least one agent (protocol-tier locked out by the `assert_caller_authorized` union). Snapshot `pm.agents` and `access.allow` before each batch. |
| 1004 | `ELendingNotEmpty` | Owner attempted `user_close_pm` while the protocol bot still has a Kai entry in `pm.lending`. Coordinate with the owner — drain via `kai_redeem` before close. |
| 1005 | `ENoSuchVault` | `kai_redeem` for a `(T, YT)` pair with no entry. Re-fetch `pm.lending` before sizing. |
| 1006 | `ENoSuchBalance` | `kai_supply` for a `T` with no balance entry in `pm.balance`. Fund `pm.balance[T]` first via `user_add_liquidity_to_balance` (owner) or by removing liquidity / collecting fees. |

External aborts that bubble up from Kai itself (cdpm does not produce these):

- `vault::EWithdrawalsDisabled` — admin disabled withdrawals; nobody can drain through cdpm. `pm.lending` stays intact and waits for Kunalabs to re-enable withdrawals.
- `vault::ETvlCapExceeded` — admin set a `tvl_cap` that the supply would breach.
- `vault::ERateLimit` — admin-configured rate limiter rejected the operation.

When any of these hit, `kai_supply` / `kai_redeem` aborts before PM mutation completes — PM state is intact. The protocol bot can reschedule once Kai is healthy.
