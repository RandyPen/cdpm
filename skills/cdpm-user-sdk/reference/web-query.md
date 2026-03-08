# Web Query Guide

For web applications, use GraphQL to query all PositionManagers owned by a user through their Record.

## Setup GraphQL Client

```typescript
import { SuiGraphQLClient } from '@mysten/sui/graphql';

const graphqlClient = new SuiGraphQLClient({
  url: 'https://sui-mainnet.mystenlabs.com/graphql',
  network: 'mainnet',
});
```

## Query PositionManagers by Record

```typescript
async function queryPositionManagersByRecord(
  recordId: string
): Promise<PositionManagerInfo[]> {
  const query = `
    query GetPositionManagers($recordId: SuiAddress!) {
      object(address: $recordId) {
        asMoveObject {
          contents {
            json
          }
        }
      }
    }
  `;

  const result = await graphqlClient.query({
    query,
    variables: { recordId },
  });

  const recordData = result.object?.asMoveObject?.contents?.json;
  if (!recordData || !recordData.record) {
    return [];
  }

  // Extract PositionManager IDs from Record's internal table
  const pmIds = Object.keys(recordData.record);
  
  // Fetch detailed info for each PositionManager
  const pmDetails = await Promise.all(
    pmIds.map(id => getPositionManagerDetails(graphqlClient, id))
  );

  return pmDetails.filter(pm => pm !== null) as PositionManagerInfo[];
}

interface PositionManagerInfo {
  id: string;
  owner: string;
  position?: {
    id: string;
    poolId: string;
  };
  agents: string[];
  balance: Record<string, string>;
  fee: Record<string, string>;
}
```

## Get Single PositionManager Details

```typescript
async function getPositionManagerDetails(
  client: SuiGraphQLClient,
  pmId: string
): Promise<PositionManagerInfo | null> {
  const query = `
    query GetPositionManager($pmId: SuiAddress!) {
      object(address: $pmId) {
        address
        asMoveObject {
          contents {
            json
          }
        }
      }
    }
  `;

  const result = await client.query({
    query,
    variables: { pmId },
  });

  const pmData = result.object?.asMoveObject?.contents?.json;
  if (!pmData) return null;

  return {
    id: pmId,
    owner: pmData.owner,
    position: pmData.position ? {
      id: pmData.position.id,
      poolId: pmData.position.pool_id,
    } : undefined,
    agents: pmData.agents || [],
    balance: pmData.balance || {},
    fee: pmData.fee || {},
  };
}
```

## Complete Web Query Flow

```typescript
async function getUserPositionManagers(
  userAddress: string
): Promise<{ recordId?: string; positionManagers: PositionManagerInfo[] }> {
  // Step 1: Check if user has a Record using gRPC
  const grpcClient = new SuiGrpcClient({
    baseUrl: 'https://fullnode.mainnet.sui.io:443',
    network: 'mainnet',
  });

  const recordId = await getUserRecordId(grpcClient, userAddress);
  
  if (!recordId) {
    return { positionManagers: [] };
  }

  // Step 2: Query PositionManagers using GraphQL
  const positionManagers = await queryPositionManagersByRecord(recordId);

  return {
    recordId,
    positionManagers,
  };
}

// Usage in React component
function PositionManagerList({ userAddress }: { userAddress: string }) {
  const [pms, setPms] = useState<PositionManagerInfo[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    getUserPositionManagers(userAddress)
      .then(data => setPms(data.positionManagers))
      .finally(() => setLoading(false));
  }, [userAddress]);

  if (loading) return <div>Loading...</div>;
  
  if (pms.length === 0) {
    return <div>No positions found. Create your first position!</div>;
  }

  return (
    <div>
      {pms.map(pm => (
        <PositionManagerCard key={pm.id} data={pm} />
      ))}
    </div>
  );
}
```

## Query with Additional Pool Info

```typescript
async function queryPositionManagersWithPool(
  recordId: string
): Promise<(PositionManagerInfo & { poolInfo?: PoolInfo })[]> {
  const pms = await queryPositionManagersByRecord(recordId);
  
  // Fetch pool details for each PositionManager
  const withPoolInfo = await Promise.all(
    pms.map(async pm => {
      if (!pm.position?.poolId) return pm;
      
      const poolQuery = `
        query GetPool($poolId: SuiAddress!) {
          object(address: $poolId) {
            asMoveObject {
              contents {
                json
              }
            }
          }
        }
      `;
      
      const poolResult = await graphqlClient.query({
        query: poolQuery,
        variables: { poolId: pm.position.poolId },
      });
      
      const poolData = poolResult.object?.asMoveObject?.contents?.json;
      
      return {
        ...pm,
        poolInfo: poolData ? {
          tokenA: poolData.token_x_type,
          tokenB: poolData.token_y_type,
          activeBin: poolData.active_index,
        } : undefined,
      };
    })
  );
  
  return withPoolInfo;
}
```
