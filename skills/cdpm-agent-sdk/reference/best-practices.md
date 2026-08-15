# Best Practices

## Contents

- [1. Pre-Operation Checks](#1-pre-operation-checks)
- [2. Batch Operations](#2-batch-operations)
- [3. Gas Optimization](#3-gas-optimization)
- [Lending Pre-Flight](#lending-pre-flight)
- [Surfacing Close-Position Warnings](#surfacing-close-position-warnings)
- [Security Guidelines](#security-guidelines)

## 1. Pre-Operation Checks

```typescript
async function preOperationChecks(
  client: SuiGrpcClient,
  pmId: string,
  agentAddress: string
): Promise<{ canProceed: boolean; reason?: string }> {
  // 1. Verify agent authorization
  const { response: pm } = await client.getObject({ id: pmId, include: { content: true } });
  const agents = pm?.content?.fields?.agents || [];
  
  if (!agents.includes(agentAddress)) {
    return { canProceed: false, reason: 'Not authorized' };
  }

  // 2. Check position exists (Option<Position> — absent when destroyed / never created)
  const position = pm?.content?.fields?.position;
  if (!position) {
    return { canProceed: false, reason: 'No active position — call agent_create_position first' };
  }

  // 3. Check sufficient balance (for add liquidity)
  const balance = pm?.content?.fields?.balance;
  // ... verify amounts

  return { canProceed: true };
}
```

## 2. Batch Operations

```typescript
async function batchOperations(
  client: SuiGrpcClient,
  signer: any,
  operations: Array<{
    type: string;
    params: any;
  }>
) {
  const tx = new Transaction();
  
  for (const op of operations) {
    switch (op.type) {
      case 'collectFees':
        tx.moveCall({
          target: `${CDPM_PACKAGE}::cdpm::agent_collect_fee`,
          typeArguments: op.params.typeArgs,
          arguments: [
            tx.object(op.params.pmId),
            tx.object(op.params.poolId),
            tx.object(globalConfigId),
            tx.object(versionedId),
          ],
        });
        break;
      // ... other operations
    }
  }
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## 3. Gas Optimization

```typescript
const GAS_OPTIMIZATION = {
  // Batch multiple operations in single PTB
  batchOperations: true,
  
  // Use dry run to estimate gas
  estimateBeforeExecute: true,
  
  // Set appropriate gas budget
  gasBudgetMultiplier: 1.2,  // 20% buffer
  
  // Retry with higher gas if estimation fails
  retryWithHigherGas: true,
};

async function executeWithGasOptimization(
  client: SuiGrpcClient,
  signer: any,
  buildTx: (tx: Transaction) => void
) {
  const tx = new Transaction();
  buildTx(tx);
  
  // Dry run to estimate gas
  const dryRun = await client.dryRunTransactionBlock({
    transactionBlock: await tx.build({ client }),
  });
  
  // Set gas budget with buffer
  const gasBudget = BigInt(dryRun.effects.gasUsed.computationCost) * 
                    BigInt(Math.ceil(GAS_OPTIMIZATION.gasBudgetMultiplier * 100)) / 100n;
  
  tx.setGasBudget(gasBudget);
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## Lending Pre-Flight

cdpm exposes two lending integrations. Each entry is a single `tx.moveCall`:

### Scallop

```
cdpm::scallop_supply<T>(access, pm, version, market, amount, clock)
cdpm::scallop_redeem<T>(access, pm, fee_house, version, market, scoin_amount, clock)
```

Scallop's `protocol::mint::mint` and `protocol::redeem::redeem` call `accrue_interest_for_market` as their first step, so the balance sheet read inside the cdpm move call is fresh by construction. The agent does not need to add a separate accrual command.

### Kai SAV

```
cdpm::kai_supply<T, YT>(access, pm, vault, amount, clock)
cdpm::kai_redeem<T, ST, YT>(access, pm, fee_house, vault, strategy, supply_pool, yt_amount, clock)
```

`kai_redeem` walks the Kai withdrawal chain (`vault::withdraw → klsp::withdraw → vault::redeem_withdraw_ticket`) internally. Re-snapshot the vault immediately before signing — Kai's `total_available_balance` ticks every block as time-locked profit unlocks, and stale snapshots can leave the bot 1-2 underlying short.

See [`scallop-lending.md`](./scallop-lending.md) and [`kai-lending.md`](./kai-lending.md) for the full per-integration recipes.

### Shared agent-side notes

- One Scallop vault per underlying `T`; one Kai vault per `(T, YT)` pair (bag keys differ — `type_name<T>` vs `type_name<YT>` — so the same underlying can hold both simultaneously). The sCoin type is structurally pinned to `MarketCoin<T>`, and `Balance<YT>` is type-pinned to Kai's `Vault<T, YT>` (whose `TreasuryCap` is private). Agents cannot inject a fake market coin or YT — cdpm holds these balances directly and no caller-supplied coin enters the redeem path.
- Agent redeems pay the protocol yield fee (`fee_house.fee_rate × interest_portion`) on **both** Scallop and Kai paths, just like owner / protocol redeems. The same `fee_house.fee_rate` is shared.
- Passing `scoin_amount = MAX_U64` or `yt_amount = MAX_U64` drains the full vault entry (removes the bag entry, returns the entire stored balance plus all stored principal).

## Surfacing Close-Position Warnings

Agents do **not** call `user_close_pm` themselves — only the position owner can close a PositionManager. However, many agent UIs drive the owner's wallet through a "close" action, so the agent layer should surface the following warning whenever it initiates or hints at a close flow:

> `pool::close_position` (used internally by `user_close_pm`) only returns underlying tokens and accumulated trading fees. Any **incentive reward tokens** still held by the position must be collected first: `user_close_pm` asserts that every `PositionInfo.rewards_owned` entry is zero and aborts with `EPositionHasRewards (1007)` otherwise. The owner's PTB must call `user_collect_reward<CoinTypeA, CoinTypeB, RewardType>` once for each reward token on the pool (typically 1-3 types) **before** `user_close_pm`, in the same transaction.

> `user_close_pm` also asserts the three internal bags are empty:
> - `bag::is_empty(&pm.balance)` → `EBalanceNotEmpty (1008)`
> - `bag::is_empty(&pm.fee)` → `EFeeNotEmpty (1009)`
> - `bag::is_empty(&pm.lending)` → `ELendingNotEmpty (1004)` (covers both `ScallopVault<T>` and `KaiVault<T, YT>` entries)
>
> Agents can run `scallop_redeem` (passing `scoin_amount = MAX_U64` to drain) or `kai_redeem` (passing `yt_amount = MAX_U64` to drain) to clear `pm.lending`, drain `pm.balance` via `user_remove_liquidity_from_balance<T>`, and drain `pm.fee` via `user_withdraw_fee<T>`. If the upstream Scallop/Kai protocol is unreachable (Version bump, paused market, withdrawals disabled), the cdpm move call aborts atomically inside the inner upstream call and `pm.lending` stays intact; recovery is to retry the normal redeem once the upstream protocol is healthy.

See the user-sdk workflow (`cdpm-user-sdk/reference/workflows.md`, section "Close Position Safely") for the complete PTB example to reuse when building the owner-facing transaction.

## Security Guidelines

### Agent Security Checklist

```typescript
const AGENT_SECURITY = {
  // 1. Verify authorization before each operation
  verifyAuthorization: true,
  
  // 2. Log all operations
  auditLogging: true,
  
  // 3. Limit operation frequency
  rateLimiting: {
    maxOperationsPerMinute: 10,
    cooldownPeriod: 6000,  // ms
  },
  
  // 4. Validate parameters
  validateInputs: true,
  
  // 5. Monitor for anomalies
  anomalyDetection: true,
};

class SecureAgent {
  private lastOperationTime: number = 0;
  private operationCount: number = 0;

  async secureOperation(
    operation: () => Promise<any>
  ): Promise<any> {
    // Rate limiting
    const now = Date.now();
    if (now - this.lastOperationTime < AGENT_SECURITY.rateLimiting.cooldownPeriod) {
      this.operationCount++;
      if (this.operationCount > AGENT_SECURITY.rateLimiting.maxOperationsPerMinute) {
        throw new Error('Rate limit exceeded');
      }
    } else {
      this.operationCount = 1;
      this.lastOperationTime = now;
    }

    // Execute with logging
    console.log(`Executing operation at ${new Date().toISOString()}`);
    const result = await operation();
    console.log(`Operation completed: ${result.digest}`);

    return result;
  }
}
```
