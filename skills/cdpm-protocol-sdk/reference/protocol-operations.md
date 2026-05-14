# Protocol Operations

## Contents

- [Helper: Get Pool ID from PositionManager](#helper-get-pool-id-from-positionmanager)
- [Add Liquidity (Protocol)](#add-liquidity-protocol)
- [Remove Liquidity (Protocol)](#remove-liquidity-protocol)
- [Transfer Fee to Balance (Protocol)](#transfer-fee-to-balance-protocol)
- [Collect Fees (Protocol)](#collect-fees-protocol)
- [Scallop Lending (Supply / Redeem)](#scallop-lending-supply-redeem)

## Helper: Get Pool ID from PositionManager

```typescript
async function getPoolIdFromPositionManager(
  client: SuiGrpcClient,
  pmId: string
): Promise<string | null> {
  const { response: pm } = await client.getObject({
    id: pmId,
    include: { content: true },
  });
  
  // Read pool_id from PositionManager's position field
  return pm?.content?.fields?.position?.fields?.pool_id || null;
}
```

## Add Liquidity (Protocol)

```typescript
async function protocolAddLiquidity(
  client: SuiGrpcClient,
  signer: any,  // Must be in AccessList
  accessListId: string,
  pmId: string,
  poolId: string,  // Can be fetched from PositionManager
  amountA: bigint,
  amountB: bigint,
  bins: number[],
  amountsA: bigint[],
  amountsB: bigint[]
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::protocol_add_liquidity`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(accessListId),
      tx.object(pmId),
      tx.object(poolId),
      tx.pure.u64(amountA),
      tx.pure.u64(amountB),
      tx.pure.vector('u32', bins),
      tx.pure.vector('u64', amountsA),
      tx.pure.vector('u64', amountsB),
      tx.object(globalConfigId),
      tx.object(versionedId),
      tx.object(clockId),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}

// Example: Auto-fetch pool_id from PositionManager
async function protocolAddLiquidityAuto(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  pmId: string,
  amountA: bigint,
  amountB: bigint,
  bins: number[],
  amountsA: bigint[],
  amountsB: bigint[]
) {
  // Read pool_id from PositionManager's position field
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no associated pool');
  }
  
  return protocolAddLiquidity(
    client, signer, accessListId, pmId, poolId,
    amountA, amountB, bins, amountsA, amountsB
  );
}
```

## Remove Liquidity (Protocol)

> Signature keeps `clk: &Clock` because it is forwarded to `pool::remove_liquidity` in the Cetus DLMM SDK.

Removed assets are returned to the PositionManager's internal balance bag (not to the caller). Use `protocol_transfer_fee_to_balance` or other balance helpers to move funds afterward.

```typescript
async function protocolRemoveLiquidity(
  client: SuiGrpcClient,
  signer: any,  // Must be in AccessList
  accessListId: string,
  pmId: string,
  poolId: string,  // Can be fetched from PositionManager
  bins: number[],
  liquidityShares: bigint[]
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::protocol_remove_liquidity`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(accessListId),
      tx.object(pmId),
      tx.object(poolId),
      tx.pure.vector('u32', bins),
      tx.pure.vector('u128', liquidityShares),
      tx.object(globalConfigId),
      tx.object(versionedId),
      tx.object(clockId),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## Transfer Fee to Balance (Protocol)

Move accumulated fee bag funds back into the PositionManager's balance bag so they can be used by subsequent protocol operations.

> Signature: `protocol_transfer_fee_to_balance<T>(access, pm, amount, ctx)` — **does not take Clock**.

The emitted `FeeTransferredToBalance.amount` reflects the actual coin value moved (which may be smaller than the requested `amount` when the fee bag holds less than requested).

```typescript
async function protocolTransferFeeToBalance(
  client: SuiGrpcClient,
  signer: any,  // Must be in AccessList
  accessListId: string,
  pmId: string,
  coinType: string,
  amount: bigint
) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::protocol_transfer_fee_to_balance`,
    typeArguments: [coinType],
    arguments: [
      tx.object(accessListId),
      tx.object(pmId),
      tx.pure.u64(amount),
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## Collect Fees (Protocol)

```typescript
async function protocolCollectFees(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  feeHouseId: string,
  pmId: string,
  poolId: string  // Can be fetched from PositionManager
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::protocol_collect_fee`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(accessListId),
      tx.object(feeHouseId),
      tx.object(pmId),
      tx.object(poolId),
      tx.object(globalConfigId),
      tx.object(versionedId),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}

// Example: Auto-fetch pool_id from PositionManager
async function protocolCollectFeesAuto(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  feeHouseId: string,
  pmId: string
) {
  // Read pool_id from PositionManager's position field
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no associated pool');
  }
  
  return protocolCollectFees(
    client, signer, accessListId, feeHouseId, pmId, poolId
  );
}
```

## Scallop Lending (Supply / Redeem)

> **REQUIRED — every Scallop PTB starts with `accrue_interest_for_market`.**
> `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)`
> MUST be **command 0** of any PTB that touches `scallop_start_supply` or
> `scallop_start_redeem`. cdpm aborts with `EStaleScallopState (1011)` otherwise.
> The Scallop SDK does NOT inject this call. No SDK shortcut. No optional path.

The Scallop hot-potato API is open to whitelisted protocol bots, but only when `pm.agents` is empty (the protocol-tier invariant). `assert_caller_authorized` inside `scallop_start_supply` / `scallop_start_redeem` lets the bot through under the union `is_owner || is_agent || (is_in_access_list && pm.agents.is_empty())`.

`scallop_finish_supply` / `scallop_finish_redeem` only verify `ticket.pm_id == object::id(pm)` — the auth check is done up front.

### Pre-flight: Accrue Interest First (Enforced)

cdpm now enforces freshness: `scallop_start_supply` / `scallop_start_redeem` take `&Clock` and assert `borrow_dynamics::last_updated_by_type(market.borrow_dynamics(), type<T>) == clock::timestamp_ms(clock) / 1000`. Omitting `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)` as command 0 aborts at the cdpm boundary with `EStaleScallopState (1011)` before any balance is touched. `scallop_finish_*` also re-take `&Market` and assert canonical-id match (`EWrongMarket = 1012`).

### PTB Recipe — Protocol Supply

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::scallop_start_supply<T>(access, pm, market, clock, amount)       → (coin_t, ticket)
3. protocol::mint::mint<T>(version, market, coin_t, clock)                → coin_market<T>
4. cdpm::scallop_finish_supply<T>(pm, market, ticket, coin_market)
```

```typescript
async function protocolSupplyToScallop(
  client: SuiGrpcClient,
  signer: any,                 // Must be in AccessList.allow
  accessListId: string,
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
      tx.object(accessListId),
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

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

### PTB Recipe — Protocol Redeem (Yield Fee Applies)

`scallop_finish_redeem` deducts `floor(max(0, redeemed − principal_portion) × fee_house.fee_rate / 10_000)` from the interest portion before adding the rest to `pm.balance[T]`. Protocol callers pay the same yield fee as owner / agent.

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::scallop_start_redeem<T>(access, pm, market, clock, scoin_amount) → (coin_market, ticket)
3. protocol::redeem::redeem<T>(version, market, coin_market, clock)       → coin_t
4. cdpm::scallop_finish_redeem<T>(pm, market, fee_house, ticket, coin_t)
```

```typescript
async function protocolRedeemFromScallop(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  feeHouseId: string,
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
      tx.object(accessListId),
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
      tx.object(feeHouseId),
      ticket,
      coinT,
    ],
  });

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

### Sizing Redemptions Before Calling `scallop_start_redeem`

Protocol bots, like agents, usually know "I need `K` underlying for the next operation" and must compute `market_coin_amount` from that. `scallop_start_redeem` takes sCoin, not underlying, so the bot has to invert `compute_expected_underlying_scallop` (and the yield-fee deduction) before signing.

Two practical inverses:

- **Pre-fee target** — I need at least `K` underlying out of Scallop, ignoring fee:
  ```
  scoin_to_burn = ceil(K × supply / denom)            // denom = cash + debt − revenue
  ```
- **Post-fee target** — I need at least `K` net underlying credited to `pm.balance[T]`:
  ```
  Let r = fee_rate / 10000, π = P_vault / S_vault, p = denom / supply
  N ≈ ceil(K / (p × (1 − r) + r × π))                  when p >  π   (interest exists)
  N  = ceil(K × supply / denom)                        when p <= π   (no interest, no fee)
  ```

Both use **ceiling division** because Scallop's redeem floors the underlying output. Asking for `floor(N)` risks receiving 1 unit fewer than the target. The full derivation, edge cases, and an iterative refinement helper (`scoinToBurnForTargetNet`) live in [`cdpm-calculation-skill/reference/scallop-lending-math.md`](../../cdpm-calculation-skill/reference/scallop-lending-math.md) section 7.

```typescript
import {
  scoinToBurnForTargetUnderlying,
  scoinToBurnForTargetNet,
} from './scallop-lending-math';

async function protocolSizedRedeem(
  client: SuiGrpcClient,
  signer: any,
  accessListId: string,
  feeHouseId: string,
  pmId: string,
  underlyingCoinType: string,
  desiredNet: bigint,           // K in underlying base units
  feeRateBp: bigint,            // read from FeeHouse.fee_rate
) {
  const reserve = await readReserveSnapshot(client, underlyingCoinType);
  const vault   = await readVaultSnapshot(client, pmId, underlyingCoinType);

  const scoinAmount = scoinToBurnForTargetNet(
    reserve, vault, desiredNet, feeRateBp,
  );

  return protocolRedeemFromScallop(
    client, signer, accessListId, feeHouseId,
    pmId, underlyingCoinType, scoinAmount,
  );
}
```

`scoinToBurnForTargetNet` returns `MAX_U64` when the vault cannot satisfy `desiredNet`; passing that value to `scallop_start_redeem` drains the entire vault and removes its entry from `pm.lending`. Always re-snapshot reserve and vault *after* the `accrue_interest_for_market` command and before sizing — stale snapshots predict a higher `denom` than the live reserve and can leave the bot 1-2 underlying short.

### No Wrapper-Extract Escape for Lending

cdpm exposes **no** `user_extract_scallop_market_coin`-style wrapper-extraction function for anyone — not for protocol bots, not for agents, not even for the owner. The only exit path from `pm.lending` is the full redeem flow: `scallop_start_redeem` → `redeem::redeem` (in the caller's PTB) → `scallop_finish_redeem` (which deducts the yield fee and deposits the underlying into `pm.balance[T]`) → `user_remove_liquidity_from_balance<T>` (owner-only). If Scallop is unreachable (Version bump, paused market), the inner `redeem::redeem` aborts before any cdpm `*_finish_*` runs, so the hot-potato ticket is never consumed and `pm.lending` stays intact; recovery is to retry the normal redeem flow once Scallop ships an SDK update against the new Version.
