# Error Handling

## Contents

- [Common Agent Errors](#common-agent-errors)
- [Recovery Strategies](#recovery-strategies)

## Common Agent Errors

```typescript
// cdpm error codes (sources/cdpm.move) — codes are SHARED between Scallop and Kai integrations.
const CDPM_ERROR_CODES = {
  ENotOwner:           1001, // Caller is not pm.owner (e.g. agent tried user_get_position / user_get_and_return_position)
  ENotAllow:           1002, // assert_caller_authorized failed (or invariant broken)
  EInvalidFeeRate:     1003, // admin_set_fee given rate > MAX_FEE_RATE (30%)
  ELendingNotEmpty:    1004, // user_close_pm called with non-empty pm.lending (any Scallop or Kai entry)
  ENoSuchVault:        1005, // scallop_start_redeem / kai_start_redeem called for an absent vault entry
  EReserveEmpty:       1006, // Scallop reserve degenerate OR Kai vault total_yt_supply == 0
  EZeroExpected:       1007, // scallop_start_* / kai_start_* would yield 0 — amount too small
  EWrongPm:            1008, // Hot-potato ticket consumed against a different PM (Scallop or Kai)
  EAmountShortfall:    1009, // finish_* received Coin with value < ticket.expected
  ENoSuchBalance:      1010, // withdraw_from_balance / withdraw_from_fee for an absent type key
  EStaleScallopState:  1011, // scallop_start_* called before accrue_interest_for_market in the same PTB second
  EWrongMarket:        1012, // scallop_finish_* received a Market with id != ticket.market_id
  EWrongVault:         1013, // kai_finish_* received a Vault with id != ticket.vault_id
};

async function handleAgentError(error: any): Promise<string> {
  const errorStr = error.toString();

  if (errorStr.includes('ENotOwner')) {
    return 'Operation requires owner permission. Agents cannot call user_get_position / user_get_and_return_position (the only owner-only escape hatch — the Cetus DLMM Position object). cdpm exposes no wrapper-extract escape for Scallop/Kai lending.';
  } else if (errorStr.includes('ENotAllow')) {
    return 'Agent not in pm.agents. Contact owner for authorization.';
  } else if (errorStr.includes('ELendingNotEmpty')) {
    return 'pm.lending is non-empty; every ScallopVault<T> AND KaiVault<T, YT> entry must be redeemed (full scallop_*/kai_* start→finish flow) before user_close_pm. There is no wrapper-extract bypass.';
  } else if (errorStr.includes('ENoSuchVault')) {
    return 'No ScallopVault<T> or KaiVault<T, YT> entry in pm.lending for the requested key. Check pm.lending entries before calling scallop_start_redeem / kai_start_redeem.';
  } else if (errorStr.includes('EReserveEmpty')) {
    return 'Lending reserve degenerate. Scallop: zero supply or zero (cash+debt-revenue) — call accrue_interest_for_market first. Kai: total_yt_supply == 0 — supply first.';
  } else if (errorStr.includes('EZeroExpected')) {
    return 'Supply/redeem amount too small — predicted output is 0. Increase the amount.';
  } else if (errorStr.includes('EWrongPm')) {
    return 'Hot-potato ticket (ScallopSupplyTicket / ScallopRedeemTicket / KaiSupplyTicket / KaiRedeemTicket) consumed against a different PositionManager.';
  } else if (errorStr.includes('EAmountShortfall')) {
    return 'finish_* received Coin with value < ticket.expected. Kai: agent passed ytAmount = MAX_U64 (full drain) — per-strategy floor-div dust trips the assert. Cap the burn at wrapperRaw − LENDING_SAFE_MARGIN_WRAPPER_RAW (recommended client-side default 100 wrapper raw) and leave the residual for the owner close-PM flow. Scallop: usually a missing accrue_interest_for_market as PTB command 0, or reserve state moved between snapshot and signing — re-snapshot after accrue. Apply the same cap to Scallop defensively for parity. See cdpm-calculation-skill/reference/{kai,scallop}-lending-math.md §9.1 and cdpm-agent-sdk/reference/{kai,scallop}-lending.md for the partial-burn recipe.';
  } else if (errorStr.includes('ENoSuchBalance')) {
    return 'withdraw_from_balance / withdraw_from_fee called for an absent type key. Check pm.balance / pm.fee for the type before signing.';
  } else if (errorStr.includes('EStaleScallopState')) {
    return 'scallop_start_* called without accrue_interest::accrue_interest_for_market in the same PTB. Make it command 0 of the batch — cdpm enforces this.';
  } else if (errorStr.includes('EWrongMarket')) {
    return 'scallop_finish_* received a Market whose id != ticket.market_id. Reuse the same tx.object(SCALLOP_MARKET_ID) handle across start_* and finish_*.';
  } else if (errorStr.includes('EWrongVault')) {
    return 'kai_finish_* received a Vault whose id != ticket.vault_id. Reuse the same tx.object(vaultObjectId) handle across start_* and finish_*.';
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
