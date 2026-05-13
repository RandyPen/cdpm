# Kai SAV Lending — Protocol Operations

cdpm exposes a second hot-potato lending integration alongside Scallop: **Kai SAV** (Strategy-Aggregating Vault). The same protocol-tier authorization rules that apply to Scallop apply to Kai: a whitelisted protocol bot may drive `kai_start_supply` / `kai_start_redeem` against a `Vault<T, YT>` only when `pm.agents` is empty. The gate inside `assert_caller_authorized` is the union `is_owner || is_agent || (is_in_access_list && pm.agents.is_empty())`.

`kai_finish_*` only check `ticket.pm_id == object::id(pm)`. A correctly-shaped PTB therefore enforces protocol-tier access on the start side and binds the ticket to the same PM on the finish side.

---

## Why a Protocol Tier Wants Kai Alongside Scallop

Two dimensions of diversification:

1. **Underlying yield source.** Scallop is a money market (variable supply APY tied to utilization). Kai SAV aggregates strategies — leveraged supply on `kai_leverage::supply_pool`, vault-of-vaults on Scallop SAV strategies, etc. A protocol bot that periodically rebalances idle balance between the two diversifies the yield curve.
2. **Coexistence on a single PM.** The `pm.lending: Bag` keys Scallop entries by `type_name<T>` and Kai entries by `type_name<YT>`. A protocol bot can hold both `ScallopVault<USDC>` and `KaiVault<USDC, YUSDC>` simultaneously without bag collision.

The yield-fee math inside `kai_finish_redeem` is **identical** to `scallop_finish_redeem`:

```
interest      = max(0, redeemed_amount − principal_portion)
fee_amount    = floor(interest × fee_house.fee_rate / 10_000)
to_pm_balance = redeemed_amount − fee_amount
```

`fee_house.fee_rate` is shared across Scallop and Kai redeems. `admin_set_fee` caps it at `MAX_FEE_RATE = 3000` (30%); the default is `2000` (20%).

---

## No Pre-Call Accrual Required

Unlike Scallop (which requires `protocol::accrue_interest::accrue_interest_for_market` as the first PTB command), Kai's `vault::deposit` / `vault::withdraw` read `total_available_balance(vault, clock)`, which folds in time-locked profit via `tlb::max_withdrawable` automatically. cdpm's `compute_expected_yt` and `compute_expected_underlying_kai` read the same auto-accruing pair, so the off-chain prediction matches the live on-chain quote at the same `clock` timestamp.

> If the vault state moves between off-chain snapshot and on-chain signing — e.g. another transaction in the same block deposits into the vault and changes the YT/underlying ratio — `kai_finish_supply` / `kai_finish_redeem` aborts with `EAmountShortfall (1009)`. The hot-potato ticket is then never consumed; the PM state is intact; the protocol bot retries with a fresh snapshot.

---

## Protocol PTB Recipe: Supply

`kai_start_supply` records `vault_id = object::id(vault)` on the ticket; `kai_finish_supply` re-takes `&Vault<T,YT>` and asserts the id matches, aborting with `EWrongVault (1013)` on mismatch. Reuse the same `tx.object(vaultObjectId)` handle across `start_*` and `finish_*`.

Authoritative signatures:

```move
public fun kai_start_supply<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<T>, KaiSupplyTicket<T, YT>);

public fun kai_finish_supply<T, YT>(
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    ticket: KaiSupplyTicket<T, YT>,
    yt: Coin<YT>,
);
```

3 commands:

