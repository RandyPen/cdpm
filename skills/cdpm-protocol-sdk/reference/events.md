# Events

## Contents

- [Admin Events](#admin-events)
- [Protocol Operation Events](#protocol-operation-events)
- [Scallop Lending Events](#scallop-lending-events)
- [Kai SAV Lending Events](#kai-sav-lending-events)
- [Event Subscription](#event-subscription)

> Every state-changing function in `cdpm` emits exactly one event. Sender attribution is read from the Sui event envelope (`event.sender`); no event struct carries a `by` field.

## Admin Events

```typescript
// Fee rate updated by admin_set_fee
interface FeeRateUpdated {
  fee_house_id: string;
  old_fee_rate: number;
  new_fee_rate: number;
}

// Access granted by admin_insert_access_list
interface AccessGranted {
  access_list_id: string;
  address: string;
}

// Access revoked by admin_remove_access_list
interface AccessRevoked {
  access_list_id: string;
  address: string;
}

// AdminCap transferred by admin_transfer
interface AdminTransferred {
  from: string;
  to: string;
}

// Emitted by both admin_collect_fee and admin_collect_fee_return_coin
interface AdminFeeCollected {
  fee_house_id: string;
  coin_type: string;
  amount: string;
  admin: string;
}
```

## Protocol Operation Events

```typescript
// Emitted by protocol_add_liquidity
interface ProtocolLiquidityAdded {
  pm_id: string;
  pool_id: string;
  bins: number[];
  amount_a: string;      // Actual amount A consumed
  amount_b: string;      // Actual amount B consumed
}

// Emitted by protocol_remove_liquidity
interface ProtocolLiquidityRemoved {
  pm_id: string;
  pool_id: string;
  bins: number[];
  liquidity_shares: string[];
  amount_a: string;   // Actual token A returned to pm.balance
  amount_b: string;   // Actual token B returned to pm.balance
}

// Emitted by protocol_collect_fee (with fee split)
interface ProtocolFeeCollected {
  pm_id: string;
  pool_id: string;
  coin_type_a: string;
  coin_type_b: string;
  amount_a: string;      // Routed to pm.fee
  amount_b: string;      // Routed to pm.fee
  fee_a: string;         // Routed to fee_house.fee
  fee_b: string;         // Routed to fee_house.fee
}

// Emitted by protocol_collect_reward (with fee split)
interface ProtocolRewardCollected {
  pm_id: string;
  pool_id: string;
  coin_type: string;     // type_name<RewardType>
  amount: string;        // Routed to pm.fee
  fee_amount: string;    // Routed to fee_house.fee
}

// Emitted by protocol_transfer_fee_to_balance and agent_transfer_fee_to_balance
interface FeeTransferredToBalance {
  pm_id: string;
  coin_type: string;
  amount: string;        // Actual coin value moved (clamped to available)
}
```

## Agent Position Lifecycle Events

Emitted by the agent-controlled position lifecycle functions
(`agent_create_position` / `agent_destroy_position`). No `by` field — use
`event.sender` from the envelope to attribute the actor.

```typescript
// Emitted by agent_create_position
interface AgentPositionCreated {
  pm_id: string;
  pool_id: string;
  lower_bin_id: { bits: number };
  upper_bin_id: { bits: number };
  liquidity_shares: string[];
}

// Emitted by agent_destroy_position
interface AgentPositionDestroyed {
  pm_id: string;
  pool_id: string;
  coin_type_a: string;  // type_name<CoinTypeA>
  coin_type_b: string;  // type_name<CoinTypeB>
  amount_a: string;     // Underlying A returned to pm.balance
  amount_b: string;     // Underlying B returned to pm.balance
}
```

## Scallop Lending Events

These events fire from `scallop_supply<T>` and `scallop_redeem<T>` regardless of which caller initiated the PTB (owner / agent / protocol). They omit a `by` field — use the Sui event envelope's `event.sender` to attribute the action.

```typescript
// Emitted by scallop_supply
interface ScallopSupplied {
  pm_id: string;
  coin_type: string;            // type_name<T> — the underlying type
  deposit_amount: string;       // underlying transferred to Scallop
  market_coin_minted: string;   // sCoin received and added to pm.lending
}

// Emitted by scallop_redeem
interface ScallopRedeemed {
  pm_id: string;
  coin_type: string;
  market_coin_redeemed: string; // sCoin burned
  redeemed_amount: string;      // underlying received from Scallop, pre-fee
  principal_portion: string;    // principal slice this redeem consumed
  interest: string;             // max(0, redeemed_amount − principal_portion)
  fee_amount: string;           // protocol yield fee deducted from interest
}
```

## Kai SAV Lending Events

Same shape as the Scallop events, with the additional `yt_type` field carrying the YT generic for human-readable reporting (the bag key is `type_name<YT>`, but `coin_type` is still required to disambiguate from a hypothetical second YT over the same underlying). No `by` field — use `event.sender` from the envelope.

```typescript
// Emitted by kai_supply
interface KaiSupplied {
  pm_id: string;
  coin_type: string;            // type_name<T>
  yt_type: string;              // type_name<YT>
  deposit_amount: string;       // underlying transferred to Kai's Vault<T, YT>
  yt_minted: string;            // YT received and added to pm.lending
}

// Emitted by kai_redeem
interface KaiRedeemed {
  pm_id: string;
  coin_type: string;
  yt_type: string;
  yt_burned: string;
  redeemed_amount: string;      // underlying received from Kai, pre-fee
  principal_portion: string;
  interest: string;
  fee_amount: string;           // shares fee_house.fee_rate with the Scallop path
}
```

## Event Subscription

```typescript
// Subscribe to cdpm module events
const unsubscribe = await client.subscribeEvent({
  filter: {
    MoveEventModule: {
      package: CDPM_PACKAGE,
      module: 'cdpm',
    },
  },
  onMessage: (event) => {
    switch (event.type) {
      case `${CDPM_PACKAGE}::cdpm::FeeRateUpdated`:
        console.log('Fee rate updated:', event.parsedJson);
        break;
      case `${CDPM_PACKAGE}::cdpm::AccessGranted`:
        console.log('Access granted:', event.parsedJson);
        break;
      case `${CDPM_PACKAGE}::cdpm::ProtocolFeeCollected`:
        console.log('Protocol fees collected:', event.parsedJson);
        break;
      case `${CDPM_PACKAGE}::cdpm::ProtocolRewardCollected`:
        console.log('Protocol reward collected:', event.parsedJson);
        break;
      case `${CDPM_PACKAGE}::cdpm::ScallopSupplied`:
      case `${CDPM_PACKAGE}::cdpm::ScallopRedeemed`:
      case `${CDPM_PACKAGE}::cdpm::KaiSupplied`:
      case `${CDPM_PACKAGE}::cdpm::KaiRedeemed`:
        console.log('Lending event:', event.type, event.parsedJson);
        break;
      case `${CDPM_PACKAGE}::cdpm::AgentPositionCreated`:
      case `${CDPM_PACKAGE}::cdpm::AgentPositionDestroyed`:
        console.log('Agent position lifecycle event:', event.type, event.parsedJson);
        break;
    }
  },
});
```
