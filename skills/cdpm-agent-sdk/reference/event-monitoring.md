# Event Monitoring

## Agent Events

```typescript
// Agent added liquidity
interface AgentLiquidityAdded {
  pm_id: string;
  pool_id: string;
  bins: number[];
  amounts_a: string[];
  amounts_b: string[];
  by: string;        // Agent address
  timestamp: number;
}

// Agent removed liquidity
interface AgentLiquidityRemoved {
  pm_id: string;
  pool_id: string;
  bins: number[];
  liquidity_shares: string[];
  by: string;
  timestamp: number;
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
  timestamp: number;
}

// Agent collected rewards
interface AgentRewardCollected {
  pm_id: string;
  pool_id: string;
  coin_type: string;
  amount: string;
  by: string;
  timestamp: number;
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
        // Filter events by agent address
        if (event.parsedJson?.by === agentAddress) {
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