```
1. cdpm::kai_start_supply<T, YT>(access, pm, vault, amount, clock)        → (coin_t, ticket)
2. kai_sav::vault::deposit<T, YT>(vault, coin_t.into_balance(), clock)    → balance_yt
3. cdpm::kai_finish_supply<T, YT>(pm, vault, ticket, balance_yt.into_coin())
```

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function protocolSupplyToKai(
  client: SuiGrpcClient,
  protocolSigner: any,         // address must be in AccessList AND pm.agents must be empty
  pmId: string,
  underlyingCoinType: string,
  ytCoinType: string,
  vaultObjectId: string,
  amount: bigint,
) {
  const tx = new Transaction();

  const [coinT, ticket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_start_supply`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(vaultObjectId),
      tx.pure.u64(amount),
      tx.object('0x6'),
    ],
  });

  const balanceT = tx.moveCall({
    target: '0x2::coin::into_balance',
    typeArguments: [underlyingCoinType],
    arguments: [coinT],
  });
  const balanceYT = tx.moveCall({
    target: `${KAI_SAV_PACKAGE}::vault::deposit`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [tx.object(vaultObjectId), balanceT, tx.object('0x6')],
  });
  const coinYT = tx.moveCall({
    target: '0x2::coin::from_balance',
    typeArguments: [ytCoinType],
    arguments: [balanceYT],
  });

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_finish_supply`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [
      tx.object(pmId),
      tx.object(vaultObjectId),
      ticket,
      coinYT,
    ],
  });

  return await client.signAndExecuteTransaction({ signer: protocolSigner, transaction: tx });
}
```

**`MAX_U64` is a "drain whatever's there" sentinel.** `kai_start_supply` pulls the underlying via the internal `withdraw_from_balance<T>` helper (`cdpm.move:1271-1286`), which clamps `amount >= balance_amount` and removes the bag entry; the post-clamp `coin.value()` is what feeds `compute_expected_yt`. So passing `tx.pure.u64(MAX_U64)` consumes the entire `pm.balance[T]` entry, and the only remaining abort path is `EZeroExpected (1007)` if the entry is empty / dust. This mirrors `protocol_transfer_fee_to_balance`, which uses the same sentinel today (the helper has identical clamp logic in `withdraw_from_fee`, `cdpm.move:1301-1316`). Prefer the sentinel for atomic-rebalance flows where the supply leg should atomically absorb the prior redeem residual without an off-chain dev-inspect round trip. Use an explicit sized `amount` only when you intentionally want to leave a residual in `pm.balance[T]`.

---

## Protocol PTB Recipe: Redeem (with strategy walk)

Variable length (4 + N commands). `vault::withdraw` returns a `WithdrawTicket` recording per-strategy `to_withdraw` quotas; the protocol bot's PTB has to walk every strategy with non-zero quota, then settle with `vault::redeem_withdraw_ticket`. The off-chain SDK is responsible for enumerating active strategies — cdpm does **not** track them.

`kai_start_redeem` records `vault_id`; `kai_finish_redeem` re-takes `&Vault<T,YT>` and asserts the id matches (`EWrongVault = 1013`).

Authoritative signatures:

```move
public fun kai_start_redeem<T, YT>(
    access: &AccessList,
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    yt_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<YT>, KaiRedeemTicket<T, YT>);

public fun kai_finish_redeem<T, YT>(
    pm: &mut PositionManager,
    vault: &kai_vault::Vault<T, YT>,
    fee_house: &mut FeeHouse,
    ticket: KaiRedeemTicket<T, YT>,
    underlying: Coin<T>,
    ctx: &mut TxContext,
);
```

```
1. cdpm::kai_start_redeem<T, YT>(access, pm, vault, yt_amount, clock)          → (coin_yt, ticket)
2. kai_sav::vault::withdraw<T, YT>(vault, coin_yt.into_balance(), clock)       → withdraw_ticket
3..3+N. for each strategy s with to_withdraw(s) > 0:
        <strategy_module>::strategy_withdraw_for_vault(strategy, vault, withdraw_ticket, ...)
