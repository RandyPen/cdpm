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

## Surfacing Close-Position Warnings

Agents do **not** call `user_close_pm` themselves — only the position owner can close a PositionManager. However, many agent UIs drive the owner's wallet through a "close" action, so the agent layer should surface the following warning whenever it initiates or hints at a close flow:

> `pool::close_position` (used internally by `user_close_pm`) only returns underlying tokens and accumulated trading fees. Any **incentive reward tokens** still held by the position will be destroyed together with the `ClosePositionCert`. The owner's PTB must call `user_collect_reward<CoinTypeA, CoinTypeB, RewardType>` once for each reward token on the pool (typically 1–3 types) **before** `user_close_pm`, in the same transaction.

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
