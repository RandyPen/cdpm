# Error Handling

## Common Agent Errors

```typescript
const AGENT_ERROR_CODES = {
  ENotAllow: 1002,  // Not authorized agent
};

async function handleAgentError(error: any): Promise<string> {
  const errorStr = error.toString();
  
  if (errorStr.includes('ENotAllow')) {
    return 'Agent not authorized. Contact owner for authorization.';
  } else if (errorStr.includes('EZeroBalance')) {
    return 'Insufficient balance for operation.';
  } else if (errorStr.includes('ENoPosition')) {
    return 'No position exists. Cannot perform operation.';
  } else if (errorStr.includes('EBinRange')) {
    return 'Invalid bin range specified.';
  }
  
  return `Unknown error: ${errorStr}`;
}
```

## Recovery Strategies

```typescript
class AgentRecovery {
  constructor(
    private client: SuiGrpcClient,
    private signer: any
  ) {}

  async recoverFromFailure(
    operation: string,
    params: any,
    maxRetries: number = 3
  ): Promise<any> {
    for (let attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        return await this.executeOperation(operation, params);
      } catch (error) {
        console.error(`Attempt ${attempt} failed:`, error);
        
        if (attempt === maxRetries) {
          throw error;
        }
        
        // Wait before retry
        await this.delay(1000 * attempt);
      }
    }
  }

  private async executeOperation(
    operation: string, 
    params: any
  ): Promise<any> {
    switch (operation) {
      case 'addLiquidity':
        return agentAddLiquidity(this.client, this.signer, ...params);
      case 'removeLiquidity':
        return agentRemoveLiquidity(this.client, this.signer, ...params);
      case 'collectFees':
        return agentCollectFees(this.client, this.signer, ...params);
      default:
        throw new Error(`Unknown operation: ${operation}`);
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}
```
