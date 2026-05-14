# Agent Operations

## Contents

- [Helper: Get Pool ID from PositionManager](#helper-get-pool-id-from-positionmanager)
- [Add Liquidity](#add-liquidity)
- [Remove Liquidity](#remove-liquidity)
- [Collect Fees](#collect-fees)
- [Collect Rewards](#collect-rewards)
- [Transfer Fee to Balance](#transfer-fee-to-balance)
- [Scallop Lending (Supply / Redeem Idle Balance)](#scallop-lending-supply-redeem-idle-balance)

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

## Add Liquidity

```typescript
import { Transaction } from '@mysten/sui/transactions';

async function agentAddLiquidity(
  client: SuiGrpcClient,
  signer: any,  // Agent's keypair
  pmId: string,
  poolId: string,  // Can be fetched from PositionManager
  amountA: bigint,  // Amount to withdraw from balance
  amountB: bigint,
  bins: number[],
  amountsA: bigint[],
  amountsB: bigint[]
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::agent_add_liquidity`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
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
async function agentAddLiquidityAuto(
  client: SuiGrpcClient,
  signer: any,
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
  
  return agentAddLiquidity(
    client, signer, pmId, poolId,
    amountA, amountB, bins, amountsA, amountsB
  );
}
```

## Remove Liquidity

```typescript
async function agentRemoveLiquidity(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  poolId: string,  // Can be fetched from PositionManager
  bins: number[],
  liquidityShares: bigint[]
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::agent_remove_liquidity`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
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

// Example: Auto-fetch pool_id from PositionManager
async function agentRemoveLiquidityAuto(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  bins: number[],
  liquidityShares: bigint[]
) {
  // Read pool_id from PositionManager's position field
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no associated pool');
  }
  
  return agentRemoveLiquidity(
    client, signer, pmId, poolId,
    bins, liquidityShares
  );
}
```

## Collect Fees

```typescript
async function agentCollectFees(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  poolId: string  // Can be fetched from PositionManager
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::agent_collect_fee`,
    typeArguments: [coinTypeA, coinTypeB],
    arguments: [
      tx.object(pmId),
      tx.object(poolId),
      tx.object(globalConfigId),
      tx.object(versionedId),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}

// Example: Auto-fetch pool_id from PositionManager
async function agentCollectFeesAuto(
  client: SuiGrpcClient,
  signer: any,
  pmId: string
) {
  // Read pool_id from PositionManager's position field
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no associated pool');
  }
  
  return agentCollectFees(client, signer, pmId, poolId);
}
```

## Collect Rewards

```typescript
async function agentCollectRewards(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  poolId: string,
  rewardType: string
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::agent_collect_reward`,
    typeArguments: [coinTypeA, coinTypeB, rewardType],
    arguments: [
      tx.object(pmId),
      tx.object(poolId),
      tx.object(globalConfigId),
      tx.object(versionedId),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}

// Example: Auto-fetch pool_id from PositionManager
async function agentCollectRewardsAuto(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  rewardType: string
) {
  // Read pool_id from PositionManager's position field
  const poolId = await getPoolIdFromPositionManager(client, pmId);
  if (!poolId) {
    throw new Error('PositionManager has no associated pool');
  }
  
  return agentCollectRewards(client, signer, pmId, poolId, rewardType);
}
```

## Transfer Fee to Balance

```typescript
async function agentTransferFeeToBalance(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  coinType: string,
  amount: bigint
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::agent_transfer_fee_to_balance`,
    typeArguments: [coinType],
    arguments: [
      tx.object(pmId),
      tx.pure.u64(amount),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## Scallop Lending (Supply / Redeem Idle Balance)

> **REQUIRED — every Scallop PTB starts with `accrue_interest_for_market`.**
> `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)`
> MUST be **command 0** of any PTB that touches `scallop_start_supply` or
> `scallop_start_redeem`. cdpm aborts with `EStaleScallopState (1011)` otherwise.
> The Scallop TS SDK does NOT inject this call. The agent scheduler must always
> emit it, even for "single-step" rebalances.

cdpm exposes a hot-potato lending API shared by owner / agent / whitelisted protocol bots. Authorization is decided in `assert_caller_authorized` inside `scallop_start_supply` and `scallop_start_redeem`: agents pass when their address is in `pm.agents`. `scallop_finish_supply` / `scallop_finish_redeem` only check `ticket.pm_id == object::id(pm)`.

### Constraints Agents Should Know (most critical first)

- **Freshness floor (F-01 / F-02 hardening) — non-negotiable.** `scallop_start_supply` / `scallop_start_redeem` now take `&Clock` and assert Scallop's per-asset `last_updated == clock.timestamp_ms / 1000`. Omitting the `accrue_interest_for_market` pre-step aborts at the cdpm boundary with `EStaleScallopState (1011)` before any balance is touched. Every Scallop PTB the agent signs must begin with this command.
- **Canonical Market binding (F-03 hardening)**: `start_*` records `market_id = object::id(market)` on the ticket; `scallop_finish_*` re-takes `&Market` and asserts the id matches, aborting with `EWrongMarket (1012)`. Reuse the same `tx.object(SCALLOP_MARKET_ID)` across `start_*` and `finish_*`.
- **One vault per underlying T**: `pm.lending` keys on the underlying `T` only. The sCoin type is structurally pinned to `MarketCoin<T>` by the type system, so a fake-sCoin variant cannot be supplied — there is no longer a separate `S` generic to mismatch.
- **Yield fee applies to agents**: `scallop_finish_redeem` computes `fee_amount = floor(max(0, redeemed − principal_portion) × fee_house.fee_rate / 10_000)` regardless of caller, so agent redeems pay the same yield fee as owner / protocol redeems.
- **No escape hatch for lending**: cdpm exposes no `user_extract_scallop_market_coin`-style wrapper-extraction function for anyone. If Scallop is unreachable, the inner `mint::mint` / `redeem::redeem` aborts before any cdpm `*_finish_*` command runs, so the hot-potato ticket is never consumed and `pm.lending` stays intact. Recovery is to retry the normal redeem flow once Scallop ships an SDK update against the new Version.
- **Agents cannot short-change the vault**: `scallop_finish_supply` requires `Coin<MarketCoin<T>>` (the only way to obtain a non-zero `Coin<MarketCoin<T>>` is through Scallop's `mint`, since `MarketCoin` has only `drop` and no public constructor) and asserts `actual >= ticket.expected_scoin`. The same two-axis defense applies on redeem.

### PTB Recipe — Agent Supply

The first PTB command **MUST** be `protocol::accrue_interest::accrue_interest_for_market`. cdpm enforces this: `scallop_start_supply` reads `borrow_dynamics::last_updated_by_type(market.borrow_dynamics(), type<T>)` and asserts equality with `clock::timestamp_ms(clock) / 1000`. Omission aborts with `EStaleScallopState (1011)`.

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

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::scallop_start_supply<T>(access, pm, market, clock, amount)       → (coin_t, ticket)
3. protocol::mint::mint<T>(version, market, coin_t, clock)                → coin_market<T>
4. cdpm::scallop_finish_supply<T>(pm, market, ticket, coin_market)
```

```typescript
async function agentSupplyToScallop(
  client: SuiGrpcClient,
  signer: any,           // Agent keypair
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

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

### PTB Recipe — Agent Redeem

Same freshness-first rule. Net underlying (after yield fee) lands back in `pm.balance[T]`.

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

```
1. protocol::accrue_interest::accrue_interest_for_market(version, market, clock)
2. cdpm::scallop_start_redeem<T>(access, pm, market, clock, scoin_amount) → (coin_market, ticket)
3. protocol::redeem::redeem<T>(version, market, coin_market, clock)       → coin_t
4. cdpm::scallop_finish_redeem<T>(pm, market, fee_house, ticket, coin_t)
```

```typescript
async function agentRedeemFromScallop(
  client: SuiGrpcClient,
  signer: any,
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

  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

### Sizing Redemptions Before Calling `scallop_start_redeem`

Agent bots typically know "I need `K` underlying to fund a rebalance" and must compute `market_coin_amount` from that. `scallop_start_redeem` takes sCoin, not underlying, so the bot has to invert `compute_expected_underlying_scallop` (and the yield-fee deduction) before signing.

There are two practical inverses:

- **Pre-fee target** — I need at least `K` underlying delivered by Scallop, ignoring fee:
  ```
  scoin_to_burn = ceil(K × supply / denom)            // denom = cash + debt − revenue
  ```
- **Post-fee target** — I need at least `K` net underlying credited to `pm.balance[T]`:
  ```
  Let r = fee_rate / 10000, π = P_vault / S_vault, p = denom / supply
  N ≈ ceil(K / (p × (1 − r) + r × π))                  when p >  π   (interest exists)
  N  = ceil(K × supply / denom)                        when p <= π   (no interest, no fee)
  ```

Both use **ceiling division** because Scallop's redeem floors the underlying output. The full derivation, edge cases, and an iterative refinement helper (`scoinToBurnForTargetNet`) live in [`cdpm-calculation-skill/reference/scallop-lending-math.md`](../../cdpm-calculation-skill/reference/scallop-lending-math.md) section 7.

```typescript
import {
  scoinToBurnForTargetUnderlying,
  scoinToBurnForTargetNet,
} from './scallop-lending-math';

// Bot strategy: "rebalance needs 100 USDC of dry powder, net of fee."
async function agentSizedRedeem(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  underlyingCoinType: string,
  desiredNet: bigint,           // K in underlying base units
  feeRateBp: bigint,            // read from FeeHouse.fee_rate
) {
  // 1. Dry-run the accrue+read PTB; snapshot reserve + vault state.
  const reserve = await readReserveSnapshot(client, underlyingCoinType);
  const vault   = await readVaultSnapshot(client, pmId, underlyingCoinType);

  // 2. Solve for sCoin to burn.
  const scoinAmount = scoinToBurnForTargetNet(
    reserve, vault, desiredNet, feeRateBp,
  );

  // 3. Feed it into the agent redeem PTB. MAX_U64 drains the vault when the
  //    target is unreachable.
  return agentRedeemFromScallop(
    client, signer, pmId, underlyingCoinType, scoinAmount,
  );
}
```

The closed-form approximation is occasionally off-by-one due to per-step floors inside `scallop_finish_redeem`; the iterative helper bumps `N` upward by 1 sCoin until forward simulation confirms `>= desiredNet`. Re-snapshot the reserve and vault *after* `accrue_interest_for_market` and before sizing — stale snapshots can leave the bot 1-2 underlying short on the very next block.

### Tickets Are Hot Potatoes

`ScallopSupplyTicket<T>` and `ScallopRedeemTicket<T>` have **no `drop` ability** — the only way to discharge them is via the matching `finish_*` call inside the same PTB. If your strategy chains conditional commands, never branch the ticket out of the success path.