3+N+1. balance_t = kai_sav::vault::redeem_withdraw_ticket<T, YT>(vault, withdraw_ticket)
3+N+2. cdpm::kai_finish_redeem<T, YT>(pm, vault, fee_house, ticket, balance_t.into_coin())
```

```typescript
async function protocolRedeemFromKai(
  client: SuiGrpcClient,
  protocolSigner: any,
  pmId: string,
  underlyingCoinType: string,
  ytCoinType: string,
  vaultObjectId: string,
  ytAmount: bigint,
  // Off-chain SDK enumerates active strategies attached to the live Vault<T, YT>
  // and returns one move-call descriptor per strategy with to_withdraw > 0.
  strategyWalkers: Array<{
    target: string;
    typeArguments: string[];
    extraArgs: (tx: Transaction, withdrawTicket: any) => any[];
  }>,
) {
  const tx = new Transaction();

  const [coinYT, ticket] = tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_start_redeem`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [
      tx.object(CDPM_MAINNET.ACCESS_LIST_ID),
      tx.object(pmId),
      tx.object(vaultObjectId),
      tx.pure.u64(ytAmount),
      tx.object('0x6'),
    ],
  });

  const balanceYT = tx.moveCall({
    target: '0x2::coin::into_balance',
    typeArguments: [ytCoinType],
    arguments: [coinYT],
  });
  const withdrawTicket = tx.moveCall({
    target: `${KAI_SAV_PACKAGE}::vault::withdraw`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [tx.object(vaultObjectId), balanceYT, tx.object('0x6')],
  });

  for (const walker of strategyWalkers) {
    tx.moveCall({
      target: walker.target,
      typeArguments: walker.typeArguments,
      arguments: walker.extraArgs(tx, withdrawTicket),
    });
  }

  const balanceT = tx.moveCall({
    target: `${KAI_SAV_PACKAGE}::vault::redeem_withdraw_ticket`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [tx.object(vaultObjectId), withdrawTicket],
  });
  const coinT = tx.moveCall({
    target: '0x2::coin::from_balance',
    typeArguments: [underlyingCoinType],
    arguments: [balanceT],
  });

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::kai_finish_redeem`,
    typeArguments: [underlyingCoinType, ytCoinType],
    arguments: [
      tx.object(pmId),
      tx.object(vaultObjectId),
      tx.object(CDPM_MAINNET.FEE_HOUSE_ID),
      ticket,
      coinT,
    ],
  });

  return await client.signAndExecuteTransaction({ signer: protocolSigner, transaction: tx });
}
```

`strategy_withdraw_for_vault` discharges its own `kai_leverage::access_management::ActionRequest` internally — protocol bots do **not** assemble or co-sign an `ActionRequest`. The walk is purely a sequence of move calls the SDK builds from the live `Vault<T, YT>` snapshot.

### Sizing Redemptions Before Calling `kai_start_redeem`

Protocol bots, like agents, usually know "I need `K` underlying for the next operation" and must compute `yt_amount` from that. `kai_start_redeem` takes YT, not underlying.

- **Pre-fee target** — I need at least `K` underlying out of Kai, ignoring fee:

  ```
  yt_to_burn = ceil(K × yt_supply / total_available_balance)
  ```

- **Post-fee target** — I want `K` net to land in `pm.balance[T]` after the yield fee. Closed-form (interest-exists branch):

  ```
  yt_to_burn ≈ ceil(K × 10000 × yt_supply × YT_in_pm
                    / ((10000 − r_bp) × total_available × YT_in_pm + r_bp × yt_supply × P_in_pm))
  ```

Both use **ceiling division** because cdpm's prediction floors. Asking for `floor(N)` risks receiving 1 unit fewer than the target. The full derivation, edge cases, and an iterative refinement helper (`ytToBurnForTargetNet`) live in [`cdpm-calculation-skill/reference/kai-lending-math.md`](../../cdpm-calculation-skill/reference/kai-lending-math.md) section 7.

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
  ytCoinType: string,
  vaultObjectId: string,
  desiredNet: bigint,
  feeRateBp: bigint,
  vaultSnapshot: KaiVaultSnapshot,
  pmKaiVault: KaiPmVaultSnapshot,
  strategyWalkers: any[],
) {
  const ytAmount = ytToBurnForTargetNet(
    vaultSnapshot, pmKaiVault, desiredNet, feeRateBp,
  );

  return protocolRedeemFromKai(
    client, protocolSigner, pmId,
    underlyingCoinType, ytCoinType, vaultObjectId,
    ytAmount,
    strategyWalkers,
  );
}
```

