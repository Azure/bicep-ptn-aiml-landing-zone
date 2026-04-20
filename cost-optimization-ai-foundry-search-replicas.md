# Cost Optimization: Reduce AI Foundry's AI Search Replica Count from 3 to 1

## Motivation

The current default deployment creates **two separate Azure AI Search instances**:

1. **Application AI Search** (`searchService` / `srch-{token}`) — deployed directly in `main.bicep`, uses `standard` SKU with `replicaCount: 1`. **This is already cost-optimized. No changes needed.**

2. **AI Foundry AI Search** (`srch-aif-{token}`) — deployed internally by the AVM pattern module `avm/ptn/ai-ml/ai-foundry:0.6.0`. This instance is created with **3 replicas** by default inside the AVM module, which is excessive for development, testing, and most production scenarios that don't require high-availability query throughput.

At `standard` SKU pricing (~$336/month per Search Unit), the difference between 3 replicas and 1 replica is:

| Configuration | Search Units | Estimated Monthly Cost |
|---|---|---|
| Current (3 replicas × 1 partition) | 3 SU | **~$1,008/month** |
| Proposed (1 replica × 1 partition) | 1 SU | **~$336/month** |
| **Savings** | | **~$672/month (~$8,064/year)** |

> Note: 3 replicas provide an SLA for read queries, but this is not required for dev/test scenarios and is often unnecessary for initial production deployments. A single replica provides no SLA but is fully functional.

## Rationale

- The AI Foundry AI Search is used for AI Foundry's internal indexing (agentic retrieval, knowledge stores). For most development and evaluation workloads, a single replica is sufficient.
- Azure AI Search supports scaling replicas up at any time without downtime, so starting with 1 replica and scaling when needed is a safe approach.
- The 3-replica default inside the AVM module appears to be a WAF-aligned (Well-Architected Framework) production default, but is not appropriate as the default for a landing zone accelerator used primarily for bootstrapping and development.

## Current Architecture

```
main.bicep
├── searchService (Application AI Search)
│   ├── sku: 'standard'
│   ├── replicaCount: 1          ← Already optimized ✅
│   └── Directly configured in main.bicep (line ~2139)
│
└── aiFoundry (modules/ai-foundry/main.bicep)
    └── avm/ptn/ai-ml/ai-foundry:0.6.0
        └── AI Foundry AI Search (srch-aif-*)
            ├── replicaCount: 3   ← Created by AVM internally ❌
            └── NOT configurable via aiSearchConfiguration
```

## The Problem

The `aiSearchConfiguration` parameter of the AVM module (`avm/ptn/ai-ml/ai-foundry`) only exposes:
- `existingResourceId` — use an existing resource
- `name` — resource name
- `privateDnsZoneResourceId` — DNS zone for private endpoints
- `roleAssignments` — RBAC

**There is no `sku` or `replicaCount` property** in `aiSearchConfiguration`. The AVM module hardcodes the AI Search configuration internally.

## Recommended Implementation

### Option A: Use "Bring Your Own" Pattern (Preferred — No AVM dependency)

Create the AI Foundry's AI Search as a standalone resource in `main.bicep` with explicit `replicaCount: 1`, then pass its resource ID to the AVM module via `existingResourceId`.

**Steps:**
1. Add a new AI Search module deployment in `main.bicep` for the AI Foundry instance:
   ```bicep
   module aiFoundrySearchService 'br/public:avm/res/search/search-service:0.11.1' = if (deployAiFoundry) {
     name: 'aiFoundrySearchService'
     params: {
       name: aiFoundrySearchServiceName
       location: location
       sku: 'standard'
       replicaCount: 1
       publicNetworkAccess: _networkIsolation ? 'Disabled' : 'Enabled'
       tags: _tags
       // ... identity, auth, etc.
     }
   }
   ```

2. Update `varAfAiSearchCfgComplete` (line ~1569) to always pass `existingResourceId`:
   ```bicep
   var varAfAiSearchCfgComplete = {
     existingResourceId: deployAiFoundry ? aiFoundrySearchService.outputs.resourceId : null
     name: aiFoundrySearchServiceName
     privateDnsZoneResourceId: _networkIsolation ? _dnsZoneSearchId : null
     roleAssignments: []
   }
   ```

3. This gives us full control over SKU, replicaCount, identity, auth, and shared private link resources for the AI Foundry AI Search, independent of the AVM module defaults.

### Option B: Request AVM Module Enhancement (Long-term)

File an issue on the [Azure/bicep-registry-modules](https://github.com/Azure/bicep-registry-modules) repository requesting that `aiSearchConfiguration` expose `sku` and `replicaCount` properties. This would allow configuration without the "bring your own" workaround.

## Acceptance Criteria

- [ ] AI Foundry's AI Search instance deploys with `replicaCount: 1` by default
- [ ] Application AI Search remains unchanged (`standard` SKU, `replicaCount: 1`)
- [ ] Bastion SKU remains `Standard` (no changes)
- [ ] Both `networkIsolation = true` and `networkIsolation = false` deployment modes work
- [ ] AI Foundry connections and agent service functionality remain intact
- [ ] Private endpoint and DNS zone configuration for AI Foundry Search is preserved in isolated mode
- [ ] Optionally: parameterize `aiFoundrySearchReplicaCount` to allow users to override

## Cost Impact Summary

| Resource | Current | Proposed | Monthly Savings | Annual Savings |
|---|---|---|---|---|
| AI Foundry AI Search (3 → 1 replicas) | ~$1,008 | ~$336 | **~$672** | **~$8,064** |
| Application AI Search | ~$336 (1 replica) | No change | $0 | $0 |
| Bastion | Standard | No change | $0 | $0 |
| **Total** | | | **~$672/month** | **~$8,064/year** |
