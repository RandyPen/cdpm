# Events

> Event timestamps are available on the `SuiEvent.timestampMs` envelope at query time — the on-chain payload no longer duplicates a `timestamp` field.

## Admin Events

```typescript
// Fee rate updated
interface FeeRateUpdated {
  fee_house_id: string;
  old_fee_rate: number;
  new_fee_rate: number;
}

// Access granted
interface AccessGranted {
  access_list_id: string;
  address: string;
}

// Access revoked
interface AccessRevoked {
  access_list_id: string;
  address: string;
}

// Admin transferred
interface AdminTransferred {
  from: string;
  to: string;
}

// Protocol fees collected
interface AdminFeeCollected {
  fee_house_id: string;
  coin_type: string;
  amount: string;
  admin: string;
}
```

## Protocol Operation Events

```typescript
// Protocol added liquidity (scalar actual amounts consumed by the pool)
interface ProtocolLiquidityAdded {
  pm_id: string;
  pool_id: string;
  bins: number[];
  amount_a: string;      // Actual amount A consumed
  amount_b: string;      // Actual amount B consumed
  by: string;
}

// Protocol removed liquidity
interface ProtocolLiquidityRemoved {
  pm_id: string;
  pool_id: string;
  bins: number[];
  liquidity_shares: string[];
  amount_a: string;   // Actual token A returned
  amount_b: string;   // Actual token B returned
  by: string;
}

// Protocol collected fees (with fee split)
interface ProtocolFeeCollected {
  pm_id: string;
  pool_id: string;
  coin_type_a: string;
  coin_type_b: string;
  amount_a: string;      // User portion
  amount_b: string;      // User portion
  fee_a: string;         // Protocol portion
  fee_b: string;         // Protocol portion
}

// Protocol collected rewards (with fee split)
interface ProtocolRewardCollected {
  pm_id: string;
  pool_id: string;
  coin_type: string;
  amount: string;        // User portion
  fee_amount: string;    // Protocol portion
}
```

## Scallop Lending Events

These three events fire from the shared Scallop hot-potato API regardless of which caller initiated the PTB (owner / agent / protocol). They intentionally omit a `by` field — use the Sui event envelope's `event.sender` to attribute the action.

```typescript
// Emitted by scallop_finish_supply
interface ScallopSupplied {
  pm_id: string;
  coin_type: string;            // type_name<T> — sCoin type is always MarketCoin<T>
  deposit_amount: string;       // underlying transferred to Scallop
  market_coin_minted: string;   // sCoin received and added to pm.lending
}

// Emitted by scallop_finish_redeem
interface ScallopRedeemed {
  pm_id: string;
  coin_type: string;
  market_coin_redeemed: string; // sCoin burned
  redeemed_amount: string;      // underlying received from Scallop, pre-fee
  principal_portion: string;    // principal slice this redeem consumed
  interest: string;             // redeemed_amount − principal_portion (≥ 0)
  fee_amount: string;           // protocol yield fee deducted from interest
}
```

cdpm emits no extraction event for Scallop lending — there is no wrapper-extract function. The only exit-related event on the Scallop side is `ScallopRedeemed`, emitted once the underlying lands in `pm.balance` via the full `scallop_start_redeem` → `redeem::redeem` → `scallop_finish_redeem` flow.

## Kai SAV Lending Events

Same shape as the Scallop events, with the additional `yt_type` field carrying the YT generic for human-readable reporting (the bag key is `type_name<YT>`, but `coin_type` is still required to disambiguate from a hypothetical second YT over the same underlying). No `by` field — use `event.sender` from the envelope.

```typescript
// Emitted by kai_finish_supply
interface KaiSupplied {
  pm_id: string;
  coin_type: string;            // type_name<T>
  yt_type: string;              // type_name<YT>
  deposit_amount: string;       // underlying transferred to Kai's Vault<T, YT>
  yt_minted: string;            // YT received and added to pm.lending
}

// Emitted by kai_finish_redeem
interface KaiRedeemed {
  pm_id: string;
  coin_type: string;
  yt_type: string;
  yt_burned: string;
  redeemed_amount: string;      // underlying received from Kai's vault::redeem_withdraw_ticket, pre-fee
  principal_portion: string;
  interest: string;
  fee_amount: string;           // protocol yield fee — shares fee_house.fee_rate with Scallop
}
```

cdpm emits no extraction event for Kai lending either — same rule as Scallop. The only exit-related event on the Kai side is `KaiRedeemed`, emitted once the underlying lands in `pm.balance` via the full `kai_start_redeem` → `vault::withdraw` → strategy walk → `redeem_withdraw_ticket` → `kai_finish_redeem` flow.

## Event Subscription

```typescript
// Subscribe to admin events
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
    }
  },
});
```
