# Error Handling

## Common Agent Errors

```typescript
// cdpm error codes (sources/cdpm.move, lines 28-36)
const CDPM_ERROR_CODES = {
  ENotOwner:         1001, // Caller is not pm.owner (e.g. agent tried user_extract_scallop_market_coin)
  ENotAllow:         1002, // assert_caller_authorized failed (or invariant broken)
  EInvalidFeeRate:   1003, // admin_set_fee given rate > MAX_FEE_RATE (30%)
  ELendingNotEmpty:  1004, // user_close_pm called with non-empty pm.lending
  ENoSuchVault:      1005, // scallop_start_redeem / extract called for an absent (T) vault
  EReserveEmpty:     1006, // Scallop reserve has zero supply or zero (cash+debt-revenue)
  EZeroExpected:     1007, // scallop_start_supply / scallop_start_redeem would yield 0
  EWrongPm:          1008, // Hot-potato ticket consumed against a different PM
  EAmountShortfall:  1009, // finish_* received Coin with value < ticket.expected
};

async function handleAgentError(error: any): Promise<string> {
  const errorStr = error.toString();

  if (errorStr.includes('ENotOwner')) {
    return 'Operation requires owner permission. Agents cannot call user_extract_scallop_market_coin.';
  } else if (errorStr.includes('ENotAllow')) {
    return 'Agent not in pm.agents. Contact owner for authorization.';
  } else if (errorStr.includes('ELendingNotEmpty')) {
    return 'pm.lending is non-empty; the owner must redeem or extract every ScallopVault before user_close_pm.';
  } else if (errorStr.includes('ENoSuchVault')) {
    return 'No ScallopVault for that underlying type T. Check pm.lending entries before calling scallop_start_redeem.';
  } else if (errorStr.includes('EReserveEmpty')) {
    return 'Scallop reserve has zero supply or zero (cash+debt-revenue). Did you call accrue_interest_for_market first?';
  } else if (errorStr.includes('EZeroExpected')) {
    return 'Supply/redeem amount too small — predicted output is 0. Increase the amount.';
  } else if (errorStr.includes('EWrongPm')) {
    return 'ScallopSupplyTicket/ScallopRedeemTicket consumed against a different PositionManager.';
  } else if (errorStr.includes('EAmountShortfall')) {
    return 'finish_* received Coin with value < ticket.expected. Run accrue_interest_for_market as the first PTB command.';
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
