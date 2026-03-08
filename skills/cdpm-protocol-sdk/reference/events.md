# Events

## Admin Events

```typescript
// Fee rate updated
interface FeeRateUpdated {
  fee_house_id: string;
  old_fee_rate: number;
  new_fee_rate: number;
  timestamp: number;
}

// Access granted
interface AccessGranted {
  access_list_id: string;
  address: string;
  timestamp: number;
}

// Access revoked
interface AccessRevoked {
  access_list_id: string;
  address: string;
  timestamp: number;
}

// Admin transferred
interface AdminTransferred {
  from: string;
  to: string;
  timestamp: number;
}

// Protocol fees collected
interface AdminFeeCollected {
  fee_house_id: string;
  coin_type: string;
  amount: string;
  admin: string;
  timestamp: number;
}
```

## Protocol Operation Events

```typescript
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
  timestamp: number;
}

// Protocol collected rewards (with fee split)
interface ProtocolRewardCollected {
  pm_id: string;
  pool_id: string;
  coin_type: string;
  amount: string;        // User portion
  fee_amount: string;    // Protocol portion
  timestamp: number;
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
