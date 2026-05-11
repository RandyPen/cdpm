# Best Practices

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

  // 2. Check position exists
  const position = pm?.content?.fields?.position;
  if (!position) {
    return { canProceed: false, reason: 'No position' };
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

cdpm exposes **two** lending integrations with different pre-flight needs.

### Scallop (`scallop_start_*` / `scallop_finish_*`)

When chaining a supply or redeem, the **first** PTB command must be `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)`. cdpm only reads Scallop's `balance_sheet` view-only (`compute_expected_scoin` / `compute_expected_underlying_scallop`), so a stale accrual will make the predicted scoin/underlying exceed what Scallop actually mints/redeems and `scallop_finish_supply` / `scallop_finish_redeem` will abort with `EAmountShortfall (1009)`.

Recommended PTB shape:

```
1. accrue_interest_for_market
2. cdpm::scallop_start_supply  | cdpm::scallop_start_redeem
3. protocol::mint::mint | protocol::redeem::redeem
4. cdpm::scallop_finish_supply | cdpm::scallop_finish_redeem
```

### Kai SAV (`kai_start_*` / `kai_finish_*`)

**No pre-flight accrual command.** Kai's `total_available_balance(vault, clock)` already folds in time-locked profit via `tlb::max_withdrawable`, and cdpm's `compute_expected_yt` / `compute_expected_underlying_kai` read the same auto-accruing pair. Re-snapshot the vault immediately before signing — `total_available_balance` ticks every block as time-locked profit unlocks, and stale snapshots can leave the bot 1-2 underlying short. See [`kai-lending.md`](./kai-lending.md) for the Kai-specific PTB recipe (which includes a multi-step strategy walk on the redeem path).

### Shared agent-side notes

- One Scallop vault per underlying `T`; one Kai vault per `(T, YT)` pair (bag keys differ — `type_name<T>` vs `type_name<YT>` — so the same underlying can hold both simultaneously). The sCoin type is structurally pinned to `MarketCoin<T>`, and `Coin<YT>` is type-pinned to Kai's `Vault<T, YT>` (whose `TreasuryCap` is private). Agents cannot supply a fake market coin or YT.
- Agent redeems pay the protocol yield fee (`fee_house.fee_rate × interest_portion`) on **both** Scallop and Kai paths, just like owner / protocol redeems. The same `fee_house.fee_rate` is shared.
- Agents cannot short-change either vault: `scallop_finish_supply` asserts `actual >= ticket.expected_scoin`; `kai_finish_supply` asserts `actual >= ticket.expected_yt`.

## Surfacing Close-Position Warnings

Agents do **not** call `user_close_pm` themselves — only the position owner can close a PositionManager. However, many agent UIs drive the owner's wallet through a "close" action, so the agent layer should surface the following warning whenever it initiates or hints at a close flow:

> `pool::close_position` (used internally by `user_close_pm`) only returns underlying tokens and accumulated trading fees. Any **incentive reward tokens** still held by the position will be destroyed together with the `ClosePositionCert`. The owner's PTB must call `user_collect_reward<CoinTypeA, CoinTypeB, RewardType>` once for each reward token on the pool (typically 1-3 types) **before** `user_close_pm`, in the same transaction.

> Additionally, `user_close_pm` now asserts `bag::is_empty(&pm.lending)` and aborts with `ELendingNotEmpty (1004)` otherwise — the same assertion covers both Scallop `ScallopVault<T>` entries and Kai `KaiVault<T, YT>` entries. Agents can run the full Scallop redeem PTB (`accrue_interest → scallop_start_redeem → redeem::redeem → scallop_finish_redeem`) or the full Kai redeem PTB (`kai_start_redeem → vault::withdraw → strategy walk → redeem_withdraw_ticket → kai_finish_redeem`) to drain entries. cdpm exposes **no** wrapper-extraction escape for lending: if the upstream Scallop/Kai protocol is unreachable (Version bump, paused market, withdrawals disabled), the cdpm hot-potato ticket is never consumed (the abort happens inside the inner upstream move-call), so `pm.lending` stays intact; recovery is to retry the normal redeem flow once Scallop/Kai ships an SDK update against the new Version.

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
