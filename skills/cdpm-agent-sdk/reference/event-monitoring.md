# Event Monitoring

## Contents

- [Agent Events](#agent-events)
- [Event Subscription](#event-subscription)

## Agent Events

```typescript
// Agent added liquidity (scalar actual amounts consumed by the pool)
interface AgentLiquidityAdded {
  pm_id: string;
  pool_id: string;
  bins: number[];
  amount_a: string;  // Actual amount A consumed
  amount_b: string;  // Actual amount B consumed
  by: string;        // Agent address
}

// Agent removed liquidity
interface AgentLiquidityRemoved {
  pm_id: string;
  pool_id: string;
  bins: number[];
  liquidity_shares: string[];
  amount_a: string;   // Actual token A returned
  amount_b: string;   // Actual token B returned
  by: string;
}

// Agent collected fees
interface AgentFeeCollected {
  pm_id: string;
  pool_id: string;
  coin_type_a: string;
  coin_type_b: string;
  amount_a: string;
  amount_b: string;
  by: string;
}

// Agent collected rewards
interface AgentRewardCollected {
  pm_id: string;
  pool_id: string;
  coin_type: string;
  amount: string;
  by: string;
}

// Scallop supply (emitted by scallop_finish_supply, regardless of caller).
// Note: there is NO `by` field — use `event.sender` from the event envelope
// to distinguish owner / agent / protocol callers.
interface ScallopSupplied {
  pm_id: string;
  coin_type: string;            // type_name<T> — sCoin type is always MarketCoin<T>
  deposit_amount: string;       // underlying transferred to Scallop
  market_coin_minted: string;   // sCoin received and added to pm.lending
}

// Scallop redeem (emitted by scallop_finish_redeem, regardless of caller).
interface ScallopRedeemed {
  pm_id: string;
  coin_type: string;
  market_coin_redeemed: string; // sCoin burned
  redeemed_amount: string;      // underlying received pre-fee
  principal_portion: string;    // principal slice this redeem consumed
  interest: string;             // redeemed_amount − principal_portion (≥ 0)
  fee_amount: string;           // protocol yield fee deducted from interest
}

// Kai supply / redeem — same shape, with extra `yt_type` for the YT generic.
// Emitted by kai_finish_supply / kai_finish_redeem regardless of caller.
interface KaiSupplied {
  pm_id: string;
  coin_type: string;            // type_name<T>
  yt_type: string;              // type_name<YT>
  deposit_amount: string;
  yt_minted: string;
}

interface KaiRedeemed {
  pm_id: string;
  coin_type: string;
  yt_type: string;
  yt_burned: string;
  redeemed_amount: string;      // underlying received pre-fee (after the strategy walk)
  principal_portion: string;
  interest: string;
  fee_amount: string;           // protocol yield fee — same fee_house.fee_rate as Scallop
}
```

> Sui event envelopes carry `event.sender`; the cdpm payload no longer includes a `by` field for either the Scallop or the Kai events to keep payload size constant across callers.

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
        // Filter events by agent address.
        // Cetus liquidity / fee / reward events carry `by`; Scallop and Kai
        // lending events do NOT (the cdpm payload omits it). Fall back to the
        // envelope's `event.sender` for those.
        const actor = event.parsedJson?.by ?? event.sender;
        if (actor === agentAddress) {
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
