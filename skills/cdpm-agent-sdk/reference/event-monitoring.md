# Event Monitoring

## Contents

- [Agent Events](#agent-events)
- [Event Subscription](#event-subscription)

## Agent Events

cdpm event payloads carry no `by` field for any event. To distinguish owner / agent / protocol callers, use the Sui event envelope's `event.sender` (the transaction signer).

```typescript
// Emitted by agent_add_liquidity
interface AgentLiquidityAdded {
  pm_id: string;
  pool_id: string;
  bins: number[];
  amount_a: string;  // Actual amount A consumed
  amount_b: string;  // Actual amount B consumed
}

// Emitted by agent_remove_liquidity
interface AgentLiquidityRemoved {
  pm_id: string;
  pool_id: string;
  bins: number[];
  liquidity_shares: string[];
  amount_a: string;   // Actual token A returned
  amount_b: string;   // Actual token B returned
}

// Emitted by agent_collect_fee
interface AgentFeeCollected {
  pm_id: string;
  pool_id: string;
  coin_type_a: string;
  coin_type_b: string;
  amount_a: string;
  amount_b: string;
}

// Emitted by agent_collect_reward
interface AgentRewardCollected {
  pm_id: string;
  pool_id: string;
  coin_type: string;
  amount: string;
}

// Emitted by agent_transfer_fee_to_balance (also emitted by protocol_transfer_fee_to_balance — same struct)
interface FeeTransferredToBalance {
  pm_id: string;
  coin_type: string;
  amount: string;
}

// Emitted by agent_create_position — agent opened a fresh Cetus position from pm.balance
interface AgentPositionCreated {
  pm_id: string;
  pool_id: string;
  lower_bin_id: { bits: number };
  upper_bin_id: { bits: number };
  liquidity_shares: string[];
}

// Emitted by agent_destroy_position — agent closed the Cetus position, assets back to pm.balance
interface AgentPositionDestroyed {
  pm_id: string;
  pool_id: string;
  coin_type_a: string;
  coin_type_b: string;
  amount_a: string;  // Underlying A returned to pm.balance
  amount_b: string;  // Underlying B returned to pm.balance
}

// Emitted by scallop_supply, regardless of caller.
interface ScallopSupplied {
  pm_id: string;
  coin_type: string;            // type_name<T> — sCoin type is always MarketCoin<T>
  deposit_amount: string;       // underlying transferred to Scallop
  market_coin_minted: string;   // sCoin received and added to pm.lending
}

// Emitted by scallop_redeem, regardless of caller.
interface ScallopRedeemed {
  pm_id: string;
  coin_type: string;
  market_coin_redeemed: string; // sCoin burned
  redeemed_amount: string;      // underlying received pre-fee
  principal_portion: string;    // principal slice this redeem consumed
  interest: string;             // redeemed_amount − principal_portion (≥ 0)
  fee_amount: string;           // protocol yield fee deducted from interest
}

// Emitted by kai_supply, regardless of caller.
interface KaiSupplied {
  pm_id: string;
  coin_type: string;            // type_name<T>
  yt_type: string;              // type_name<YT>
  deposit_amount: string;
  yt_minted: string;
}

// Emitted by kai_redeem, regardless of caller.
interface KaiRedeemed {
  pm_id: string;
  coin_type: string;
  yt_type: string;
  yt_burned: string;
  redeemed_amount: string;      // underlying received pre-fee
  principal_portion: string;
  interest: string;
  fee_amount: string;           // protocol yield fee — same fee_house.fee_rate as Scallop
}
```

## Event Subscription

```typescript
class AgentEventMonitor {
  private unsubscribe?: () => void;

  constructor(private client: SuiGrpcClient) {}

  start(agentAddress: string, onEvent: (event: any) => void): void {
    this.unsubscribe = this.client.subscribeEvent({
      filter: {
        MoveEventModule: {
          package: CDPM_PACKAGE,
          module: 'cdpm',
        },
      },
      onMessage: (event) => {
        // cdpm event payloads carry no `by` field. Filter on the envelope's
        // `event.sender` (the transaction signer) to identify the actor.
        if (event.sender === agentAddress) {
          onEvent(event);
        }
      },
    });
  }

  stop(): void {
    this.unsubscribe?.();
  }
}

// Usage
const monitor = new AgentEventMonitor(client);
monitor.start(agentAddress, (event) => {
  console.log(`Agent event: ${event.type}`, event.parsedJson);
});
```