`ytToBurnForTargetNet` returns `MAX_U64` when the `KaiVault<T, YT>` entry cannot satisfy `desiredNet`; passing that value to `kai_start_redeem` drains the entry and removes its bag entry from `pm.lending`. Always re-snapshot vault state right before signing — Kai's `total_available_balance` ticks every block as time-locked profit unlocks.

---

## Protocol-Tier Permission Invariant

The protocol-tier branch of `assert_caller_authorized` *only* fires when `pm.agents.is_empty()`. Once the owner authorizes any agent, the protocol tier is locked out until every agent is revoked. This is the same rule Scallop uses; it applies to both `kai_start_supply` and `kai_start_redeem`.

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

**No wrapper-extract escape for lending.** cdpm exposes no `user_extract_kai_yt`-style function for anyone — not for protocol bots, not for the owner. If Kai is impaired, no caller can rescue raw `Coin<YT>` from `pm.lending`. The only exit is the full redeem flow (`kai_start_redeem` → `vault::withdraw` → strategy walk → `redeem_withdraw_ticket` → `kai_finish_redeem`); if Kai's `vault::withdraw` aborts (Version bump, withdrawals disabled, etc.), the cdpm hot-potato ticket is never consumed, `pm.lending` stays intact, and recovery is to retry the normal flow once Kunalabs ships an SDK update against the new Version.

---

## Events Emitted by Protocol Kai Operations

Identical event types as user/agent paths — Sui event envelopes already record `event.sender`, so the protocol address is observable without a separate `by` field.

```typescript
interface KaiSupplied {
  pm_id: string;
  coin_type: string;
  yt_type: string;
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

cdpm emits no extraction event for Kai lending — there is no wrapper-extract function. `KaiRedeemed` is the only exit-related Kai event and is emitted by `kai_finish_redeem` once the underlying lands in `pm.balance`.

---

## Error Cheat Sheet (protocol-flavored)

| Code | Constant | Most likely cause for a protocol bot |
|------|----------|---------------------------------------|
| 1002 | `ENotAllow` | Either: protocol address not in AccessList, or PM has at least one agent (protocol-tier locked out). Snapshot `pm.agents` and `access.allow` before each batch. |
| 1004 | `ELendingNotEmpty` | Owner attempted `user_close_pm` while the protocol bot still has a Kai entry in `pm.lending`. Coordinate with owner — drain via the full redeem flow before close (no wrapper-extract bypass exists). |
| 1005 | `ENoSuchVault` | `kai_start_redeem` for a `(T, YT)` pair with no entry. Re-fetch `pm.lending` before sizing. |
| 1006 | `EReserveEmpty` | `total_yt_supply == 0` on the live vault — degenerate. Bootstrap by supplying first or skip this vault. |
| 1007 | `EZeroExpected` | Amount too small for the current vault ratio. Increase amount; for tiny TVL vaults, batch multiple PMs into one supply. |
| 1008 | `EWrongPm` | Hot-potato ticket consumed against a different PM. Bug in batch construction — assert `pmId` consistency across all four cdpm move-calls in the batch. |
| 1009 | `EAmountShortfall` | Vault state moved between snapshot and signing. Re-snapshot and retry; for large redeems, size with a small margin via `ytToBurnForTargetNet`. |
| 1013 | `EWrongVault` | `kai_finish_*` received a `&Vault<T,YT>` whose id ≠ ticket.vault_id. Reuse the same `tx.object(vaultObjectId)` handle across `start_*` and `finish_*`. |

External aborts that bubble up from Kai itself (cdpm does not produce these):

- `vault::EWithdrawalsDisabled` — admin disabled withdrawals; nobody can drain through cdpm. `pm.lending` stays intact (the hot-potato ticket is never consumed) and waits for Kunalabs to re-enable withdrawals.
- `vault::ETvlCapExceeded` — admin set a `tvl_cap` that the supply would breach.
- `vault::ERateLimit` — admin-configured rate limiter rejected the operation.

When any of these hit, the cdpm hot-potato ticket is never consumed (the abort happens inside the inner Kai move-call before `kai_finish_*` runs), so the PM state is intact. The protocol bot can reschedule once Kai is healthy.
