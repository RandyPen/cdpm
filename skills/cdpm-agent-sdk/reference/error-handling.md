# Error Handling

## Contents

- [Common Agent Errors](#common-agent-errors)
- [Recovery Strategies](#recovery-strategies)

## Common Agent Errors

```typescript
// cdpm error codes (sources/cdpm.move). Codes are SHARED across all integrations.
const CDPM_ERROR_CODES = {
  ENotOwner:           1001, // Caller is not pm.owner (e.g. agent tried user_get_position / user_get_and_return_position)
  ENotAllow:           1002, // assert_caller_authorized failed, or pm.agents invariant broken
  EInvalidFeeRate:     1003, // admin_set_fee given rate > MAX_FEE_RATE = 5000 (50%)
  ELendingNotEmpty:    1004, // user_close_pm called with non-empty pm.lending (any Scallop or Kai entry)
  ENoSuchVault:        1005, // scallop_redeem / kai_redeem called for an absent vault entry
  ENoSuchBalance:      1006, // withdraw_from_balance / withdraw_from_fee for an absent type key
  EPositionHasRewards: 1007, // user_close_pm called with unclaimed Cetus pool rewards
  EBalanceNotEmpty:    1008, // user_close_pm called with non-empty pm.balance
  EFeeNotEmpty:        1009, // user_close_pm called with non-empty pm.fee
};

async function handleAgentError(error: any): Promise<string> {
  const errorStr = error.toString();

  if (errorStr.includes('ENotOwner')) {
    return 'Operation requires owner permission. Agents cannot call user_get_position / user_get_and_return_position (the Cetus DLMM Position object is owner-only).';
  } else if (errorStr.includes('ENotAllow')) {
    return 'Agent not in pm.agents. Contact owner for authorization.';
  } else if (errorStr.includes('ELendingNotEmpty')) {
    return 'pm.lending is non-empty. Every ScallopVault<T> AND KaiVault<T, YT> entry must be redeemed (scallop_redeem / kai_redeem) before user_close_pm.';
  } else if (errorStr.includes('ENoSuchVault')) {
    return 'No ScallopVault<T> or KaiVault<T, YT> entry in pm.lending for the requested key. Check pm.lending entries before calling scallop_redeem / kai_redeem.';
  } else if (errorStr.includes('ENoSuchBalance')) {
    return 'withdraw_from_balance / withdraw_from_fee called for an absent type key. Check pm.balance / pm.fee for the type before signing.';
  } else if (errorStr.includes('EPositionHasRewards')) {
    return 'user_close_pm called while the Cetus position still holds unclaimed reward tokens. Owner must call user_collect_reward<CoinTypeA, CoinTypeB, RewardType> for each reward type on the pool before user_close_pm.';
  } else if (errorStr.includes('EBalanceNotEmpty')) {
    return 'user_close_pm called with non-empty pm.balance. Drain via user_remove_liquidity_from_balance<T> for each entry before closing.';
  } else if (errorStr.includes('EFeeNotEmpty')) {
    return 'user_close_pm called with non-empty pm.fee. Drain via user_withdraw_fee<T> for each entry before closing.';
  } else if (errorStr.includes('EInvalidFeeRate')) {
    return 'admin_set_fee given a rate above MAX_FEE_RATE = 5000 (50% cap). Choose a rate <= 5000.';
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
