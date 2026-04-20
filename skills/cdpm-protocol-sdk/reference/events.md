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
