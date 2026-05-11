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

## Scallop Lending Pre-Flight

When chaining a supply or redeem, the **first** PTB command must be `protocol::accrue_interest::accrue_interest_for_market(version, market, clock)`. cdpm only reads Scallop's `balance_sheet` view-only (`compute_expected_scoin` / `compute_expected_underlying_scallop`), so a stale accrual will make the predicted scoin/underlying exceed what Scallop actually mints/redeems and `scallop_finish_supply` / `scallop_finish_redeem` will abort with `EAmountShortfall (1009)`.

Recommended PTB shape for an agent:

```
1. accrue_interest_for_market
2. cdpm::scallop_start_supply  | cdpm::scallop_start_redeem
3. protocol::mint::mint | protocol::redeem::redeem
4. cdpm::scallop_finish_supply | cdpm::scallop_finish_redeem
```

Other agent-side notes:

- One vault per underlying `T`. The sCoin type is structurally pinned to `MarketCoin<T>` by the type system, so agents cannot supply a fake or alternate sCoin — there is no `S` generic to mismatch.
- Agent redeems still pay the protocol yield fee (`fee_house.fee_rate × interest_portion`) just like owner / protocol redeems.
- Agents cannot short-change the vault: `scallop_finish_supply` only accepts `Coin<MarketCoin<T>>` (the only way to obtain a non-zero `Coin<MarketCoin<T>>` is through Scallop's `mint`, since `MarketCoin` has only `drop` and no public constructor) and asserts `actual >= ticket.expected_scoin`.

## Surfacing Close-Position Warnings

Agents do **not** call `user_close_pm` themselves — only the position owner can close a PositionManager. However, many agent UIs drive the owner's wallet through a "close" action, so the agent layer should surface the following warning whenever it initiates or hints at a close flow:

> `pool::close_position` (used internally by `user_close_pm`) only returns underlying tokens and accumulated trading fees. Any **incentive reward tokens** still held by the position will be destroyed together with the `ClosePositionCert`. The owner's PTB must call `user_collect_reward<CoinTypeA, CoinTypeB, RewardType>` once for each reward token on the pool (typically 1-3 types) **before** `user_close_pm`, in the same transaction.

> Additionally, `user_close_pm` now asserts `bag::is_empty(&pm.lending)` and aborts with `ELendingNotEmpty (1004)` otherwise. Drain every `ScallopVault<T>` first — agents can run the full `accrue_interest → scallop_start_redeem → redeem::redeem → scallop_finish_redeem` PTB, but the **owner-only** `user_extract_scallop_market_coin` is the rescue path when Scallop is unreachable.

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
