# Changelog

All notable changes to this project will be documented in this file.  
This format follows [Keep a Changelog](https://keepachangelog.com/) and adheres to [Semantic Versioning](https://semver.org/).

## [v1.0.9] - 2026-04-22
### Added
- **Default Bastion NSG** (fixes #8): Dedicated NSG on the `AzureBastionSubnet` that denies all internet inbound on port 443 by default. Operators add trusted source IPs via the new `bastionAllowedSourceIPs` parameter. All required Bastion control-plane rules (GatewayManager, AzureLoadBalancer, BastionHostCommunication) are included. New module `modules/networking/bastion-nsg.bicep`.
- **Default Azure Firewall + UDR** (fixes #9): Azure Firewall with a Standard firewall policy and a route table that forces `0.0.0.0/0` egress through the firewall for workload subnets. Includes essential outbound FQDN rules (MCR, Entra ID) and diagnostics wired to Log Analytics. Enabled by default when network isolation is active.
- **Standalone AI Services account resource**: Pre-creates the `Microsoft.CognitiveServices/accounts` resource before the AVM `ai-foundry` module runs, with `dependsOn` wiring on the `aiFoundry` module. This permanently eliminates the `AccountProvisioningStateInvalid` race condition where the AVM module would attempt to create the AI Services private endpoint while the account was still in `Accepted` provisioning state.
- **Dedicated Azure AI Search for AI Foundry**: New `searchServiceAIFoundry` module provisions a separate AI Search instance (name `aiFoundrySearchServiceName`, Basic/2 replicas/1 partition) used exclusively by AI Foundry. The application search (`searchService`) remains dedicated to workload use. A matching private endpoint `privateEndpointSearchAIFoundry` is created when network isolation is active. Consumers can still bring their own Foundry search via `aiSearchResourceId`.
- **Consolidated DNS zones module** (`modules/networking/private-dns-zones.bicep`): Single for-loop wrapper over the AVM `avm/res/network/private-dns-zone` module. Replaces 15 individual Private DNS Zone module invocations in `main.bicep`.
- **Consolidated private endpoints module** (`modules/networking/private-endpoints.bicep`): Single `@batchSize(1)` for-loop wrapper over the AVM `avm/res/network/private-endpoint` module. Replaces 8 individual PE module invocations while preserving serialization. The App Insights Private Link Scope PE remains a separate module invocation due to its unique four-DNS-zone configuration.

### Changed
- **Cost optimization — Azure AI Search defaults** (fixes #11): Search service defaults changed to `sku: 'basic'`, `replicaCount: 2`, `partitionCount: 1`. This follows Azure AI Search reliability guidance (minimum 2 replicas for query workloads) while significantly reducing default cost. SKU, replica, and partition settings remain overridable for larger workloads.
- **Cost optimization — Jumpbox VM default** (fixes #11): Default `vmSize` changed from `Standard_D8s_v5` (8 vCPU / 32 GiB) to `Standard_D2s_v5` (2 vCPU / 8 GiB). Same Dsv5 general-purpose family, right-sized for the jumpbox admin/bootstrap role. Override remains available for heavier use cases.
- Estimated combined cost reduction from the above: ~$1,359/month (~$16.3k/year) for default deployments.
- **Template size optimization**: Compiled `main.json` reduced from **7.94 MB to 3.98 MB**, bringing the template below the 4 MB Azure Resource Manager request limit and unblocking `azd provision` with the `RequestContentTooLarge` error. Changes:
  - Collapsed 11 TestVM role-assignment modules into a single array-driven `assignTestVmRoles` module call.
  - Collapsed 8 Executor role-assignment modules into a single array-driven `assignExecutorRoles` module call.
  - Replaced the following AVM module wrappers with direct ARM resource declarations to avoid full nested-template inlining: all 7 user-assigned identities (including the `containerAppsUAI` loop), `logAnalytics` (`Microsoft.OperationalInsights/workspaces@2023-09-01`), `appInsights` (`Microsoft.Insights/components@2020-02-02`), `containerRegistry` (`Microsoft.ContainerRegistry/registries@2023-11-01-preview`), `keyVault` (`Microsoft.KeyVault/vaults@2024-11-01`), `containerEnv` (`Microsoft.App/managedEnvironments@2025-01-01`), and `appConfig` (`Microsoft.AppConfiguration/configurationStores@2024-05-01` with an explicit `Microsoft.Authorization/roleAssignments` for AppConfigurationDataOwner).
  - Functional behavior, feature flags, role assignments, idempotent GUIDs, and network-isolation dependency ordering are preserved.

### Fixed
- **`RoleAssignmentExists` deployment failure**: Removed the custom `assignSearchSearchServiceContributorAIFoundryProject` module from `main.bicep`. The AVM `ai-foundry` module already creates this role assignment (Search Service Contributor on the Search service for the AI Foundry Project identity) internally with the same deterministic GUID, causing a conflict on deployment. Cleaned up the downstream `dependsOn` accordingly.
- **`RequestContentTooLarge` on `azd provision`**: Compiled template size now 3.98 MB, under the 4 MB ARM limit (see the template size optimization entry above).

## [v1.0.8] - 2026-04-16
### Added
- New parameter `policyManagedPrivateDns` (`bool`, default `false`) to skip Private DNS Zone and DNS zone group creation. Use this in environments where Azure Policy manages Private DNS Zone linking (e.g., CAF Enterprise-Scale Platform Landing Zone). (PR #4, fixes #2)
- New parameter `privateEndpointLocation` to override the Azure region for private endpoint creation. Supports scenarios where the VNet is in a different region than the deployed resources. (PR #6, fixes #1)
- New parameter `privateEndpointResourceGroupName` to specify a dedicated resource group for private endpoints. (PR #6, fixes #3)
- New variable `_deployPrivateDnsZones` that gates all Private DNS Zone module deployments based on `networkIsolation && !policyManagedPrivateDns`.
- New variables `_peLocation`, `_defaultPeResourceGroupName`, and `_peResourceGroupName` for resolving PE location and resource group overrides with backward-compatible fallbacks.

### Changed
- All Private DNS Zone modules now conditionally deploy based on `_deployPrivateDnsZones` instead of `_networkIsolation`, allowing policy-managed environments to opt out.
- All private endpoint `privateDnsZoneGroup` configurations are conditionally set to `{}` when `policyManagedPrivateDns` is `true`.
- All 8 private endpoint module invocations updated to use `_peLocation` and `_peResourceGroupName` instead of hardcoded `location` and inline ternary expressions.
- Updated `main.parameters.json` with `privateEndpointLocation` and `privateEndpointResourceGroupName` entries supporting `azd` env var substitution (`AZURE_PE_LOCATION`, `AZURE_PE_RESOURCE_GROUP_NAME`).

### Refactored
- Extracted default PE resource group resolution into a separate `_defaultPeResourceGroupName` variable for improved readability.

## [v1.0.7] - 2026-04-14
### Fixed
- Fixed Log Analytics provisioning failure in Sweden Central (and other regions enforcing CMK validation) by explicitly setting `forceCmkForQuery: false` in the `logAnalytics` module. The AVM module defaults this to `true`, which requires a fully configured Customer Managed Key setup that the landing zone does not provision.

## [v1.0.6] - 2026-04-08
### Changed
- Parametrized Container App CPU and memory in `containerAppsList`. Each app can now optionally define `cpu` and `memory`, falling back to `'0.5'` and `'1.0Gi'` respectively.
- Added `dataingest` container app entry to default parameters with `cpu: "1.0"` and `memory: "2.0Gi"`.

## [v1.0.5] - 2026-04-01
### Fixed
- Fixed jumpbox Custom Script Extension using incorrect release tag. Replaced `install_script` URL field in `manifest.json` with `ailz_tag` field. The install script URL is now constructed from the tag in `main.bicep`, and the correct landing zone tag is passed to the `-release` parameter instead of the consumer repo tag.

### Documentation
- Updated `AGENTS.md` to reflect the `ailz_tag` field replacing `install_script`.

## [v1.0.4] - 2026-03-29
### Changed
- Made Cosmos DB throughput fully optional at both database and container levels using nullable types and safe access operators.
- Added `dbDatabaseThroughput` parameter (`int?`) for optional database-level throughput configuration.
- Container-level throughput and indexing policy are now optional via safe access (`container.?throughput`, `container.?indexingPolicy`).
- Default parameters no longer set throughput, aligning with the serverless Cosmos DB account configuration.

## [v1.0.3] - 2026-03-24
### Changed
- Simplified the default workload in `main.parameters.json` to a single Hello World container app (`orchestrator`) by removing GPT-RAG-specific defaults (`frontend`, `dataingest`, and `mcp`).
- Reduced default data resources by keeping only the `documents` storage container and `conversations` Cosmos DB container.
- Updated default chat model deployment from `gpt-4.1-mini` to `gpt-5-nano` and aligned model API versions to `2025-12-01-preview`.

### Removed
- Removed GPT-RAG-specific App Configuration keys from template defaults (`PROMPT_SOURCE`, `AGENT_STRATEGY`, and `AGENT_ID`).
- Removed tracked generated build artifact `main.json` from source control.

### Documentation
- Updated README container app role assignments to match current default configuration (Hello World `orchestrator` only).

## [v1.0.2] - 2026-03-17
### Fixed
- Fixed provisioning failures caused by unguarded references to outputs from optional resources when feature flags are disabled.
- Aligned App Configuration population with resource deployment toggles for Search, Key Vault, Storage, Container Apps, and Container Environment values.
- Aligned role-assignment loop conditions with `deployContainerApps` to prevent unsafe indexed references when Container Apps are disabled.
- Aligned user-assigned identity creation conditions with owning resource flags to avoid orphan identities.

## [v1.0.1] - 2026-03-06
### Fixed
- Fixed conditional references to Log Analytics outputs when `deployLogAnalytics=false`.
- Aligned App Insights, Private Link Scope, and scoped resources conditions with the Log Analytics flag.
- Prevented App Configuration values from referencing non-deployed Log Analytics/App Insights resources.

### Removed
- Removed all API Management (APIM) mentions and related configuration from the landing zone templates and constants.

## [v1.0.0] - 2026-03-02
### Added
- Initial release of the Azure AI Landing Zone Bicep implementation.