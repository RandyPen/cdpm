# Agent Management

## Authorize Agent

```typescript
async function authorizeAgent(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  agentAddress: string
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_insert_agent`,
    arguments: [
      tx.object(pmId),
      tx.pure.address(agentAddress),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## Revoke Agent

```typescript
async function revokeAgent(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  agentAddress: string
) {
  const tx = new Transaction();
  
  tx.moveCall({
    target: `${CDPM_PACKAGE}::cdpm::user_remove_agent`,
    arguments: [
      tx.object(pmId),
      tx.pure.address(agentAddress),
    ],
  });
  
  return await client.signAndExecuteTransaction({ signer, transaction: tx });
}
```

## List Authorized Agents

```typescript
async function getAuthorizedAgents(
  client: SuiGrpcClient,
  pmId: string
): Promise<string[]> {
  const { response: pm } = await client.getObject({
    id: pmId,
    include: { content: true },
  });
  
  const agents = pm?.content?.fields?.agents;
  return agents || [];
}
```

## Security Best Practices

### Pre-Authorization Checklist

Before authorizing an agent:

1. **Verify ownership** - Confirm you own the PositionManager
2. **Check agent reputation** - Research the agent's track record
3. **Set clear boundaries** - Understand what the agent can/cannot do
4. **Monitor activity** - Regularly review agent operations

### Agent Permission Boundaries

| Operation | Agent Can |
|-----------|-----------|
| Add Liquidity | ✅ Yes |
| Remove Liquidity | ✅ Yes |
| Collect Fees | ✅ Yes (to fee bag) |
| Withdraw Funds | ❌ No |
| Close Position | ❌ No |
| Authorize Agents | ❌ No |

### Revocation Strategy

Always have a plan to revoke agent access if needed:

```typescript
// Emergency revocation
async function emergencyRevoke(
  client: SuiGrpcClient,
  signer: any,
  pmId: string,
  agentAddress: string
) {
  // No special checks - just revoke immediately
  return revokeAgent(client, signer, pmId, agentAddress);
}
```
