# Changelog

All notable changes to this project will be documented in this file.  
This format follows [Keep a Changelog](https://keepachangelog.com/) and adheres to [Semantic Versioning](https://semver.org/).

## [v1.1.1] - 2026-04-26

### Added
- **`enablePrivateLogAnalytics` parameter** (PR #16): new `bool` parameter (default `true`) that controls whether the Azure Monitor Private Link Scope (AMPLS) and its five associated private DNS zones (`privatelink.monitor.azure.com`, `privatelink.oms.opinsights.azure.com`, `privatelink.ods.opinsights.azure.com`, `privatelink.agentsvc.azure.automation.net`, `privatelink.applicationinsights.io`) are deployed when `networkIsolation = true`. Gated through `_deployAmpls = networkIsolation && deployAppInsights && deployLogAnalytics && enablePrivateLogAnalytics`. Set to `false` (or `ENABLE_PRIVATE_LOG_ANALYTICS=false`) when these singleton zones are managed centrally (e.g. by a hub) to avoid DNS conflicts and link collisions with other private endpoints. Default preserves existing zero-trust behavior.
- **`aiFoundryStorageSku` parameter and helper module** (PR #17): new `string` parameter (default `Standard_LRS`, `@allowed` covers all standard/premium SKUs) plus new module `modules/ai-foundry/storage-account.bicep` that pre-creates the AI Foundry Storage Account via `avm/res/storage/storage-account` with the requested SKU and an optional blob private endpoint when `networkIsolation = true`. The pre-created account's resource ID is fed back to the AVM `ai-foundry` pattern via `storageAccountConfiguration.existingResourceId`, so the AVM skips its internal storage creation. Workaround for `avm/ptn/ai-ml/ai-foundry@<=0.6.0`, which does not expose `skuName` and hardcodes `Standard_GRS` — failing in regions that don't offer GRS (e.g. Poland Central, with `RedundancyConfigurationNotAvailableInRegion`). Existing deployments passing `aiFoundryStorageAccountResourceId` are unaffected.

### Fixed
- **ACR Tasks agent pool hangs in `Queued` forever** (fixes #18): the `AllowAcrTasks` application rule on the Azure Firewall only allowed `*.azurecr.io` and `*.data.azurecr.io` from the build-agents subnet, but the ACR Tasks agent VM also needs egress to the Azure Storage queue/blob/table endpoints used by the ACR Tasks control plane to dispatch jobs. Without it, `az acr build --agent-pool <pool>` stayed in `Queued` indefinitely (no `startTime`), the agent pool eventually flipped to `Failed`, and any subsequent `update`/`scale` returned `RegistryStatusConflict`. Extended `_firewallAcrTaskFqdns` with `*.blob.${environment().suffixes.storage}`, `*.queue.${environment().suffixes.storage}`, and `*.table.${environment().suffixes.storage}` (sovereign-cloud safe via `environment().suffixes.storage`).

### Changed
- **`aiFoundryStorageSku` default** (PR #17): for new deployments where `aiFoundryStorageAccountResourceId` is empty, the AI Foundry Storage Account SKU defaults to `Standard_LRS` instead of the AVM default `Standard_GRS`. Trades cross-region redundancy for guaranteed regional availability — appropriate for a workload-scoped AI Foundry storage account. Operators wanting GRS can set `aiFoundryStorageSku: 'Standard_GRS'`.

### Removed
- **`main.json` no longer versioned**: the compiled ARM template generated from `main.bicep` was removed from the repository and added to `.gitignore`. It was the source of recurring merge conflicts on PRs and is regenerated on demand by `azd` / `az bicep build` during deployment, so it does not need to be tracked.

## [v1.1.0] - 2026-04-24
### Added
- **Optional ACR Task agent pool for network-isolated image builds** (fixes #14): new `Microsoft.ContainerRegistry/registries/agentPools@2019-06-01-preview` child resource parented to the existing `containerRegistry`, attached to the existing `devops-build-agents-subnet` (`/27`, previously unused). Gated on `deployContainerRegistry && networkIsolation && deployAcrTaskAgentPool`. Lets `az acr build --agent-pool <name>` run builds inside the VNet and push to the private ACR over its private endpoint, removing the need for Docker on any jumpbox or client and avoiding the common workaround of re-enabling `publicNetworkAccess` for every build.
  - New parameters in `main.bicep`:
    - `deployAcrTaskAgentPool` (`bool`, default `true`)
    - `acrTaskAgentPoolName` (`string`, `@maxLength(20)`, default `'build-pool'`)
    - `acrTaskAgentPoolTier` (`@allowed(['S1','S2','S3'])`, default `'S1'`)
    - `acrTaskAgentPoolCount` (`int`, `@minValue(0)`, default `1`)
  - New output `ACR_TASK_AGENT_POOL`: the agent pool name when deployed, empty otherwise. Surfaced via `azd env get-values`.
  - New firewall application rule `AllowAcrTasks` scoped to `devopsBuildAgentsSubnetPrefix`, allowing `*.azurecr.io` and `*.data.azurecr.io`. `management.azure.com` for task orchestration and `mcr.microsoft.com` for the builder base image are covered by existing shared rules.
  - Cost note: `S1` at `count=1` is billed per hour whether idle or not. To pause billing between builds: `az acr agentpool update -r <acr> -n <pool> --count 0`.
- **Complete Firewall allow-list for the jumpbox CSE bootstrap under network isolation** (fixes #15): replaced the monolithic `_firewallVmSetupFqdns` with four purpose-labeled sets that cover every tool `install.ps1` actually runs. All jumpbox-specific rules are now scoped to `jumpboxSubnetPrefix` (previously `*`) so the ACA/agent subnets do not inherit developer-tooling egress.
  - New parameter `extendFirewallForJumpboxBootstrap` (`bool`, default `true`) — disable if egress is managed centrally.
  - Shared `_firewallEssentialAuthFqdns` extended with `login.windows.net`, `management.azure.com`, and `*.applicationinsights.azure.com` (previously missing, caused `az <anything>` and telemetry calls to fail from inside the VNet).
  - Shared `_firewallEssentialGitHubFqdns` extended with `codeload.github.com` and `objects.githubusercontent.com` (git clone blob fetches).
  - New `_firewallVmBootstrapFqdns` (Chocolatey + Windows prerequisites): adds `packages.chocolatey.org`, `api.nuget.org`, `www.nuget.org`, `dist.nuget.org`, `download.visualstudio.microsoft.com`, `*.visualstudio.microsoft.com`, `download.microsoft.com`, `*.download.microsoft.com`. Fixes `choco install python311` failing on the `vcredist140` dependency download.
  - New `_firewallDevRuntimeFqdns` (Python + Node): adds `www.python.org`, `pypi.org`, `files.pythonhosted.org`, `*.pythonhosted.org`, `registry.npmjs.org`, `*.npmjs.org`. Fixes `pip install` failing against `files.pythonhosted.org`.
  - New `_firewallEditorFqdns` (VS Code): preserves the existing VS Code update endpoints but scoped to the jumpbox subnet.
  - Three new application rules — `AllowJumpboxBootstrap`, `AllowJumpboxDevRuntimes`, `AllowJumpboxEditors` — replace the old `AllowVmSetup` rule. Sources are `[jumpboxSubnetPrefix]` instead of `*`.

### Removed
- **Jumpbox Docker / Moby install** (fixes #14): `install.ps1` no longer installs Moby Engine, `docker buildx`, Docker Desktop, WSL2 features, or the associated 6-step Docker status tracking and log file (`docker-setup-status.json`). Rationale (per issue #14): Windows Server's Moby engine cannot run privileged Linux containers required by BuildKit, so the jumpbox could never actually build Linux images; Docker Desktop is not supported on Windows Server and requires a paid subscription above ~250 employees / ~$10M revenue. Image builds move to the ACR Tasks agent pool. `install.ps1` now prints a short MOTD pointing users at `az acr build --agent-pool <pool>`.
- **Docker Hub FQDNs** removed from the Firewall Policy allow-list: `download.docker.com` and `desktop.docker.com` are no longer required because the jumpbox no longer installs Docker.

### Changed
- **`install.ps1` reboot reason** updated from "activate Windows Containers feature" to "finalize installed tooling" (Chocolatey-installed Git/Python/VS Code/PowerShell Core may flag a pending reboot). The 120 s delay before `shutdown /r` is preserved so the Custom Script Extension agent can still report `Succeeded` to ARM before the VM goes down.

### Fixed
- **`choco install python311` fails on fresh NI jumpbox**: blocked by firewall while fetching `vcredist140` from `download.visualstudio.microsoft.com`. Addressed by the new `_firewallVmBootstrapFqdns` set.
- **`git clone https://github.com/...` on jumpbox fails mid-fetch**: blob fetches to `codeload.github.com` / `objects.githubusercontent.com` were not matched by the prior narrow GitHub list. Addressed by extending `_firewallEssentialGitHubFqdns`.
- **`pip install ...` on jumpbox fails**: `files.pythonhosted.org` was not matched by `*.pypi.org`. Addressed by the new `_firewallDevRuntimeFqdns` set.
- **`az <anything>` against `management.azure.com` from jumpbox fails**: ARM endpoint was missing from `_firewallEssentialAuthFqdns`. Addressed by extending that set.

## [v1.0.9] - 2026-04-22
### Fixed (amended 2026-04-23, third amendment)
- **Rare race condition between `searchService` and `searchServiceAIFoundry`**: The two Azure AI Search services introduced in v1.0.9 had no dependency wiring, so ARM attempted to create them in parallel. In some regions (observed in Sweden Central) this occasionally caused the `Microsoft.Search` resource provider to leave the second service name "stuck" in its internal namespace cache, producing `ServiceNameUnavailable` on the first deployment and then `A service with the name '…' already exists` on retry — even though `checkNameAvailability` reports the name available and `az resource list` shows no such service. Added a `dependsOn: [searchService!]` to `searchServiceAIFoundry` in `main.bicep` to serialize their creation and eliminate the race. If a name is already stuck from a previous failed deployment, the backend cache typically clears within 4–24h; alternatively, override `aiFoundrySearchServiceName` or set `aiSearchResourceId` to reuse an existing Search account.

### Fixed (amended 2026-04-23)
- **CSE stuck in `Updating` provisioning state after jumpbox bootstrap**: `install.ps1` previously scheduled the post-install reboot via `schtasks` ~1 minute after the script ended, which caused the VM to reboot before the Custom Script Extension agent could report `Succeeded` back to ARM. As a result, `Microsoft.Compute/virtualMachines/extensions/cse` stayed permanently at `provisioningState=Updating`, blocking `az vm extension wait` and any downstream deployment gating on CSE completion. Replaced the `schtasks` approach with `shutdown /r /t 120`, giving the CSE agent ~30s to post its final status to ARM before the reboot happens. The reboot itself is preserved because it is required to activate the Windows `Containers` feature for Docker. **Validated on 2026-04-23**: clean redeploy of the jumpbox on env `ailz-ni-win-04231238` reported `provisioningState=Succeeded` with CSE exit code `0` (duration ~10 min, no stderr), and the overall `azd provision` completed in ~18 min.

### Added (amended 2026-04-23)
- **Hardened jumpbox Docker Engine (Moby) bootstrap in `install.ps1`**: Server branch rewritten with explicit step-by-step logging, per-step `try/catch` error capture, and post-install validation. Improvements:
  - Windows `Containers` feature enable is now performed **before** extracting Moby and registering `dockerd`, matching the documented install order for Moby on Windows Server.
  - `$env:ProgramFiles\docker` is **prepended** to MACHINE/Session `Path` (instead of appended) so `docker.exe` from Moby wins over any pre-existing Docker client binary on the VM image.
  - `Start-Service docker` is followed by a 60-second wait loop that confirms the service reaches `Running` before buildx bootstrap is attempted.
  - `docker-buildx` plugin install and `buildx create --driver docker-container` bootstrap are gated on the daemon actually being `Running`, avoiding silent bootstrap failures.
  - A machine-readable status file is written to `C:\WindowsAzure\Logs\docker-setup-status.json` capturing the outcome of each of the 6 setup steps (Containers feature, Moby download, Moby extract, service register, service running, buildx plugin, buildx bootstrap).
  - All output continues to be captured in the existing `Start-Transcript` log at `C:\WindowsAzure\Logs\CMFAI_CustomScriptExtension.txt`.
  - Motivation: prior deployments showed the Custom Script Extension reporting success while the Docker Engine was in fact not registered as a service (no `docker` Windows service, no `buildx` plugin, `Containers` feature not enabled). The new layout surfaces the exact failing step in the transcript and status file, and eliminates PATH precedence ambiguity when a pre-existing `docker.exe` is on the image.

### Added
- **`searchServiceLocation` parameter**: New optional parameter to override the Azure region for Azure AI Search services. Set via `AZURE_SEARCH_LOCATION` in azd env. Useful when the primary deployment region is out of capacity for AI Search (`InsufficientResourcesAvailable` error).
- **Default Bastion NSG** (fixes #8): Dedicated NSG on the `AzureBastionSubnet` that denies all internet inbound on port 443 by default. Operators add trusted source IPs via the new `bastionAllowedSourceIPs` parameter. All required Bastion control-plane rules (GatewayManager, AzureLoadBalancer, BastionHostCommunication) are included. New module `modules/networking/bastion-nsg.bicep`.
- **Default Azure Firewall + UDR** (fixes #9): Azure Firewall with a Standard firewall policy and a route table that forces `0.0.0.0/0` egress through the firewall for workload subnets. Includes essential outbound FQDN rules (MCR, Entra ID) and diagnostics wired to Log Analytics. Enabled by default when network isolation is active.
- **Standalone AI Services account resource**: Pre-creates the `Microsoft.CognitiveServices/accounts` resource before the AVM `ai-foundry` module runs, with `dependsOn` wiring on the `aiFoundry` module. This permanently eliminates the `AccountProvisioningStateInvalid` race condition where the AVM module would attempt to create the AI Services private endpoint while the account was still in `Accepted` provisioning state.
- **Dedicated Azure AI Search for AI Foundry**: New `searchServiceAIFoundry` module provisions a separate AI Search instance (name `aiFoundrySearchServiceName`, Basic/2 replicas/1 partition) used exclusively by AI Foundry. The application search (`searchService`) remains dedicated to workload use. A matching private endpoint `privateEndpointSearchAIFoundry` is created when network isolation is active. Consumers can still bring their own Foundry search via `aiSearchResourceId`.
- **Consolidated DNS zones module** (`modules/networking/private-dns-zones.bicep`): Single for-loop wrapper over the AVM `avm/res/network/private-dns-zone` module. Replaces 15 individual Private DNS Zone module invocations in `main.bicep`.
- **Consolidated private endpoints module** (`modules/networking/private-endpoints.bicep`): Single `@batchSize(1)` for-loop wrapper over the AVM `avm/res/network/private-endpoint` module. Replaces 8 individual PE module invocations while preserving serialization. The App Insights Private Link Scope PE remains a separate module invocation due to its unique four-DNS-zone configuration.

### Changed
- **Cost optimization — Azure AI Search defaults** (fixes #11): Search service defaults changed to `sku: 'basic'`, `replicaCount: 1`, `partitionCount: 1`. Reduced `replicaCount` from 2 to 1 to lower default cost and ease regional capacity pressure in constrained regions. SKU, replica, and partition settings remain overridable for larger workloads.
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
- **Network-isolation provisioning failures**:
  - **App Configuration Forbidden on `keyValues` writes under NI**: `appConfigPopulate` and `cosmosConfigKeyVaultPopulate` are now gated with `!_networkIsolation` to avoid ARM data-plane writes against an App Configuration store with `publicNetworkAccess: 'Disabled'` (writes require an ARM private link path not provisioned by this template).
  - **App Configuration `dataPlaneProxy.privateLinkDelegation`** now set to `'Enabled'` when `_networkIsolation` is true (required by API `2024-05-01` when `publicNetworkAccess` is `Disabled`).
  - **`InvalidTemplate: bastionNsgDeployment requires an API version`** when `deployVM=false`: made the `networkSecurityGroupResourceId` reference in the VNet `baseSubnets` null-safe using `bastionNsg!.outputs.id` gated on `(deployVM && _networkIsolation && deployNsgs)`.
  - **Jumpbox VM `OSProvisioningTimedOut`**: default `vmSize` changed to `Standard_D2s_v3` (v5 family unavailable in several regions incl. East US 2) and `deployVM` is now controllable via the `DEPLOY_VM` azd env var (`${DEPLOY_VM=true}`) so operators can opt out in subscriptions where Azure Policy auto-installs the `AzurePolicyforWindows` extension and blocks OS provisioning.

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