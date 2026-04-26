// ============================================================================
// AI Landing Zone Bicep Deployment Template
// This infrastructure-as-code template follows best practices for modular,
// reusable, and configuration-aware deployments. Key principles:
//
// - **AZD Integration**: This template is optimized for use with the Azure Developer CLI (`azd`).
//   Use `azd provision` to deploy infrastructure and `azd deploy` to deploy your application.
//   It supports automated, repeatable, and configuration-aware workflows. The `main.json` file
//   can include placeholders (e.g., `${AZURE_LOCATION}`, `${AZURE_PRINCIPAL_ID}`) that are automatically
//   injected by `azd` during execution, enabling seamless parameter resolution.
//
// - **Parameterization**: All configuration values are defined in `main.json`.
//   You can create multiple parameter files to support different deployment configurations,
//   such as variations in scale, resource combinations, or cost constraints.
//
// - **Feature Flags**: Resource provisioning is modular and controlled via feature flags
//   (e.g., `deployAppConfig`). This enables selective deployment of components based on project needs.
//
// - **Azure Verified Modules (AVM)**: Official AVM modules are used as the foundation
//   for resource deployment, ensuring consistency, maintainability, and alignment with Microsoft standards.
//   Reference: https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/
//   When AVM does not cover a specific resource, custom Bicep module is used as fallback.
//
// - **Output Exposure**: Key outputs such as connection strings, endpoints, and resource IDs
//   are exposed as Bicep outputs and can be consumed by downstream processes or deployment scripts.
//
// - **Post-Provisioning Automation**: Supports optional post-provisioning scripts to perform data plane
//   operations or additional configurations. These scripts can run independently or as `azd` hooks,
//   enabling fine-grained control and custom automation after infrastructure deployment.
//
// ============================================================================

targetScope = 'resourceGroup'

//////////////////////////////////////////////////////////////////////////
// PARAMETERS
//////////////////////////////////////////////////////////////////////////

// Important notes about parameters:
// 1) Before running azd provision, set parameter values using main.parameters.json or 
// the command line: azd env set ENV_VARIABLE_NAME value, for parameters configured to allow substitution.
//
// 2) You can identify these substitutable parameters in main.parameters.json by this format:
// "parameterName": { "value": "${ENV_VARIABLE_NAME}" }.
// This allows the convenience of setting values via the command line (e.g., azd env set ENV_VARIABLE_NAME true).
//
// 3) Substitutable parameters: if an environment variable isn’t set before running `azd provision`, its value will be empty.
// To prevent this, each parameter that uses the substitution mechanism has a corresponding Bicep variable (`_parameterName`) with a default value.
// When adding new substitutable parameters in this Bicep file or in `main.parameters.bicep`, follow the same pattern.

// ---------------------------------------------------------------------
// Imports
// ----------------------------------------------------------------------
import * as const from 'constants/constants.bicep'

// ----------------------------------------------------------------------
// General Parameters
// ----------------------------------------------------------------------

@description('Name of the Azure Developer CLI environment')
param environmentName string

@description('The Azure region where your resources will be created.')
param location string = resourceGroup().location

@description('The Azure region where Cosmos DB will be created. Defaults to the resource group location.')
param cosmosLocation string = resourceGroup().location

@description('The Azure region where Azure AI Search services will be created. Defaults to the main deployment location. Override this when the primary region is out of capacity for AI Search.')
param searchServiceLocation string = ''

@description('Principal ID for role assignments. This is typically the Object ID of the user or service principal running the deployment.')
param principalId string

@description('Principal type for role assignments. This can be "User", "ServicePrincipal", or "Group".')
param principalType string = 'User'

@description('Tags to apply to all resources in the deployment')
param deploymentTags object = {}

@description('Label used for App Configuration key-value pairs.')
param appConfigLabel string = 'ai-lz'

@description('Enable network isolation for the deployment. This will restrict public access to resources and require private endpoints where applicable.')
param networkIsolation bool = false

@description('''When set to true, Private DNS Zones and DNS zone groups will NOT be created by this module.
Use this option in environments where Azure Policy automatically manages Private DNS Zone linking for private endpoints
(e.g., CAF Enterprise-Scale Platform Landing Zone). Creating DNS zones in those environments causes conflicts with
policy-driven DNS management and results in deployment failures.
When false (default), the module creates and manages all Private DNS Zones and links them to the VNet.
Requires networkIsolation to be true to have any effect.''')
param policyManagedPrivateDns bool = false

@description('The Azure region where private endpoints will be created. Defaults to the main deployment location. Use this when your VNet is in a different region than the resources.')
param privateEndpointLocation string = ''

@description('The name of the resource group where private endpoints will be created. When empty, private endpoints are placed in the VNet resource group (for existing VNets with sideBySideDeploy disabled) or the deployment resource group.')
param privateEndpointResourceGroupName string = ''

@description('Use an existing Virtual Network. When false, a new VNet will be created.')
param useExistingVNet bool = false

@description('The full ARM resource ID of an existing Virtual Network. Format: /subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}/providers/Microsoft.Network/virtualNetworks/{vnetName}. Leave empty to create a new VNet.')
param existingVnetResourceId string = ''

param agentSubnetName string = 'agent-subnet'
param peSubnetName string = 'pe-subnet'
param gatewaySubnetName string = 'gateway-subnet'
param azureBastionSubnetName string = 'AzureBastionSubnet'
param azureFirewallSubnetName string = 'AzureFirewallSubnet'
param azureAppGatewaySubnetName string = 'AppGatewaySubnet'
param jumpboxSubnetName string = 'jumpbox-subnet'
param acaEnvironmentSubnetName string = 'aca-environment-subnet'
param devopsBuildAgentsSubnetName string = 'devops-build-agents-subnet'

@description('Address prefixes for the virtual network.')
param vnetAddressPrefixes array = [
  '192.168.0.0/21' // 192.168.0.0 – 192.168.7.255 (2048 IPs total)
]

//
// Subnet allocations (non-overlapping, optimized for production workloads)
// PE subnet increased to /26 to support multiple Private Endpoints without race conditions
//

@description('AI Foundry Agents subnet — Recommended /24 (256 IPs)')
param agentSubnetPrefix string = '192.168.0.0/24' // 192.168.0.0–192.168.0.255

@description('Azure Container Apps Environment subnet — /24 (256 IPs)') // Recommended minimum is /23
param acaEnvironmentSubnetPrefix string = '192.168.1.0/24' // 192.168.1.0–192.168.1.255

@description('Private Endpoints subnet — /26 (64 IPs) — Increased to prevent race conditions during parallel PE creation')
param peSubnetPrefix string = '192.168.2.0/26' // 192.168.2.0–192.168.2.63

@description('Azure Bastion subnet — Required /26 (64 IPs, CIDR-aligned)')
param azureBastionSubnetPrefix string = '192.168.2.64/26' // 192.168.2.64–192.168.2.127

@description('Azure Firewall subnet — /26 (64 IPs, CIDR-aligned)')
param azureFirewallSubnetPrefix string = '192.168.2.128/26' // 192.168.2.128–192.168.2.191

@description('Gateway subnet — Required /26 (64 IPs, CIDR-aligned)')
param gatewaySubnetPrefix string = '192.168.2.192/26' // 192.168.2.192–192.168.2.255

@description('Application Gateway subnet — /27 (32 IPs)')
param azureAppGatewaySubnetPrefix string = '192.168.3.0/27' // 192.168.3.0–192.168.3.31

@description('Jumpbox subnet — /27 (32 IPs)')
param jumpboxSubnetPrefix string = '192.168.3.64/27' // 192.168.3.64–192.168.3.95

@description('DevOps Build Agents subnet — /27 (32 IPs)')
param devopsBuildAgentsSubnetPrefix string = '192.168.3.96/27' // 192.168.3.96–192.168.3.127

// ----------------------------------------------------------------------
// Feature-flagging Params (as booleans with a default of true)
// ----------------------------------------------------------------------

// @description('If false, skips creating platform infrastructure such as Firewall, Jumpbox, Bastion, etc.')
// param greenFieldDeployment bool = true

@description('Whether to deploy Bing-powered grounding capabilities alongside your AI services.')
param deployGroundingWithBing bool = true

@description('Deploy Azure AI Foundry for building and managing AI models.')
param deployAiFoundry bool = true

@description('Deploy Azure AI Foundry agent subnet.')
param deployAiFoundrySubnet bool = true

@description('Deploy Azure App Configuration for centralized feature-flag and configuration management.')
param deployAppConfig bool = true

@description('Deploy an Azure Key Vault to securely store secrets, keys, and certificates.')
param deployKeyVault bool = true

@description('Deploy an Azure Key Vault to securely store VM secrets, keys, and certificates.')
param deployVmKeyVault bool = true

@description('Deploy an Azure Log Analytics workspace for centralized log collection and query.')
param deployLogAnalytics bool = true

@description('When network isolation is enabled, also deploy an Azure Monitor Private Link Scope (AMPLS) with private endpoints and the related monitor/opinsights/automation private DNS zones to keep Log Analytics + Application Insights traffic on the private network. Disable to opt-out and avoid sharing those Azure Monitor private DNS zones with other workloads (preventing cross-workload DNS conflicts). Has no effect when networkIsolation is false.')
param enablePrivateLogAnalytics bool = true

@description('Deploy Azure Application Insights for application performance monitoring and diagnostics.')
param deployAppInsights bool = true

@description('Deploy an Azure Cognitive Search service for indexing and querying content. When disabled, search-related connections are skipped and search app configuration values resolve to empty values.')
param deploySearchService bool = true

@description('Deploy an Azure Storage Account to hold blobs, queues, tables, and files.')
param deployStorageAccount bool = true

@description('Deploy an Azure Cosmos DB account for globally distributed NoSQL data storage.')
param deployCosmosDb bool = true

@description('Deploy Azure Container Apps for running your microservices in a serverless Kubernetes environment.')
param deployContainerApps bool = true

@description('Deploy an Azure Container Registry to store and manage Docker container images.')
param deployContainerRegistry bool = true

@description('Deploy the Container Apps environment (log ingestion, VNet integration, etc.).')
param deployContainerEnv bool = true

@description('Deploy a Virtual Machine (e.g., for jumpbox or specialized workloads).')
param deployVM bool = true

@description('Deploy the virtual network subnets.')
param deploySubnets bool = true

@description('Will deploy network security groups.')
param deployNsgs bool = true

@description('Deploy Azure Firewall with UDR for egress traffic control. Defaults to true when networkIsolation is enabled.')
param deployAzureFirewall bool = true

@description('Deploy an ACR Task agent pool so image builds can run inside the VNet when the registry has public access disabled. Requires a Premium container registry (auto-selected when networkIsolation is true) and is gated on both deployContainerRegistry and networkIsolation.')
param deployAcrTaskAgentPool bool = true

@description('Name for the ACR Task agent pool. Max 20 characters.')
@maxLength(20)
param acrTaskAgentPoolName string = 'build-pool'

@description('SKU tier for the ACR Task agent pool: S1 (2 vCPU), S2 (4 vCPU), S3 (8 vCPU).')
@allowed([ 'S1', 'S2', 'S3' ])
param acrTaskAgentPoolTier string = 'S1'

@description('Initial instance count for the ACR Task agent pool. Set to 0 after provisioning to pause billing (az acr agentpool update -r <acr> -n <pool> --count 0).')
@minValue(0)
param acrTaskAgentPoolCount int = 1

@description('When true, extends the Azure Firewall Policy with the FQDN allow-list required by the default install.ps1 jumpbox bootstrap (Chocolatey, Python, Node, VS Code, GitHub clones, Azure CLI control plane). Disable if you manage egress centrally.')
param extendFirewallForJumpboxBootstrap bool = true

@description('List of trusted source IP CIDRs allowed to connect to the Bastion public IP on port 443. When empty, all internet inbound to port 443 is denied by default.')
param bastionAllowedSourceIPs array = []

@description('Will deploy network resources side by side with the Azure resources.')
param sideBySideDeploy bool = true

@description('Deploy Virtual Machine software.')
param deploySoftware bool = true

@description('Deploy AI Foundry Project.')
param deployAfProject bool = true

@description('Deploy AI Foundry Service.')
param deployAAfAgentSvc bool = true


@description('Enable agentic retrieval features in Azure AI Search indexes. Requires vectorizer configuration and semantic search.')
param enableAgenticRetrieval bool = false

// ----------------------------------------------------------------------
// Reuse Existing Services Parameters
// Note: Reuse is optional. Leave empty to create new resources
// ----------------------------------------------------------------------

// AI Foundry Dependencies

@description('The AI Search Service full ARM resource ID. Optional; if not provided, a new resource will be created.')
param aiSearchResourceId string = ''

@description('The AI Storage Account full ARM resource ID. Optional; if not provided, a new resource will be created.')
param aiFoundryStorageAccountResourceId string = ''

@description('The SKU name for the AI Foundry Storage Account. Only used when a new account is created (aiFoundryStorageAccountResourceId is empty). The AVM ai-foundry module does not expose this, so we pre-create the storage account with the requested SKU. Defaults to Standard_LRS for broad regional availability (some regions, e.g. Poland Central, do not support the AVM default Standard_GRS).')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_RAGRS'
  'Standard_ZRS'
  'Standard_GZRS'
  'Standard_RAGZRS'
  'Premium_LRS'
  'Premium_ZRS'
])
param aiFoundryStorageSku string = 'Standard_LRS'

@description('The Cosmos DB account full ARM resource ID. Optional; if not provided, a new resource will be created.')
param aiFoundryCosmosDBAccountResourceId string = ''

// GenAI App Services

@description('The Key Vault full ARM resource ID. Optional; if not provided, a new vault will be created.')
param keyVaultResourceId string = ''

// ----------------------------------------------------------------------
// Feature-flagging Params (as booleans with a default of false)
// ----------------------------------------------------------------------
param useUAI bool = false // Use User Assigned Identity (UAI)
param useCAppAPIKey bool = false // Use API Keys to connect to container apps
param useZoneRedundancy bool = false // Use Zone Redundancy

// ----------------------------------------------------------------------
// Resource Naming params
// ----------------------------------------------------------------------

@description('Unique token used to build deterministic resource names, derived from subscription ID, environment name, and location.')
param resourceToken string = toLower(uniqueString(subscription().id, environmentName, location))

@description('Name of the Azure AI Foundry account to create or reference.')
param aiFoundryAccountName string = '${const.abbrs.ai.aiFoundry}${resourceToken}'

@description('Name of the AI Foundry project resource.')
param aiFoundryProjectName string = '${const.abbrs.ai.aiFoundryProject}${resourceToken}'

@description('Name of the Storage Account used by AI Foundry for blobs, queues, tables, and files.')
param aiFoundryStorageAccountName string = replace('${const.abbrs.storage.storageAccount}${const.abbrs.ai.aiFoundry}${resourceToken}', '-', '')

@description('Name of the Cognitive Search service provisioned for AI Foundry.')
param aiFoundrySearchServiceName string = '${const.abbrs.ai.aiSearch}${const.abbrs.ai.aiFoundry}${resourceToken}'

@description('Name of the Azure Cosmos DB account used by AI Foundry.')
param aiFoundryCosmosDbName string = '${const.abbrs.databases.cosmosDBDatabase}${const.abbrs.ai.aiFoundry}${resourceToken}'

@description('Name of the Bing Search resource for grounding capabilities.')
param bingSearchName string = '${const.abbrs.ai.bing}${resourceToken}'

@description('Name of the Azure App Configuration store for centralized settings.')
param appConfigName string = '${const.abbrs.configuration.appConfiguration}${resourceToken}'

@description('Name of the Application Insights instance for monitoring.')
param appInsightsName string = '${const.abbrs.managementGovernance.applicationInsights}${resourceToken}'

@description('Name of the Azure Container Apps environment (log ingestion, VNet integration, etc.).')
param containerEnvName string = '${const.abbrs.containers.containerAppsEnvironment}${resourceToken}'

@description('Name of the Azure Container Registry for storing Docker images.')
param containerRegistryName string = '${const.abbrs.containers.containerRegistry}${resourceToken}'

@description('Name of the Cosmos DB account (alias for database operations).')
param dbAccountName string = '${const.abbrs.databases.cosmosDBDatabase}${resourceToken}'

@description('Name of the Cosmos DB database to host application data.')
param dbDatabaseName string = '${const.abbrs.databases.cosmosDBDatabase}db${resourceToken}'

@description('Name of the Azure Key Vault for secrets, keys, and certificates.')
param keyVaultName string = '${const.abbrs.security.keyVault}${resourceToken}'

@description('Name of the Log Analytics workspace for collecting and querying logs.')
param logAnalyticsWorkspaceName string = '${const.abbrs.managementGovernance.logAnalyticsWorkspace}${resourceToken}'

@description('Name of the Cognitive Search service.')
param searchServiceName string = '${const.abbrs.ai.aiSearch}${resourceToken}'

@description('Name of the Azure Storage Account for general-purpose blob and file storage.')
param storageAccountName string = '${const.abbrs.storage.storageAccount}${resourceToken}'

@description('Name of the Virtual Network to isolate resources and enable private endpoints.')
param vnetName string = '${const.abbrs.networking.virtualNetwork}${resourceToken}'

// ----------------------------------------------------------------------
// Azure AI Foundry Service params
// ----------------------------------------------------------------------

@description('List of model deployments to create in the AI Foundry account')
param modelDeploymentList array

// ----------------------------------------------------------------------
// Container Apps params
// ----------------------------------------------------------------------

@description('List of container apps to create')
param containerAppsList array

@description('Workload profiles.')
param workloadProfiles array = []

param acrDnsSuffix string = (environment().name == 'AzureUSGovernment' ? 'azurecr.us' : environment().name == 'AzureChinaCloud'   ? 'azurecr.cn' : 'azurecr.io')

// ----------------------------------------------------------------------
// Cosmos DB Database params
// ----------------------------------------------------------------------

@description('Optional throughput (RU/s) for the Cosmos DB database. Omit or set to null for serverless accounts.')
param dbDatabaseThroughput int?

@description('List of Cosmos DB containers to create. Each entry supports optional throughput and indexingPolicy via safe access.')
param databaseContainersList array

// ----------------------------------------------------------------------
// VM params
// ----------------------------------------------------------------------

@description('The name of the Test VM. If left empty, a random name will be generated.')
param vmName string = ''

@description('Test vm user name. Needed only when choosing network isolation and create bastion option. If not you can leave it blank.')
param vmUserName string = ''

@secure()
@description('Admin password for the test VM user')
param vmAdminPassword string

@description('Size of the test VM')
param vmSize string = 'Standard_D2s_v5'

@description('Image SKU (e.g., 2022-datacenter-azure-edition, win11-25h2-ent).')
param vmImageSku string = '2022-datacenter-azure-edition'

@description('Image publisher (Windows Server: MicrosoftWindowsServer, Windows 11: MicrosoftWindowsDesktop).')
param vmImagePublisher string = 'MicrosoftWindowsServer'

@description('Image offer (Windows Server: WindowsServer, Windows 11: windows-11).')
param vmImageOffer string = 'WindowsServer'

@description('Image version (use latest unless you need a pinned build).')
param vmImageVersion string = 'latest'


// ----------------------------------------------------------------------
// Storage Account params
// ----------------------------------------------------------------------

@description('List of containers to create in the Storage Account')
param storageAccountContainersList array

// ----------------------------------------------------------------------
// CMK params
// ----------------------------------------------------------------------
// Note : Customer Managed Keys (CMK) not implemented in this module yet
// @description('Use Customer Managed Keys for Storage Account and Key Vault')
// param useCMK      bool   = false

//////////////////////////////////////////////////////////////////////////
// VARIABLES
//////////////////////////////////////////////////////////////////////////

// ----------------------------------------------------------------------
// General Variables
// ----------------------------------------------------------------------

var _manifest = loadJsonContent('./manifest.json')
var _azdTags = { 'azd-env-name': environmentName }
var _tags = union(_azdTags, deploymentTags)
var _networkIsolation = empty(string(networkIsolation)) ? false : bool(networkIsolation)
// AMPLS (Azure Monitor Private Link Scope) and the related monitor/opinsights/automation
// private DNS zones + private endpoint are only deployed when network isolation is on AND
// the operator explicitly opts in via enablePrivateLogAnalytics. This lets isolated
// deployments opt-out of AMPLS to avoid cross-workload private DNS conflicts.
var _deployAmpls = _networkIsolation && deployAppInsights && deployLogAnalytics && enablePrivateLogAnalytics
var _deployPrivateDnsZones = _networkIsolation && !policyManagedPrivateDns
var _searchServiceLocation = empty(searchServiceLocation) ? location : searchServiceLocation


// ----------------------------------------------------------------------
// Container vars
// ----------------------------------------------------------------------

var _containerDummyImageName = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

// ----------------------------------------------------------------------
// Networking vars
// ----------------------------------------------------------------------

// Parse existing VNet Resource ID if provided
var varVnetIdSegments = empty(existingVnetResourceId) ? [''] : split(existingVnetResourceId, '/')
var varExistingVnetSubscriptionId = length(varVnetIdSegments) >= 3 ? varVnetIdSegments[2] : subscription().subscriptionId
var varExistingVnetResourceGroupName = length(varVnetIdSegments) >= 5 ? varVnetIdSegments[4] : resourceGroup().name
var varExistingVnetName = length(varVnetIdSegments) >= 9 ? varVnetIdSegments[8] : ''

var virtualNetworkResourceId = _networkIsolation ? (useExistingVNet ? existingVnetResourceId : virtualNetwork!.outputs.resourceId) : ''

#disable-next-line BCP318
var _peSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${peSubnetName}' : ''
#disable-next-line BCP318
var _caEnvSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${acaEnvironmentSubnetName}' : ''
#disable-next-line BCP318
var _jumpbxSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${jumpboxSubnetName}' : ''
#disable-next-line BCP318
var _agentSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${agentSubnetName}' : ''

var _peLocation = !empty(privateEndpointLocation) ? privateEndpointLocation : location
var _defaultPeResourceGroupName = useExistingVNet && !sideBySideDeploy ? varExistingVnetResourceGroupName : resourceGroup().name
var _peResourceGroupName = !empty(privateEndpointResourceGroupName) ? privateEndpointResourceGroupName : _defaultPeResourceGroupName

// ----------------------------------------------------------------------
// VM vars
// ----------------------------------------------------------------------

var _vmBaseName = !empty(vmName) ? vmName : 'testvm${resourceToken}'
var _vmName = substring(_vmBaseName, 0, 15)
var _vmUserName = !empty(vmUserName) ? vmUserName : 'testvmuser'

// ----------------------------------------------------------------------
// Container App vars
// ----------------------------------------------------------------------

var _containerAppsKeyVaultKeysTemp =  [
  for app in containerAppsList: {
    name: '${app.canonical_name}_APIKEY'
    value: resourceToken
    contentType: 'string'
  }
]
var _containerAppsKeyVaultKeys = _useCAppAPIKey ? _containerAppsKeyVaultKeysTemp : []

// ----------------------------------------------------------------------
// // Feature-flagging vars 
// ----------------------------------------------------------------------
var _useUAI         = empty(string(useUAI)) ? false : bool(useUAI)
var _useCAppAPIKey  = empty(string(useCAppAPIKey))? false : bool(useCAppAPIKey)

//////////////////////////////////////////////////////////////////////////
// RESOURCES
//////////////////////////////////////////////////////////////////////////

// Security
///////////////////////////////////////////////////////////////////////////

// Network Watcher
// Note: Automatically provisioned when network isolation is enabled (VNet deployment)

// Azure Defender for Cloud
// Note: By default, free tier (foundational recommendations) is enabled at the subscription level.
//       To enable its advanced threat protection features, Defender plans must be explicitly configured
//       using the Microsoft.Security/pricings resource (e.g., for Storage, Key Vault, App Services).

// Purview Compliance Manager
// Note: Not applicable, it's part of Microsoft 365 Compliance Center, not Azure Resource Manager.

// Networking
///////////////////////////////////////////////////////////////////////////

// Bastion NSG — restricts inbound 443 to trusted IPs only
module bastionNsg 'modules/networking/bastion-nsg.bicep' = if (deployVM && _networkIsolation && deployNsgs) {
  name: 'bastionNsgDeployment'
  params: {
    name: 'nsg-${vnetName}-${azureBastionSubnetName}'
    location: location
    bastionAllowedSourceIPs: bastionAllowedSourceIPs
  }
}

// Firewall FQDN allowlist for essential outbound connectivity
// Essential (shared across subnets, source = '*'): auth, container registry mirror, GitHub
var _firewallEssentialAuthFqdns = [
  #disable-next-line no-hardcoded-env-urls
  'login.microsoftonline.com'
  'login.windows.net'
  #disable-next-line no-hardcoded-env-urls
  'management.azure.com'
  'graph.microsoft.com'
  '*.applicationinsights.azure.com'
]
var _firewallEssentialContainerFqdns = ['mcr.microsoft.com', '*.data.mcr.microsoft.com']
var _firewallEssentialGitHubFqdns = [
  'github.com'
  '*.github.com'
  'raw.githubusercontent.com'
  'codeload.github.com'
  'objects.githubusercontent.com'
  '*.githubusercontent.com'
]

// Jumpbox-only FQDNs — scoped to jumpboxSubnetPrefix so ACA/agent subnets do not
// inherit developer-tooling egress. Split into purpose-labeled sets so consumers can
// audit which tool requires which endpoint.
// Docker / Docker Hub FQDNs intentionally removed — image builds run in the ACR
// Tasks agent pool (see deployAcrTaskAgentPool) and the Windows Server jumpbox
// cannot build Linux images with BuildKit anyway.
var _firewallVmBootstrapFqdns = [
  'community.chocolatey.org'
  'packages.chocolatey.org'
  '*.chocolatey.org'
  'api.nuget.org'
  'www.nuget.org'
  'dist.nuget.org'
  '*.nuget.org'
  'download.visualstudio.microsoft.com'
  '*.visualstudio.microsoft.com'
  'download.microsoft.com'
  '*.download.microsoft.com'
  'aka.ms'
  'go.microsoft.com'
  #disable-next-line no-hardcoded-env-urls
  '*.core.windows.net'
  '*.azureedge.net'
]
#disable-next-line no-hardcoded-env-urls
var _firewallDevRuntimeFqdns = [
  'www.python.org'
  '*.python.org'
  'pypi.org'
  '*.pypi.org'
  'files.pythonhosted.org'
  '*.pythonhosted.org'
  'registry.npmjs.org'
  '*.npmjs.org'
]
#disable-next-line no-hardcoded-env-urls
var _firewallEditorFqdns = [
  'update.code.visualstudio.com'
  '*.vo.msecnd.net'
  '*.vscode-cdn.net'
]

// ACR Tasks agent-pool FQDNs — scoped to devopsBuildAgentsSubnetPrefix. Only
// populated when the agent pool is actually deployed.
var _deployAcrTaskAgentPool = deployContainerRegistry && _networkIsolation && deployAcrTaskAgentPool
var _firewallAcrTaskFqdns = _deployAcrTaskAgentPool ? [
  '*.azurecr.io'
  '*.data.azurecr.io'
] : []

// Route Table for egress traffic control through Azure Firewall
resource routeTable 'Microsoft.Network/routeTables@2024-07-01' = if (_networkIsolation) {
  name: '${const.abbrs.networking.routeTable}${resourceToken}'
  location: location
  tags: _tags
  properties: {
    disableBgpRoutePropagation: true
  }
}

// Base subnets that are always included
var baseSubnets = [
      {
        name: agentSubnetName
        addressPrefix: agentSubnetPrefix 
        delegation: 'Microsoft.app/environments'
        routeTableResourceId: routeTable.id
        serviceEndpoints: [
          'Microsoft.CognitiveServices'
        ]
      }
      {
        name: peSubnetName
        addressPrefix: peSubnetPrefix 
        routeTableResourceId: routeTable.id
        serviceEndpoints: [
          'Microsoft.AzureCosmosDB'
        ]        
        delegation: ''
      }
      {
        name: gatewaySubnetName
        addressPrefix: gatewaySubnetPrefix 
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: azureBastionSubnetName
        addressPrefix: azureBastionSubnetPrefix
        #disable-next-line BCP318
        networkSecurityGroupResourceId: (deployVM && _networkIsolation && deployNsgs) ? bastionNsg!.outputs.id : ''
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: azureFirewallSubnetName
        addressPrefix: azureFirewallSubnetPrefix 
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: azureAppGatewaySubnetName
        addressPrefix: azureAppGatewaySubnetPrefix  
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: jumpboxSubnetName
        addressPrefix: jumpboxSubnetPrefix 
        natGatewayResourceId: natGateway.id
        routeTableResourceId: routeTable.id
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: acaEnvironmentSubnetName
        addressPrefix: acaEnvironmentSubnetPrefix  
        delegation: 'Microsoft.app/environments'
        routeTableResourceId: routeTable.id
        serviceEndpoints: [
          'Microsoft.AzureCosmosDB'
        ]
      }
      {
        name: devopsBuildAgentsSubnetName
        addressPrefix: devopsBuildAgentsSubnetPrefix 
        routeTableResourceId: routeTable.id
        delegation: ''
        serviceEndpoints : []
      }
]

var subnets = baseSubnets

module virtualNetworkSubnets 'modules/networking/subnets.bicep' = if (_networkIsolation && useExistingVNet && deploySubnets) {
  name: 'virtualNetworkSubnetsDeployment'
  params: {
    vnetName: useExistingVNet ? varExistingVnetName : vnetName
    location: location
    resourceGroupName: useExistingVNet ? varExistingVnetResourceGroupName : resourceGroup().name
    subscriptionId: useExistingVNet ? varExistingVnetSubscriptionId : subscription().subscriptionId
    tags: _tags
    addressPrefixes: vnetAddressPrefixes
    subnets: subnets
    deploySubnets : deploySubnets
    deployNsgs: deployNsgs
    useExistingVNet: useExistingVNet
    virtualNetworkResourceId: virtualNetworkResourceId
  }
}

// VNet
// Note on IP address sizing: https://learn.microsoft.com/en-us/azure/ai-foundry/agents/how-to/virtual-networks#known-limitations
module virtualNetwork 'br/public:avm/res/network/virtual-network:0.7.0' = if (_networkIsolation && !useExistingVNet) {
  name: 'virtualNetworkDeployment'
  params: {
    // VNet sized /16 to fit all subnets
    addressPrefixes: vnetAddressPrefixes
    name: vnetName
    location: location

    tags: _tags
    subnets: subnets
  }
}

// Bastion Host
module testVmBastionHost 'br/public:avm/res/network/bastion-host:0.8.0' = if (deployVM && networkIsolation) {
  name: 'bastionHost'
  params: {
    // Bastion host name
    name: '${const.abbrs.security.bastion}testvm-${resourceToken}'
    #disable-next-line BCP318
    virtualNetworkResourceId: virtualNetworkResourceId
    location: location
    skuName: 'Standard'
    tags: _tags
    availabilityZones: useZoneRedundancy ? [1, 2, 3] : []

    // Configuration for the Public IP that the module will create
    publicIPAddressObject: {
      // Name for the Public IP resource
      name: '${const.abbrs.networking.publicIPAddress}bastion-${resourceToken}'
      publicIPAllocationMethod: 'Static'
      skuName: 'Standard'
      skuTier: 'Regional'
      availabilityZones: useZoneRedundancy ? [1, 2, 3] : []
      tags: _tags
    }
  }
  dependsOn: [
    #disable-next-line BCP321
    !useExistingVNet ? virtualNetwork : null
    #disable-next-line BCP321
    useExistingVNet ? virtualNetworkSubnets : null
  ]
}

// Azure Firewall for egress traffic control
///////////////////////////////////////////////////////////////////////////

resource firewallPublicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = if (deployAzureFirewall && _networkIsolation) {
  name: '${const.abbrs.networking.publicIPAddress}${const.abbrs.networking.firewall}${resourceToken}'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
  tags: _tags
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2024-07-01' = if (deployAzureFirewall && _networkIsolation) {
  name: '${const.abbrs.networking.firewallPolicy}${resourceToken}'
  location: location
  tags: _tags
  properties: {
    sku: {
      tier: 'Standard'
    }
    threatIntelMode: 'Alert'
  }
}

resource firewallPolicyDefaultRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-07-01' = if (deployAzureFirewall && _networkIsolation) {
  parent: firewallPolicy
  name: 'DefaultRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AllowEssentialOutbound'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'AllowMicrosoftContainerRegistry'
            protocols: [
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: _firewallEssentialContainerFqdns
            sourceAddresses: ['*']
          }
          {
            ruleType: 'ApplicationRule'
            name: 'AllowEntraIdAuth'
            protocols: [
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: _firewallEssentialAuthFqdns
            sourceAddresses: ['*']
          }
          {
            ruleType: 'ApplicationRule'
            name: 'AllowGitHub'
            protocols: [
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: _firewallEssentialGitHubFqdns
            sourceAddresses: ['*']
          }
          {
            ruleType: 'ApplicationRule'
            name: 'AllowJumpboxBootstrap'
            protocols: [
              { protocolType: 'Https', port: 443 }
              { protocolType: 'Http', port: 80 }
            ]
            targetFqdns: extendFirewallForJumpboxBootstrap ? _firewallVmBootstrapFqdns : []
            sourceAddresses: [jumpboxSubnetPrefix]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'AllowJumpboxDevRuntimes'
            protocols: [
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: extendFirewallForJumpboxBootstrap ? _firewallDevRuntimeFqdns : []
            sourceAddresses: [jumpboxSubnetPrefix]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'AllowJumpboxEditors'
            protocols: [
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: extendFirewallForJumpboxBootstrap ? _firewallEditorFqdns : []
            sourceAddresses: [jumpboxSubnetPrefix]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'AllowAcrTasks'
            protocols: [
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: _firewallAcrTaskFqdns
            sourceAddresses: [devopsBuildAgentsSubnetPrefix]
          }
        ]
      }
    ]
  }
}

#disable-next-line BCP318
var _firewallSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${azureFirewallSubnetName}' : ''

resource azureFirewall 'Microsoft.Network/azureFirewalls@2024-07-01' = if (deployAzureFirewall && _networkIsolation) {
  name: '${const.abbrs.networking.firewall}${resourceToken}'
  location: location
  tags: _tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          publicIPAddress: {
            id: firewallPublicIp.id
          }
          subnet: {
            id: _firewallSubnetId
          }
        }
      }
    ]
    firewallPolicy: {
      id: firewallPolicy.id
    }
  }
  dependsOn: [
    #disable-next-line BCP321
    !useExistingVNet ? virtualNetwork : null
    #disable-next-line BCP321
    useExistingVNet ? virtualNetworkSubnets : null
  ]
}

// Default route through Azure Firewall
resource defaultRoute 'Microsoft.Network/routeTables/routes@2024-07-01' = if (deployAzureFirewall && _networkIsolation) {
  parent: routeTable
  name: 'default-to-firewall'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: azureFirewall!.properties.ipConfigurations[0].properties.privateIPAddress
  }
}

// Azure Firewall diagnostics to Log Analytics
resource firewallDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployAzureFirewall && _networkIsolation && deployLogAnalytics) {
  name: 'fw-diagnostics'
  scope: azureFirewall
  properties: {
    #disable-next-line BCP318
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

//Test VM User Managed Identity
resource testVmUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (_useUAI) {
  name: '${const.abbrs.security.managedIdentity}${_vmName}'
  location: location
}

// Test VM
module testVm 'br/public:avm/res/compute/virtual-machine:0.15.0' = if (deployVM && _networkIsolation) {
  name: 'testVmDeployment'
  params: {
    name: _vmName
    location: location
    adminUsername: _vmUserName
    adminPassword: vmAdminPassword
    managedIdentities: {
      systemAssigned: _useUAI ? false : true
      #disable-next-line BCP318
      userAssignedResourceIds: _useUAI ? [testVmUAI.id] : []
    }
    imageReference: {
      publisher: vmImagePublisher
      offer:     vmImageOffer
      sku:       vmImageSku
      version:   vmImageVersion
    }
    encryptionAtHost: false 
    vmSize: vmSize
    osDisk: {
      caching: 'ReadWrite'
      diskSizeGB: 250
      managedDisk: {
        storageAccountType: 'Standard_LRS'
      }
      
    }
    osType: 'Windows'
    zone: 0
    nicConfigurations: [
      {
        nicSuffix: '-nic-01'
        ipConfigurations: [
          {
            name: 'ipconfig01'
            #disable-next-line BCP318
            subnetResourceId: _jumpbxSubnetId
          }
        ]
      }
    ]
  }
  dependsOn: [
    testVmBastionHost
    #disable-next-line BCP321
    !useExistingVNet ? virtualNetwork : null
    #disable-next-line BCP321
    useExistingVNet ? virtualNetworkSubnets : null
  ]
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = if (deployVM && _networkIsolation) {
  name: '${const.abbrs.networking.publicIPAddress}${const.abbrs.networking.natGateway}${resourceToken}'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 30
    dnsSettings: {
      domainNameLabel: '${const.abbrs.networking.publicIPAddress}${const.abbrs.networking.natGateway}${resourceToken}'
    }
  }
  tags: _tags
}

#disable-next-line BCP081
resource natGateway 'Microsoft.Network/natGateways@2024-10-01' = if (deployVM && _networkIsolation) {
  name: '${const.abbrs.networking.natGateway}${resourceToken}'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// TestVM role assignments (consolidated into a single array-driven module call
// to keep the compiled ARM template under the 4 MB deployment limit).
// ---------------------------------------------------------------------------
var _testVmPrincipalId = (deployVM && _networkIsolation)
  #disable-next-line BCP318
  ? (_useUAI ? testVmUAI.properties.principalId : testVm.outputs.systemAssignedMIPrincipalId!)
  : ''

var _testVmRoles = (deployVM && _networkIsolation) ? concat(
  (deployAppConfig && deployContainerRegistry) ? [
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ContainerAppsContributor.guid)
      principalId: _testVmPrincipalId
      resourceId: ''
      principalType: 'ServicePrincipal'
    }
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ManagedIdentityOperator.guid)
      principalId: _testVmPrincipalId
      resourceId: ''
      principalType: 'ServicePrincipal'
    }
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ContainerRegistryRepositoryWriter.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: 'ServicePrincipal'
    }
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ContainerRegistryContributorDataAccessConfigurationAdministrator.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: 'ServicePrincipal'
    }
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ContainerRegistryTasksContributor.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployAppConfig ? [
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AppConfigurationDataOwner.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: appConfig.id
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployContainerRegistry ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AcrPush.guid)
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployKeyVault ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.KeyVaultContributor.guid)
      #disable-next-line BCP318
      resourceId: keyVault.id
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.KeyVaultSecretsOfficer.guid)
      #disable-next-line BCP318
      resourceId: keyVault.id
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deploySearchService ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.SearchServiceContributor.guid)
      #disable-next-line BCP318
      resourceId: searchService.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.SearchIndexDataContributor.guid)
      #disable-next-line BCP318
      resourceId: searchService.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployAiFoundry ? [
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesContributor.guid)
      principalId: _testVmPrincipalId
      resourceId: aiFoundryAccountResourceId
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesOpenAIUser.guid)
      resourceId: aiFoundryAccountResourceId
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployStorageAccount ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.StorageBlobDataContributor.guid)
      #disable-next-line BCP318
      resourceId: storageAccount.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
  ] : []
) : []

module assignTestVmRoles 'modules/security/resource-role-assignment.bicep' = if (deployVM && _networkIsolation) {
  name: 'assignTestVmRoles'
  params: {
    name: 'assignTestVmRoles'
    roleAssignments: _testVmRoles
  }
}

// Cosmos DB Account - Cosmos DB Built-in Data Contributor -> TestVm
module assignCosmosDBCosmosDbBuiltInDataContributorTestVm 'modules/security/cosmos-data-plane-role-assignment.bicep' = if (deployVM && deployCosmosDb && _networkIsolation) {
  name: 'assignCosmosDBCosmosDbBuiltInDataContributorTestVm'
  params: {
    #disable-next-line BCP318
    cosmosDbAccountName: cosmosDBAccount.outputs.name
    principalId: _testVmPrincipalId
    roleDefinitionGuid: const.roles.CosmosDBBuiltInDataContributor.guid
    scopePath: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${dbAccountName}/dbs/${dbDatabaseName}'
  }
}

var _fileUris = [
  'https://raw.githubusercontent.com/Azure/bicep-ptn-aiml-landing-zone/refs/tags/${_manifest.ailz_tag}/install.ps1'
]

resource cse 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = if (deployVM && deploySoftware && _networkIsolation) {
  name: '${_vmName}/cse'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    forceUpdateTag: deployment().name
    settings: {
      fileUris: _fileUris
      commandToExecute: 'powershell.exe -ExecutionPolicy Unrestricted -File install.ps1 -release ${_manifest.ailz_tag} -UseUAI ${_useUAI} -ResourceToken ${resourceToken} -AzureTenantId ${subscription().tenantId} -AzureLocation ${location} -AzureSubscriptionId ${subscription().subscriptionId} -AzureResourceGroupName ${resourceGroup().name} -AzdEnvName ${environmentName}'
    }
    protectedSettings: {
      
    }
  }
  dependsOn: [
    testVm
    appConfigPopulate
    assignTestVmRoles
    assignCosmosDBCosmosDbBuiltInDataContributorTestVm
    azureFirewall
    firewallPolicyDefaultRuleCollectionGroup
  ]
}

// Private DNS Zones (consolidated into a single for-loop module to keep compiled ARM template under 4 MB).
///////////////////////////////////////////////////////////////////////////

var _dnsZonesTargetRg = useExistingVNet && !sideBySideDeploy ? varExistingVnetResourceGroupName : resourceGroup().name
var _dnsZonesLinkSuffix = useExistingVNet ? '-byon' : ''

var _dnsZonesList = _deployPrivateDnsZones ? concat(
  [
    { dnsName: 'privatelink.cognitiveservices.azure.com', virtualNetworkLinkName: '${vnetName}-cogsvcs-link${_dnsZonesLinkSuffix}' }
    { dnsName: 'privatelink.openai.azure.com',            virtualNetworkLinkName: '${vnetName}-openai-link${_dnsZonesLinkSuffix}' }
    { dnsName: 'privatelink.services.ai.azure.com',       virtualNetworkLinkName: '${vnetName}-aiservices-link${_dnsZonesLinkSuffix}' }
    { dnsName: 'privatelink.search.windows.net',          virtualNetworkLinkName: '${vnetName}-search-std-link${_dnsZonesLinkSuffix}' }
    { dnsName: 'privatelink.documents.azure.com',         virtualNetworkLinkName: '${vnetName}-cosmos-std-link${_dnsZonesLinkSuffix}' }
    { dnsName: 'privatelink.blob.${environment().suffixes.storage}', virtualNetworkLinkName: '${vnetName}-blob-std-link${_dnsZonesLinkSuffix}' }
    { dnsName: 'privatelink.vaultcore.azure.net',         virtualNetworkLinkName: '${vnetName}-kv-link${_dnsZonesLinkSuffix}' }
    { dnsName: 'privatelink.azconfig.io',                 virtualNetworkLinkName: '${vnetName}-appcfg-link${_dnsZonesLinkSuffix}' }
  ],
  deployContainerApps ? [
    { dnsName: 'privatelink.${location}.azurecontainerapps.io', virtualNetworkLinkName: '${vnetName}-containerapps-link${_dnsZonesLinkSuffix}' }
  ] : [],
  deployContainerRegistry ? [
    { dnsName: 'privatelink.${acrDnsSuffix}',                         virtualNetworkLinkName: '${vnetName}-containerregistry-link${_dnsZonesLinkSuffix}' }
  ] : [],
  _deployAmpls ? [
    { dnsName: 'privatelink.applicationinsights.io',      virtualNetworkLinkName: '${vnetName}-appi-link${_dnsZonesLinkSuffix}' }
    { dnsName: 'privatelink.monitor.azure.com',                       virtualNetworkLinkName: '${vnetName}-azure-monitor-link${_dnsZonesLinkSuffix}' }
    { dnsName: 'privatelink.oms.opinsights.azure.com',                virtualNetworkLinkName: '${vnetName}-oms-opinsights-link${_dnsZonesLinkSuffix}' }
    { dnsName: 'privatelink.ods.opinsights.azure.com',                virtualNetworkLinkName: '${vnetName}-ods-opinsights-link${_dnsZonesLinkSuffix}' }
    { dnsName: 'privatelink.agentsvc.azure.automation.net',           virtualNetworkLinkName: '${vnetName}-azure-automation-link${_dnsZonesLinkSuffix}' }
  ] : []
) : []

module privateDnsZones 'modules/networking/private-dns-zones.bicep' = if (_deployPrivateDnsZones) {
  name: 'dep-private-dns-zones'
  params: {
    zones: _dnsZonesList
    tags: _tags
    resourceGroupName: _dnsZonesTargetRg
    virtualNetworkResourceId: virtualNetworkResourceId
  }
  dependsOn: [
    virtualNetwork!
    virtualNetworkSubnets!
  ]
}

// Private Endpoints (consolidated into a single for-loop module with @batchSize(1) to keep compiled ARM template under 4 MB while preserving serialized PE creation).
///////////////////////////////////////////////////////////////////////////

var _peDnsZoneGroupBlob = policyManagedPrivateDns ? {} : {
  name: 'blobDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'blobARecord', privateDnsZoneResourceId: _dnsZoneBlobId }
  ]
}
var _peDnsZoneGroupCosmos = policyManagedPrivateDns ? {} : {
  name: 'cosmosDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'cosmosARecord', privateDnsZoneResourceId: _dnsZoneCosmosId }
  ]
}
var _peDnsZoneGroupSearch = policyManagedPrivateDns ? {} : {
  name: 'searchDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'searchARecord', privateDnsZoneResourceId: _dnsZoneSearchId }
  ]
}
var _peDnsZoneGroupKeyVault = policyManagedPrivateDns ? {} : {
  name: 'kvDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'kvARecord', privateDnsZoneResourceId: _dnsZoneKeyVaultId }
  ]
}
var _peDnsZoneGroupAppConfig = policyManagedPrivateDns ? {} : {
  name: 'appConfigDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'appConfigARecord', privateDnsZoneResourceId: _dnsZoneAppConfigId }
  ]
}
var _peDnsZoneGroupContainerApps = policyManagedPrivateDns ? {} : {
  name: 'ccaDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'ccaARecord', privateDnsZoneResourceId: _dnsZoneContainerAppsId }
  ]
}
var _peDnsZoneGroupAcr = policyManagedPrivateDns ? {} : {
  name: 'acrDnsZoneGroup'
  privateDnsZoneGroupConfigs: [
    { name: 'acr', privateDnsZoneResourceId: _dnsZoneAcrId }
  ]
}

var _peList = concat(
  (_networkIsolation && deployStorageAccount) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${storageAccountName}'
      privateLinkServiceConnections: [
        {
          name: 'blobConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: storageAccount.outputs.resourceId, groupIds: ['blob'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupBlob
    }
  ] : [],
  (_networkIsolation && deployCosmosDb) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${dbAccountName}'
      privateLinkServiceConnections: [
        {
          name: 'cosmosConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: cosmosDBAccount.outputs.resourceId, groupIds: ['Sql'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupCosmos
    }
  ] : [],
  (_networkIsolation && deploySearchService) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${searchServiceName}'
      privateLinkServiceConnections: [
        {
          name: 'searchConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: searchService.outputs.resourceId, groupIds: ['searchService'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupSearch
    }
  ] : [],
  (_networkIsolation && deployAiFoundry && aiSearchResourceId == '') ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${aiFoundrySearchServiceName}'
      privateLinkServiceConnections: [
        {
          name: 'searchAIFConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: searchServiceAIFoundry.outputs.resourceId, groupIds: ['searchService'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupSearch
    }
  ] : [],
  (_networkIsolation && deployKeyVault) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${keyVaultName}'
      privateLinkServiceConnections: [
        {
          name: 'kvConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: keyVault.id, groupIds: ['vault'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupKeyVault
    }
  ] : [],
  (_networkIsolation && deployAppConfig) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${appConfigName}'
      privateLinkServiceConnections: [
        {
          name: 'appConfigConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: appConfig.id, groupIds: ['configurationStores'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupAppConfig
    }
  ] : [],
  (_networkIsolation && deployContainerEnv) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${containerEnvName}'
      privateLinkServiceConnections: [
        {
          name: 'ccaConnection'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: containerEnv.id, groupIds: ['managedEnvironments'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupContainerApps
    }
  ] : [],
  (_networkIsolation && deployContainerRegistry) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${containerRegistryName}'
      privateLinkServiceConnections: [
        {
          name: '${containerRegistryName}-registry-connection'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: containerRegistry.id, groupIds: ['registry'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroupAcr
    }
  ] : []
)

module privateEndpoints 'modules/networking/private-endpoints.bicep' = if (_networkIsolation) {
  name: 'dep-private-endpoints'
  params: {
    endpoints: _peList
    location: _peLocation
    resourceGroupName: _peResourceGroupName
    tags: _tags
    subnetResourceId: _peSubnetId
  }
  dependsOn: [
    privateDnsZones
    storageAccount!
    cosmosDBAccount!
    searchService!
    searchServiceAIFoundry!
    keyVault!
    appConfig!
    containerEnv!
    containerRegistry!
  ]
}


// Azure Application Gateway
//////////////////////////////////////////////////////////////////////////
// Coming Soon

// Azure Firewall
//////////////////////////////////////////////////////////////////////////
// Coming Soon

// AI Foundry Standard Setup
//////////////////////////////////////////////////////////////////////////


var _dnsZonesSubscriptionId = useExistingVNet && !sideBySideDeploy ? varExistingVnetSubscriptionId : subscription().subscriptionId
var _dnsZonesResourceGroupName = useExistingVNet && !sideBySideDeploy ? varExistingVnetResourceGroupName : resourceGroup().name
var _dnsZoneCogSvcsId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.cognitiveservices.azure.com')
var _dnsZoneOpenAiId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.openai.azure.com')
var _dnsZoneAiServicesId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.services.ai.azure.com')
var _dnsZoneSearchId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.search.windows.net')
var _dnsZoneCosmosId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.documents.azure.com')
var _dnsZoneBlobId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.blob.${environment().suffixes.storage}')
var _dnsZoneKeyVaultId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.vaultcore.azure.net')
var _dnsZoneAppConfigId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.azconfig.io')
var _dnsZoneContainerAppsId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.${location}.azurecontainerapps.io')
var _dnsZoneAcrId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.${acrDnsSuffix}')
var _dnsZoneAzureMonitorId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.monitor.azure.com')
var _dnsZoneOmsOpsInsightsId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.oms.opinsights.azure.com')
var _dnsZoneOdsOpsInsightsId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.ods.opinsights.azure.com')
var _dnsZoneAzureAutomationId = resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.agentsvc.azure.automation.net')

//AI Foundry Account User Managed Identity
resource aiFoundryUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (_useUAI) {
  name: '${const.abbrs.security.managedIdentity}${aiFoundryAccountName}'
  location: location
}

// 16.0 Pre-create AI Services account to avoid PE race condition in AVM module.
// The AVM creates the CogSvc account and its PE in the same deployment, causing
// the PE to fail with AccountProvisioningStateInvalid when the account is still
// in "Accepted" state. By pre-creating the account here, the AVM's subsequent PUT
// is an idempotent update on an already-provisioned resource, so the PE succeeds.
resource aiServicesAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = if (deployAiFoundry) {
  name: aiFoundryAccountName
  location: location
  tags: deploymentTags
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: aiFoundryAccountName
    disableLocalAuth: true
    publicNetworkAccess: _networkIsolation ? 'Disabled' : 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Pre-create AI Foundry Storage Account with a region-safe SKU.
// The AVM ai-foundry module (<= 0.6.0) creates its Storage Account with the
// provider default `Standard_GRS`, which is not offered in every region
// (e.g. Poland Central -> RedundancyConfigurationNotAvailableInRegion).
// Creating it ourselves and passing the resource ID as `existingResourceId`
// lets us honor an explicit SKU (default `Standard_LRS`).
module aiFoundryStorageAccount 'modules/ai-foundry/storage-account.bicep' = if (deployAiFoundry && aiFoundryStorageAccountResourceId == '') {
  name: 'aiFoundryStorage-${resourceToken}-deployment'
  params: {
    name: aiFoundryStorageAccountName
    location: location
    tags: _tags
    skuName: aiFoundryStorageSku
    disablePublicNetworkAccess: _networkIsolation
    privateEndpointSubnetResourceId: _networkIsolation ? _peSubnetId : ''
    blobPrivateDnsZoneResourceId: _networkIsolation ? _dnsZoneBlobId : ''
  }
  dependsOn: [
    #disable-next-line BCP321
    (_networkIsolation && !useExistingVNet) ? virtualNetwork : null
    #disable-next-line BCP321
    (_networkIsolation && useExistingVNet && deploySubnets) ? virtualNetworkSubnets : null
    #disable-next-line BCP321
    _networkIsolation ? privateDnsZones : null
  ]
}

// 16.1 AI Foundry Configuration
module aiFoundry 'modules/ai-foundry/main.bicep' = if (deployAiFoundry) {
  name: '${aiFoundryAccountName}-${resourceToken}-deployment'
  params: {
    // Required
    baseName: substring(resourceToken, 0, 10)

    includeAssociatedResources: true
    location: location
    tags: deploymentTags

    privateEndpointSubnetResourceId: varPeSubnetId

    aiFoundryConfiguration: {
      accountName: aiFoundryAccountName
      allowProjectManagement: deployAfProject
      createCapabilityHosts: deployAAfAgentSvc
      location: location

      networking: varAfNetworkingOverride

      project: deployAfProject
        ? {
            name: 'aifoundry-default-project'
            displayName: 'Default AI Foundry Project.'
            description: 'This is the default project for AI Foundry.'
          }
        : null
    }

    aiModelDeployments: !empty(modelDeploymentList)
      ? modelDeploymentList
      : [
          {
            model: {
              format: 'OpenAI'
              name: 'gpt-5-nano'
              version: '2025-08-07'
            }
            name: 'gpt-5-nano'
            sku: {
              name: 'GlobalStandard'
              capacity: 40
            }
          }
          {
            model: {
              format: 'OpenAI'
              name: 'text-embedding-3-large'
              version: '1'
            }
            name: 'text-embedding-3-large'
            sku: {
              name: 'Standard'
              capacity: 10
            }
          }
        ]

    aiSearchConfiguration: varAfAiSearchCfgComplete
    cosmosDbConfiguration: varAfCosmosCfgComplete
    keyVaultConfiguration: varAfKVCfgComplete
    storageAccountConfiguration: varAfStorageCfgComplete

    enableTelemetry: true
  }
  dependsOn: [
    #disable-next-line BCP321
    (aiSearchResourceId == '') ? searchServiceAIFoundry : null
    #disable-next-line BCP321
    (_networkIsolation && !useExistingVNet) ? virtualNetwork : null
    #disable-next-line BCP321
    (_networkIsolation && useExistingVNet && deploySubnets) ? virtualNetworkSubnets : null
    #disable-next-line BCP321
    _networkIsolation ? privateDnsZones : null
    aiServicesAccount
    #disable-next-line BCP321
    (aiFoundryStorageAccountResourceId == '') ? aiFoundryStorageAccount : null
  ]
}


var varPeSubnetId = empty(existingVnetResourceId!)
  ? '${virtualNetworkResourceId}/subnets/pe-subnet'
  : '${existingVnetResourceId!}/subnets/pe-subnet'

var varAfNetworkingOverride = _networkIsolation ? {
  cognitiveServicesPrivateDnsZoneResourceId: _dnsZoneCogSvcsId
  openAiPrivateDnsZoneResourceId: _dnsZoneOpenAiId
  aiServicesPrivateDnsZoneResourceId: _dnsZoneAiServicesId
  agentServiceSubnetResourceId: deployAiFoundrySubnet ? _agentSubnetId : null
} : null

var varAfAiSearchCfgComplete = {
  existingResourceId: aiSearchResourceId != ''
    ? aiSearchResourceId
    : deployAiFoundry ? searchServiceAIFoundry.outputs.resourceId : null
  name: aiFoundrySearchServiceName
  privateDnsZoneResourceId: _networkIsolation ? _dnsZoneSearchId : null
  roleAssignments: []
}

var varAfCosmosCfgComplete = {
  existingResourceId: aiFoundryCosmosDBAccountResourceId != '' ? aiFoundryCosmosDBAccountResourceId : null
  name: aiFoundryCosmosDbName
  privateDnsZoneResourceId: _networkIsolation ? _dnsZoneCosmosId : null
  roleAssignments: []
}

var varAfKVCfgComplete = {
  existingResourceId: keyVaultResourceId != '' ? keyVaultResourceId : null
  name: '${const.abbrs.security.keyVault}ai-${resourceToken}'
  privateDnsZoneResourceId: _networkIsolation ? _dnsZoneKeyVaultId : null
  roleAssignments: []
}

// NOTE: The AVM ai-foundry `storageAccountConfigurationType` does not expose
// a `skuName` field. We instead pre-create the Storage Account in
// `aiFoundryStorageAccount` above with the requested SKU and pass its
// resource ID here as `existingResourceId`, which causes the AVM to skip
// internal storage creation (and its default `Standard_GRS`).
var varAfStorageCfgComplete = {
  existingResourceId: aiFoundryStorageAccountResourceId != ''
    ? aiFoundryStorageAccountResourceId
    : (deployAiFoundry ? aiFoundryStorageAccount.outputs.resourceId : null)
  name: aiFoundryStorageAccountName
  blobPrivateDnsZoneResourceId: _networkIsolation ? _dnsZoneBlobId : null
  roleAssignments: []
}

var aiFoundryAccountResourceId = resourceId('Microsoft.CognitiveServices/accounts', aiFoundry!.outputs.aiServicesName)

var aiFoundryProjectResourceId = resourceId(
  'Microsoft.CognitiveServices/accounts/projects', 
  aiFoundry!.outputs.aiServicesName, 
  aiFoundry!.outputs.aiProjectName 
)

var aiFoundryAccountEndpoint = 'https://${aiFoundry!.outputs.aiServicesName}.cognitiveservices.azure.com/'

var aiFoundryProjectEndpoint = 'https://${aiFoundry!.outputs.aiServicesName}.services.ai.azure.com/api/projects/${aiFoundry!.outputs.aiProjectName}'

// Bing Search Connection (optional)
module bingSearchConnection 'modules/bing-search/main.bicep' = if (deployAiFoundry && deployGroundingWithBing) {
  name: 'bingSearchConnection-${resourceToken}'
  params: {
    accountName: aiFoundry!.outputs.aiServicesName
    projectName: aiFoundry!.outputs.aiProjectName
    bingSearchName: bingSearchName
  }
  dependsOn: [
    aiFoundry!
  ]
}

// AI Foundry Connections
//////////////////////////////////////////////////////////////////////////

// Bing Search Connection
module aiFoundryBingConnection 'modules/ai-foundry/connection-bing-search-tool.bicep' = if (deployAiFoundry && deployGroundingWithBing) {
  name: '${bingSearchName}-connection'
  params: {
    account_name: aiFoundry!.outputs.aiServicesName
    project_name: aiFoundry!.outputs.aiProjectName
    bingSearchName: bingSearchName
  }
  dependsOn: [
    aiFoundry!
  ]
}

// AI Search Connection
module aiFoundryConnectionSearch 'modules/ai-foundry/connection-ai-search.bicep' = if (deployAiFoundry && deploySearchService) {
  name: 'connection-ai-search-${resourceToken}'
  params: {
    aiFoundryName: aiFoundry!.outputs.aiServicesName
    aiProjectName: aiFoundry!.outputs.aiProjectName
    connectedResourceName: searchService!.outputs.name
  }
  dependsOn: [
    aiFoundry!
    searchService!
  ]
}

// Application Insights Connection
module aiFoundryConnectionInsights 'modules/ai-foundry/connection-application-insights.bicep' = if (deployAiFoundry && deployAppInsights && deployLogAnalytics) {
  name: 'connection-appinsights-${resourceToken}'
  params: {
    aiFoundryName: aiFoundry!.outputs.aiServicesName
    connectedResourceName: appInsights!.name
  }
  dependsOn: [
    aiFoundry!
    appInsights!
  ]
}

// Storage Account Connection
module aiFoundryConnectionStorage 'modules/ai-foundry/connection-storage-account.bicep' = if (deployAiFoundry && deployStorageAccount) {
  name: 'connection-storage-account-${resourceToken}'
  params: {
    aiFoundryName: aiFoundry!.outputs.aiServicesName
    connectedResourceName: storageAccount!.outputs.name
  }
  dependsOn: [
    aiFoundry!
    storageAccount!
  ]
}

// Application Insights
//////////////////////////////////////////////////////////////////////////
var appInsightsInvalidLocations = ['westcentralus']

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (deployAppInsights && deployLogAnalytics) {
  name: appInsightsName
  location: contains(appInsightsInvalidLocations, location) ? 'eastus' : location
  kind: 'web'
  tags: _tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    DisableIpMasking: false
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

//private link scope
resource privateLinkScope 'microsoft.insights/privatelinkscopes@2021-07-01-preview' = if (_deployAmpls) {
  name: '${const.abbrs.networking.privateLinkScope}${resourceToken}'
  location: 'global'
  properties :{
    accessModeSettings : {
      queryAccessMode : 'Open'
      ingestionAccessMode : 'Open'
    }
  }
  dependsOn: [
    appInsights!
  ]
}

module privateEndpointPrivateLinkScope 'modules/networking/private-endpoint.bicep' = if (_deployAmpls) {
  name: 'privatelink-scope-private-endpoint'
  params: {
    name: '${const.abbrs.networking.privateEndpoint}${const.abbrs.networking.privateLinkScope}${resourceToken}'
    location: _peLocation
    resourceGroupName: _peResourceGroupName
    tags: _tags
    subnetResourceId: _peSubnetId
    privateLinkServiceConnections: [
      {
        name: 'privateLinkScopeConnection'
        properties: {
          privateLinkServiceId: privateLinkScope.id
          groupIds: ['azuremonitor']
        }
      }
    ]
    privateDnsZoneGroup: policyManagedPrivateDns ? {} : {
      name: 'privateLinkDnsZoneGroup'
      privateDnsZoneGroupConfigs: [
        { name: 'azuremonitorARecord', privateDnsZoneResourceId: _dnsZoneAzureMonitorId }
        { name: 'omsinsightsARecord',  privateDnsZoneResourceId: _dnsZoneOmsOpsInsightsId }
        { name: 'odsinsightsARecord',  privateDnsZoneResourceId: _dnsZoneOdsOpsInsightsId }
        { name: 'automationARecord',   privateDnsZoneResourceId: _dnsZoneAzureAutomationId }
      ]
    }
  }
  dependsOn: [
    privateLinkScope!
    privateDnsZones
    privateEndpoints // Serialize PE operations to avoid conflicts
  ]
}

resource privateLinkScopedResources1 'microsoft.insights/privatelinkscopes/scopedresources@2021-07-01-preview' = if (_deployAmpls) {
  name: '${const.abbrs.networking.privateLinkScope}${resourceToken}/${logAnalyticsWorkspaceName}'!
  properties :{
    #disable-next-line BCP318
    linkedResourceId: logAnalytics.id
  }
  dependsOn: [
    privateLinkScope
  ]
}

resource privateLinkScopedResources2 'microsoft.insights/privatelinkscopes/scopedresources@2021-07-01-preview' = if (_deployAmpls) {
  name: '${const.abbrs.networking.privateLinkScope}${resourceToken}/${appInsightsName}'!
  properties :{
    #disable-next-line BCP318
    linkedResourceId: appInsights.id
  }
  dependsOn: [
    privateLinkScope
  ]
}

// Container Resources
//////////////////////////////////////////////////////////////////////////

//Container Apps Env User Managed Identity
resource containerEnvUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (_useUAI && deployContainerEnv) {
  name: '${const.abbrs.security.managedIdentity}${containerEnvName}'
  location: location
}

// Container Apps Environment
resource containerEnv 'Microsoft.App/managedEnvironments@2025-01-01' = if (deployContainerEnv) {
  name: containerEnvName
  location: location
  tags: _tags
  identity: {
    type: _useUAI ? 'UserAssigned' : 'SystemAssigned'
    userAssignedIdentities: _useUAI ? { '${containerEnvUAI.id}': {} } : null
  }
  properties: {
    appLogsConfiguration: {
      destination: null
    }
    appInsightsConfiguration: (deployAppInsights && deployLogAnalytics) ? {
      connectionString: appInsights.properties.ConnectionString
    } : null
    zoneRedundant: useZoneRedundancy
    workloadProfiles: workloadProfiles
    vnetConfiguration: networkIsolation ? {
      infrastructureSubnetId: _caEnvSubnetId
      internal: true
    } : null
  }
  dependsOn: [
    #disable-next-line BCP321
    !useExistingVNet ? virtualNetwork : null
    #disable-next-line BCP321
    useExistingVNet ? virtualNetworkSubnets : null
  ]
}

//Container Registry User Managed Identity
resource containerRegistryUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (_useUAI && deployContainerRegistry) {
  name: '${const.abbrs.security.managedIdentity}${containerRegistryName}'
  location: location
}

// Container Registry
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = if (deployContainerRegistry) {
  name: containerRegistryName
  location: location
  tags: _tags
  sku: {
    name: _networkIsolation ? 'Premium' : 'Basic'
  }
  identity: {
    type: _useUAI ? 'UserAssigned' : 'SystemAssigned'
    userAssignedIdentities: _useUAI ? { '${containerRegistryUAI.id}': {} } : null
  }
  properties: {
    publicNetworkAccess: _networkIsolation ? 'Disabled' : 'Enabled'
    zoneRedundancy: useZoneRedundancy ? 'Enabled' : 'Disabled'
    dataEndpointEnabled: _networkIsolation
    policies: {
      exportPolicy: {
        status: 'enabled'
      }
    }
  }
}

// ACR Task agent pool — enables `az acr build --agent-pool <name>` to run image
// builds inside the VNet when publicNetworkAccess on the registry is Disabled.
// Gated on networkIsolation (Premium SKU) and deployAcrTaskAgentPool.
resource acrTaskAgentPool 'Microsoft.ContainerRegistry/registries/agentPools@2019-06-01-preview' = if (_deployAcrTaskAgentPool) {
  parent: containerRegistry
  name: acrTaskAgentPoolName
  location: location
  tags: _tags
  properties: {
    count: acrTaskAgentPoolCount
    tier: acrTaskAgentPoolTier
    os: 'Linux'
    #disable-next-line BCP318
    virtualNetworkSubnetResourceId: _networkIsolation ? '${virtualNetworkResourceId}/subnets/${devopsBuildAgentsSubnetName}' : ''
  }
}

//Container Apps User Managed Identity
resource containerAppsUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [
  for app in containerAppsList: if (_useUAI && deployContainerApps) {
    name: '${const.abbrs.security.managedIdentity}${const.abbrs.containers.containerApp}${resourceToken}-${app.service_name}'
    location: location
  }
]

// Container Apps
@batchSize(4)
module containerApps 'br/public:avm/res/app/container-app:0.18.1' = [
  for (app, index) in containerAppsList: if (deployContainerApps) {
    name: empty(app.name) ? '${const.abbrs.containers.containerApp}${resourceToken}-${app.service_name}' : app.name
    params: {
      name: empty(app.name) ? '${const.abbrs.containers.containerApp}${resourceToken}-${app.service_name}' : app.name
      location: location
      #disable-next-line BCP318
      environmentResourceId: containerEnv.id
      workloadProfileName: app.profile_name

      ingressExternal: app.external
      ingressTargetPort: int(app.?target_port ?? 8080)
      ingressTransport: 'auto'
      ingressAllowInsecure: false

      dapr: {
        enabled: true
        appId: app.service_name
        appPort: int(app.?target_port ?? 8080)
        appProtocol: 'http'
      }

      managedIdentities: {
        systemAssigned: (_useUAI) ? false : true
        #disable-next-line BCP318
        userAssignedResourceIds: (_useUAI) ? [containerAppsUAI[index].id] : []
      }

      scaleSettings: {
        minReplicas: app.min_replicas
        maxReplicas: app.max_replicas
      }

      containers: [
        {
          name: app.service_name
          image: _containerDummyImageName
          resources: {
            cpu: app.?cpu ?? '0.5'
            memory: app.?memory ?? '1.0Gi'
          }
          env: [
            {
              name: 'APP_CONFIG_ENDPOINT'
              value: 'https://${appConfigName}.azconfig.io'
            }
            {
              name: 'AZURE_TENANT_ID'
              value: subscription().tenantId
            }
            {
              name: 'AZURE_CLIENT_ID'
              #disable-next-line BCP318
              value: _useUAI ? containerAppsUAI[index].properties.clientId : ''
            }
          ]
        }
      ]

      tags: union(_tags, {
        'azd-service-name': app.service_name
      })
    }
    dependsOn: [
      containerEnv!                   
      privateDnsZones
      privateEndpoints
    ]
  }
]

// Cosmos DB Account and Database
//////////////////////////////////////////////////////////////////////////

//Cosmos User Managed Identity
resource cosmosUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (_useUAI) {
  name: '${const.abbrs.security.managedIdentity}${dbAccountName}'
  location: location
}

module cosmosDBAccount 'br/public:avm/res/document-db/database-account:0.15.1' = if (deployCosmosDb) {
  name: 'CosmosDBAccount'
  params: {
    name: dbAccountName
    location: cosmosLocation
    managedIdentities: {
      systemAssigned: _useUAI ? false : true
      #disable-next-line BCP318
      userAssignedResourceIds: _useUAI ? [cosmosUAI.id] : []
    }
    failoverLocations: [
      {
        locationName: cosmosLocation
        failoverPriority: 0
        isZoneRedundant: useZoneRedundancy
      }
    ]
    defaultConsistencyLevel: 'Session'
    capabilitiesToAdd: ['EnableServerless']
    enableAnalyticalStorage: true
    enableFreeTier: false
    networkRestrictions: {
      publicNetworkAccess: _networkIsolation ? 'Disabled' : 'Enabled'
      virtualNetworkRules: _networkIsolation ? [
        {
          subnetResourceId: _peSubnetId
          ignoreMissingVnetServiceEndpoint: true
        }
        {
          subnetResourceId: _caEnvSubnetId
          ignoreMissingVnetServiceEndpoint: true
        }
      ] : []
    }
    tags: _tags
    sqlDatabases: [
      {
        name: dbDatabaseName
        throughput: dbDatabaseThroughput
        containers: [
          for container in databaseContainersList: {
            name: container.name
            paths: [container.partitionKey]
            defaultTtl: -1
            throughput: container.?throughput
            indexingPolicy: container.?indexingPolicy
          }
        ]
      }
    ]
  }
  dependsOn: [
    #disable-next-line BCP321
    (_networkIsolation) ? virtualNetwork : null
  ]
}

// Key Vault
//////////////////////////////////////////////////////////////////////////

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = if (deployKeyVault) {
  name: keyVaultName
  location: location
  tags: _tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: _networkIsolation ? 'Disabled' : 'Enabled'
  }
}

// Provision Container App secrets in Key Vault (only happens when useAPIKeys is true)
resource secret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = [for (config, i) in _containerAppsKeyVaultKeys: {
  parent: keyVault
  name: replace(config.name, '_', '-')
  properties: {
      contentType: config.contentType
      value:  config.value
  }
  tags: {}
}
]

// Log Analytics Workspace
//////////////////////////////////////////////////////////////////////////

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (deployLogAnalytics) {
  name: logAnalyticsWorkspaceName
  location: location
  tags: _tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      disableLocalAuth: false
    }
  }
}

// AI Search
//////////////////////////////////////////////////////////////////////////

//Search Service User Managed Identity
resource searchServiceUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (_useUAI && deploySearchService) {
  name: '${const.abbrs.security.managedIdentity}${searchServiceName}'
  location: _searchServiceLocation
}

module searchService 'br/public:avm/res/search/search-service:0.11.1' = if (deploySearchService) {
  name: 'searchService'
  params: {
    name: searchServiceName
    location: _searchServiceLocation
    publicNetworkAccess: _networkIsolation ? 'Disabled' : 'Enabled'
    tags: _tags

    // SKU & capacity
    // Using 'standard' rather than 'basic' because several regions (eastus2, westus3, etc.)
    // are returning InsufficientResourcesAvailable for the basic SKU capacity pool. Standard
    // has broader capacity availability at ~same cost tier when kept at 1 replica / 1 partition.
    sku: 'standard'
    replicaCount: 1
    partitionCount: 1
    semanticSearch: 'disabled'

    // Identity & Auth
    managedIdentities: {
      systemAssigned: _useUAI ? false : true
      #disable-next-line BCP318
      userAssignedResourceIds: _useUAI ? [searchServiceUAI.id] : []
    }

    disableLocalAuth: false
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
    sharedPrivateLinkResources: _networkIsolation
      ? [
          // {
          //   groupId: 'blob'
          //   #disable-next-line BCP318
          //   privateLinkResourceId: storageAccount.outputs.resourceId
          //   requestMessage: 'Automated link for Storage'
          //   provisioningState: 'Succeeded'
          //   status: 'Approved'
          // }
        ]
      : []
  }
  dependsOn: [
    containerEnv!
    storageAccount!
  ]
}

// Dedicated AI Search service for AI Foundry (separate from the application search).
// Skipped when the consumer brings their own AI Foundry search via `aiSearchResourceId`.
module searchServiceAIFoundry 'br/public:avm/res/search/search-service:0.11.1' = if (deployAiFoundry && aiSearchResourceId == '') {
  name: 'searchServiceAIFoundry'
  params: {
    name: aiFoundrySearchServiceName
    location: _searchServiceLocation
    publicNetworkAccess: _networkIsolation ? 'Disabled' : 'Enabled'
    tags: _tags

    // SKU & capacity (aligned with application search defaults; override for heavier workloads)
    // Using 'standard' SKU for reliable regional capacity availability.
    sku: 'standard'
    replicaCount: 1
    partitionCount: 1
    semanticSearch: 'disabled'

    // Identity & Auth: system-assigned MI (AI Foundry project identity gets data-plane roles via AVM)
    managedIdentities: {
      systemAssigned: true
    }

    disableLocalAuth: false
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
  }
  dependsOn: [
    containerEnv!
    // Serialize creation of the two search services to avoid a rare race
    // condition in the Microsoft.Search resource provider where two parallel
    // PUTs against similarly-named services in the same region/subscription
    // can leave the second name "stuck" in the backend namespace cache,
    // producing subsequent "already exists" / "ServiceNameUnavailable" errors
    // even though the service is not visible in ARM and the name appears
    // available to checkNameAvailability.
    searchService!
  ]
}

// Storage Accounts
//////////////////////////////////////////////////////////////////////////

// Storage Account
module storageAccount 'br/public:avm/res/storage/storage-account:0.26.2' = if (deployStorageAccount) {
  name: 'storageAccountSolution'
  params: {
    name: storageAccountName
    location: location
    publicNetworkAccess: _networkIsolation ? 'Disabled' : 'Enabled'
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    requireInfrastructureEncryption: true
    networkAcls: {
      bypass: 'AzureServices'
      virtualNetworkRules: []
      defaultAction: 'Allow'
    }
    tags: _tags
    blobServices: {
      automaticSnapshotPolicyEnabled: true
      containerDeleteRetentionPolicyDays: 10
      containerDeleteRetentionPolicyEnabled: true
      containers: [
        for container in storageAccountContainersList: {
          name: container.name
          publicAccess: 'None'
        }
      ]
      deleteRetentionPolicyDays: 7
      deleteRetentionPolicyEnabled: true
      lastAccessTimeTrackingPolicyEnabled: true
    }
  }
}

//////////////////////////////////////////////////////////////////////////
// ROLE ASSIGNMENTS
//////////////////////////////////////////////////////////////////////////

// Role assignments are centralized in this section to make it easier to view all permissions granted in this template.
// Custom modules are used for role assignments since no published AVM module available for this at the time we created this template.

// ---------------------------------------------------------------------------
// Executor role assignments (consolidated into a single array-driven module
// call to reduce compiled ARM template size).
// ---------------------------------------------------------------------------
var _executorRoles = concat(
  deployContainerRegistry ? [
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AcrPush.guid)
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: principalType
    }
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AcrPull.guid)
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: principalType
    }
  ] : [],
  deployKeyVault ? [
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.KeyVaultContributor.guid)
      #disable-next-line BCP318
      resourceId: keyVault.id
      principalType: principalType
    }
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.KeyVaultSecretsOfficer.guid)
      #disable-next-line BCP318
      resourceId: keyVault.id
      principalType: principalType
    }
  ] : [],
  deploySearchService ? [
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.SearchServiceContributor.guid)
      #disable-next-line BCP318
      resourceId: searchService.outputs.resourceId
      principalType: principalType
    }
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.SearchIndexDataContributor.guid)
      #disable-next-line BCP318
      resourceId: searchService.outputs.resourceId
      principalType: principalType
    }
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.SearchIndexDataReader.guid)
      #disable-next-line BCP318
      resourceId: searchService.outputs.resourceId
      principalType: principalType
    }
  ] : [],
  deployStorageAccount ? [
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.StorageBlobDataContributor.guid)
      #disable-next-line BCP318
      resourceId: storageAccount.outputs.resourceId
      principalType: principalType
    }
  ] : [],
  deployAiFoundry ? [
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesOpenAIUser.guid)
      resourceId: aiFoundryAccountResourceId
      principalType: principalType
    }
    {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesUser.guid)
      resourceId: aiFoundryAccountResourceId
      principalType: principalType
    }
  ] : []
)

module assignExecutorRoles 'modules/security/resource-role-assignment.bicep' = if (deployContainerRegistry || deployKeyVault || deploySearchService || deployStorageAccount || deployAiFoundry) {
  name: 'assignExecutorRoles'
  params: {
    name: 'assignExecutorRoles'
    roleAssignments: _executorRoles
  }
}

// Cosmos DB Account - Cosmos DB Built-in Data Contributor -> Executor (data plane, separate module)
module assignCosmosDBCosmosDbBuiltInDataContributorExecutor 'modules/security/cosmos-data-plane-role-assignment.bicep' = if (deployCosmosDb) {
  name: 'assignCosmosDBCosmosDbBuiltInDataContributorExecutor'
  params: {
    #disable-next-line BCP318
    cosmosDbAccountName: cosmosDBAccount.outputs.name
    principalId: principalId
    roleDefinitionGuid: const.roles.CosmosDBBuiltInDataContributor.guid
    scopePath: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${dbAccountName}/dbs/${dbDatabaseName}'
  }
}

// Key Vault Service - Key Vault Secrets User -> ContainerApp (per-app loop preserved)
module assignKeyVaultSecretsUserAca 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployKeyVault && contains(app.roles, const.roles.KeyVaultSecretsUser.key)) {
    name: 'assignKeyVaultSecretsUserAca-${app.service_name}'
    params: {
      name: 'assignKeyVaultSecretsUserAca-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.KeyVaultSecretsUser.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: keyVault.id
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// App Configuration Settings Service - App Configuration Data Reader -> ContainerApp
module assignAppConfigAppConfigurationDataReaderContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployAppConfig && contains(
    app.roles,
    const.roles.AppConfigurationDataReader.key
  )) {
    name: 'assignAppConfigAppConfigurationDataReader-${app.service_name}'
    params: {
      name: 'assignAppConfigAppConfigurationDataReader-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.AppConfigurationDataReader.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: appConfig.id
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// AI Foundry Account - Cognitive Services User -> ContainerApp
module assignAiFoundryAccountCognitiveServicesUserContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployAiFoundry && contains(
    app.roles,
    const.roles.CognitiveServicesUser.key
  )) {
    name: 'assignAIFoundryAccountCognitiveServicesUser-${app.service_name}'
    params: {
      name: 'assignAIFoundryAccountCognitiveServicesUser-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.CognitiveServicesUser.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          resourceId: aiFoundryAccountResourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// AI Foundry Account - Cognitive Services OpenAI User -> ContainerApp
module assignAIFoundryCogServOAIUserContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployAiFoundry && contains(
    app.roles,
    const.roles.CognitiveServicesOpenAIUser.key
  )) {
    name: 'assignAIFoundryCogServOAIUserContainerApps-${app.service_name}'
    params: {
      name: 'assignAIFoundryCogServOAIUserContainerApps-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.CognitiveServicesOpenAIUser.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          resourceId: aiFoundryAccountResourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// AI Foundry Account - Cognitive Services User -> Search Service (for agentic retrieval vectorizers)
module assignAiFoundryAccountCognitiveServicesUserSearch 'modules/security/resource-role-assignment.bicep' = if (deployAiFoundry && deploySearchService) {
  name: 'assignAiFoundryAccountCognitiveServicesUserSearch'
  params: {
    name: 'assignAiFoundryAccountCognitiveServicesUserSearch'
    roleAssignments: [
      {
        #disable-next-line BCP318
        principalId: (_useUAI) ? searchServiceUAI.properties.principalId : searchService.outputs.systemAssignedMIPrincipalId!
        roleDefinitionId: subscriptionResourceId(
          'Microsoft.Authorization/roleDefinitions',
          const.roles.CognitiveServicesUser.guid
        )
        resourceId: aiFoundryAccountResourceId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

// Azure Container Registry Service - AcrPull -> ContainerApp
module assignCrAcrPullContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployContainerRegistry && contains(app.roles, const.roles.AcrPull.key)) {
    name: 'assignCrAcrPull-${app.service_name}'
    params: {
      name: 'assignCrAcrPull-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AcrPull.guid)
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: containerRegistry.id
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Cosmos DB Account - Cosmos DB Built-in Data Contributor -> ContainerApp
module assignCosmosDBCosmosDbBuiltInDataContributorContainerApps 'modules/security/cosmos-data-plane-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployCosmosDb && contains(
    app.roles,
    const.roles.CosmosDBBuiltInDataContributor.key
  )) {
    name: 'assignCosmosDBCosmosDbBuiltInDataContributor-${app.service_name}'
    params: {
      #disable-next-line BCP318
      cosmosDbAccountName: cosmosDBAccount.outputs.name
      #disable-next-line BCP318
      principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
      roleDefinitionGuid: const.roles.CosmosDBBuiltInDataContributor.guid
      scopePath: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${dbAccountName}/dbs/${dbDatabaseName}'
    }
  }
]

// Key Vault Service - Key Vault Secrets User -> ContainerApp
module assignKeyVaultKeyVaultSecretsUserContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployKeyVault && contains(app.roles, const.roles.KeyVaultSecretsUser.key)) {
    name: 'assignKeyVaultKeyVaultSecretsUser-${app.service_name}'
    params: {
      name: 'assignKeyVaultKeyVaultSecretsUser-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.KeyVaultSecretsUser.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: keyVault.id
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Search Service - Search Index Data Reader -> ContainerApp
module assignSearchSearchIndexDataReaderContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deploySearchService && contains(
    app.roles,
    const.roles.SearchIndexDataReader.key
  )) {
    name: 'assignSearchSearchIndexDataReader-${app.service_name}'
    params: {
      name: 'assignSearchSearchIndexDataReader-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.SearchIndexDataReader.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI)  ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: searchService.outputs.resourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Search Service - Search Index Data Contributor -> ContainerApp
module assignSearchSearchIndexDataContributorContainerApps 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deploySearchService && contains(
    app.roles,
    const.roles.SearchIndexDataContributor.key
  )) {
    name: 'assignSearchSearchIndexDataContributor-${app.service_name}'
    params: {
      name: 'assignSearchSearchIndexDataContributor-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.SearchIndexDataContributor.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId  : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: searchService.outputs.resourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Storage Account - Storage Blob Data Contributor -> ContainerApp
module assignStorageStorageBlobDataContributorAca 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployStorageAccount && contains(
    app.roles,
    const.roles.StorageBlobDataContributor.key
  )) {
    name: 'assignStorageStorageBlobDataContributor-${app.service_name}'
    params: {
      name: 'assignStorageStorageBlobDataContributor-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.StorageBlobDataContributor.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: storageAccount.outputs.resourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Storage Account - Storage Blob Data Reader -> ContainerApp
module assignStorageStorageBlobDataReaderAca 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployStorageAccount && contains(
    app.roles,
    const.roles.StorageBlobDataReader.key
  )) {
    name: 'assignStorageStorageBlobDataReaderAca-${app.service_name}'
    params: {
      name: 'assignStorageStorageBlobDataReaderAca-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.StorageBlobDataReader.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI)  ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: storageAccount.outputs.resourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Storage Account - Storage Blob Data Delegator -> ContainerApp
module assignStorageStorageBlobDataDelegatorAca 'modules/security/resource-role-assignment.bicep' = [
  for (app, i) in containerAppsList: if (deployContainerApps && deployStorageAccount && contains(
    app.roles,
    const.roles.StorageBlobDelegator.key
  )) {
    name: 'assignStorageStorageBlobDataDelegatorAca-${app.service_name}'
    params: {
      name: 'assignStorageStorageBlobDataDelegatorAca-${app.service_name}'
      roleAssignments: [
        {
          roleDefinitionId: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            const.roles.StorageBlobDelegator.guid
          )
          #disable-next-line BCP318
          principalId: (_useUAI)  ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
          #disable-next-line BCP318
          resourceId: storageAccount.outputs.resourceId
          principalType: 'ServicePrincipal'
        }
      ]
    }
  }
]

// Storage Account - Storage Blob Data Reader -> Search Service
module assignStorageStorageBlobDataReaderSearch 'modules/security/resource-role-assignment.bicep' = if (deployStorageAccount && deploySearchService) {
  name: 'assignStorageStorageBlobDataReaderSearch'
  params: {
    name: 'assignStorageStorageBlobDataReaderSearch'
    roleAssignments: [
      {
        #disable-next-line BCP318
        principalId: (_useUAI) ? searchServiceUAI.properties.principalId : searchService.outputs.systemAssignedMIPrincipalId!
        roleDefinitionId: subscriptionResourceId(
          'Microsoft.Authorization/roleDefinitions',
          const.roles.StorageBlobDataReader.guid
        )
        #disable-next-line BCP318
        resourceId: storageAccount.outputs.resourceId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

// Search Service - Search Index Data Reader -> AiFoundryProject
module assignSearchSearchIndexDataReaderAIFoundryProject 'modules/security/resource-role-assignment.bicep' = if (deployAiFoundry && deploySearchService) {
  name: 'assignSearchSearchIndexDataReaderAIFoundryProject'
  params: {
    name: 'assignSearchSearchIndexDataReaderAIFoundryProject'
    roleAssignments: [
      {
        principalId: aiFoundry!.outputs.aiProjectPrincipalId
        roleDefinitionId: subscriptionResourceId(
          'Microsoft.Authorization/roleDefinitions',
          const.roles.SearchIndexDataReader.guid
        )
        #disable-next-line BCP318
        resourceId: searchService.outputs.resourceId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

// NOTE: Search Service Contributor for the AI Foundry Project identity on the
// Search service is already created by the AVM AI Foundry module (avm/ptn/ai-ml/ai-foundry)
// when aiSearchConfiguration is provided. Creating it again here causes a
// RoleAssignmentExists conflict because both produce the same deterministic GUID.
// Intentionally omitted.

// Storage Account - Storage Blob Data Reader -> AiFoundry Project
module assignStorageStorageBlobDataReaderAIFoundryProject 'modules/security/resource-role-assignment.bicep' = if (deployAiFoundry && deployStorageAccount) {
  name: 'assignStorageStorageBlobDataReaderAIFoundryProject'
  params: {
    name: 'assignStorageStorageBlobDataReaderAIFoundryProject'
    roleAssignments: [
      {
        principalId: aiFoundry!.outputs.aiProjectPrincipalId
        roleDefinitionId: subscriptionResourceId(
          'Microsoft.Authorization/roleDefinitions',
          const.roles.StorageBlobDataReader.guid
        )
        #disable-next-line BCP318
        resourceId: storageAccount.outputs.resourceId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

//////////////////////////////////////////////////////////////////////////
// App Configuration Settings Service
//////////////////////////////////////////////////////////////////////////

// App Configuration Store
//////////////////////////////////////////////////////////////////////////

resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-05-01' = if (deployAppConfig) {
  name: appConfigName
  location: location
  tags: _tags
  sku: {
    name: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dataPlaneProxy: {
      authenticationMode: 'Pass-through'
      privateLinkDelegation: _networkIsolation ? 'Enabled' : 'Disabled'
    }
    publicNetworkAccess: _networkIsolation ? 'Disabled' : 'Enabled'
    disableLocalAuth: false
  }
}

resource appConfigDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAppConfig) {
  #disable-next-line use-resource-id-functions
  name: guid(appConfig.id, principalId, const.roles.AppConfigurationDataOwner.guid)
  scope: appConfig
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AppConfigurationDataOwner.guid)
  }
}

// prepare the container apps settings for the app configuration store
module containerAppsSettings 'modules/container-apps/container-apps-list.bicep' = if (deployContainerApps) {
  name: 'containerAppsSettings'
  params: {
    appConfigLabel: appConfigLabel
    containerAppsList: [
      for i in range(0, length(containerAppsList)): {
        #disable-next-line BCP318
        name: containerApps[i].outputs.name
        serviceName: containerAppsList[i].service_name
        canonical_name: containerAppsList[i].canonical_name
        #disable-next-line BCP318
        principalId: (_useUAI) ? containerAppsUAI[i].properties.principalId : containerApps[i].outputs.systemAssignedMIPrincipalId!
        #disable-next-line BCP318
        fqdn: containerApps[i].outputs.fqdn
      }
    ]
  }
}

// prepare the model deployment names for the app configuration store
var _modelDeploymentNamesSettings = [
  for modelDeployment in modelDeploymentList: {
    name: modelDeployment.canonical_name
    value: modelDeployment.name
    label: appConfigLabel
    contentType: 'text/plain'
  }
]

// prepare the database container names for the app configuration store
var _databaseContainerNamesSettings = [
  for databaseContainer in databaseContainersList: {
    name: databaseContainer.canonical_name
    value: databaseContainer.name
    label: appConfigLabel
    contentType: 'text/plain'
  }
]

// prepare the storage container names for the app configuration store
var _storageContainerNamesSettings = [
  for storageContainer in storageAccountContainersList: {
    name: storageContainer.canonical_name
    value: storageContainer.name
    label: appConfigLabel
    contentType: 'text/plain'
  }
]

var _modelDeploymentSettings = [
  for modelDeployment in modelDeploymentList: { 
    canonical_name: modelDeployment.canonical_name 
    capacity: modelDeployment.sku.capacity          
    model: modelDeployment.model.name                  
    modelFormat: modelDeployment.model.format          
    name: modelDeployment.name
    version: modelDeployment.model.version         
    apiVersion: modelDeployment.?apiVersion ?? '2025-01-01-preview' 
    endpoint: 'https://${aiFoundryAccountName}.openai.azure.com/' 
  }
]

// Populate App Configuration store with Container App API keys (only when useAPIKeys is true).
module appConfigKeyVaultPopulate 'modules/app-configuration/app-configuration.bicep' = if (deployAppConfig && deployKeyVault && _useCAppAPIKey) {
  name: 'appConfigKeyVaultPopulate'
  params: {
    #disable-next-line BCP318
    storeName: appConfig.name
    keyValues:  [ 
      for app in containerAppsList: {
            name: '${app.canonical_name}_APIKEY'
            #disable-next-line BCP318
            value: '{"uri":"${keyVault.properties.vaultUri}secrets/${replace(app.canonical_name, '_', '-')}-APIKEY"}'
            label: appConfigLabel
            contentType: 'application/vnd.microsoft.appconfig.keyvaultref+json;charset=utf-8'
      }
    ]
  }
}

module cosmosConfigKeyVaultPopulate 'modules/app-configuration/app-configuration.bicep' = if (deployCosmosDb && deployAppConfig && !_networkIsolation) {
  name: 'cosmosConfigKeyVaultPopulate'
  params: {
    #disable-next-line BCP318
    storeName: appConfig.name
    keyValues: concat(
      [
        #disable-next-line BCP318
      { name: 'COSMOS_DB_ACCOUNT_RESOURCE_ID', value: cosmosDBAccount.outputs.resourceId, label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'COSMOS_DB_ENDPOINT',              value: cosmosDBAccount.outputs.endpoint,            label: appConfigLabel, contentType: 'text/plain' }
      ]
    )
  }
}

module appConfigPopulate 'modules/app-configuration/app-configuration.bicep' = if (deployAppConfig && !_networkIsolation) {
  name: 'appConfigPopulate'
  params: {
    #disable-next-line BCP318
    storeName: appConfig.name
    keyValues: concat(
      #disable-next-line BCP318
      deployContainerApps ? containerAppsSettings.outputs.containerAppsEndpoints : [],
      #disable-next-line BCP318
      deployContainerApps ? containerAppsSettings.outputs.containerAppsName : [],
      _modelDeploymentNamesSettings,
      _databaseContainerNamesSettings,
      _storageContainerNamesSettings,
      [
        // ── General / Deployment ─────────────────────────────────────────────
      { name: 'AZURE_TENANT_ID',     value: tenant().tenantId,                      label: appConfigLabel, contentType: 'text/plain' }
      { name: 'SUBSCRIPTION_ID',     value: subscription().subscriptionId,          label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AZURE_RESOURCE_GROUP', value: resourceGroup().name,                  label: appConfigLabel, contentType: 'text/plain' }
      { name: 'LOCATION',            value: location,                               label: appConfigLabel, contentType: 'text/plain' }
      { name: 'ENVIRONMENT_NAME',    value: environmentName,                        label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOYMENT_NAME',     value: deployment().name,                      label: appConfigLabel, contentType: 'text/plain' }
      { name: 'RESOURCE_TOKEN',      value: resourceToken,                          label: appConfigLabel, contentType: 'text/plain' }
      { name: 'ENABLE_AGENTIC_RETRIEVAL', value: toLower(string(enableAgenticRetrieval)), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'NETWORK_ISOLATION',   value: toLower(string(_networkIsolation)),     label: appConfigLabel, contentType: 'text/plain' }
      { name: 'USE_UAI',             value: string(_useUAI),                        label: appConfigLabel, contentType: 'text/plain' }
      { name: 'LOG_LEVEL',           value: 'INFO',                                 label: appConfigLabel, contentType: 'text/plain' }
      { name: 'ENABLE_CONSOLE_LOGGING', value: 'true',                              label: appConfigLabel, contentType: 'text/plain' }
      { name: 'RELEASE',     value: _manifest.tag,                      label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: (deployAppInsights && deployLogAnalytics) ? appInsights.properties.ConnectionString : '',   label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'APPLICATIONINSIGHTS__INSTRUMENTATIONKEY', value: (deployAppInsights && deployLogAnalytics) ? appInsights.properties.InstrumentationKey : '', label: appConfigLabel, contentType: 'text/plain' }

      //── Resource IDs ─────────────────────────────────────────────────────
      #disable-next-line BCP318
      { name: 'KEY_VAULT_RESOURCE_ID', value: deployKeyVault ? keyVault.id : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'STORAGE_ACCOUNT_RESOURCE_ID', value: deployStorageAccount ? storageAccount.outputs.resourceId : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'APP_INSIGHTS_RESOURCE_ID', value: (deployAppInsights && deployLogAnalytics) ? appInsights.id : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'LOG_ANALYTICS_RESOURCE_ID', value: deployLogAnalytics ? logAnalytics.id : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'CONTAINER_ENV_RESOURCE_ID', value: deployContainerEnv ? containerEnv.id : '', label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AI_FOUNDRY_ACCOUNT_RESOURCE_ID', value: (deployAiFoundry) ? aiFoundryAccountResourceId : '', label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AI_FOUNDRY_PROJECT_RESOURCE_ID', value: (deployAiFoundry) ? aiFoundryProjectResourceId : '', label: appConfigLabel, contentType: 'text/plain' }
      // { name: 'AI_FOUNDRY_PROJECT_WORKSPACE_ID', value: (deployAiFoundry) ? aiFoundryFormatProjectWorkspaceId!.outputs.projectWorkspaceIdGuid : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'SEARCH_SERVICE_UAI_RESOURCE_ID', value: (deploySearchService && _useUAI) ? searchServiceUAI.id : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'SEARCH_SERVICE_RESOURCE_ID', value: deploySearchService ? searchService.outputs.resourceId : '', label: appConfigLabel, contentType: 'text/plain' }
      
      // ── Resource Names ───────────────────────────────────────────────────
      { name: 'AI_FOUNDRY_ACCOUNT_NAME', value: aiFoundryAccountName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AI_FOUNDRY_PROJECT_NAME', value: aiFoundryProjectName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AI_FOUNDRY_STORAGE_ACCOUNT_NAME', value: aiFoundryStorageAccountName, label: appConfigLabel, contentType: 'text/plain'}
      { name: 'APP_CONFIG_NAME', value: appConfigName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'APP_INSIGHTS_NAME', value: appInsightsName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'CONTAINER_ENV_NAME', value: containerEnvName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'CONTAINER_REGISTRY_NAME', value: containerRegistryName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'CONTAINER_REGISTRY_LOGIN_SERVER', value: '${containerRegistryName}.azurecr.io', label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DATABASE_ACCOUNT_NAME', value: dbAccountName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DATABASE_NAME', value: dbDatabaseName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'SEARCH_SERVICE_NAME', value: searchServiceName, label: appConfigLabel, contentType: 'text/plain' }
      { name: 'STORAGE_ACCOUNT_NAME', value: storageAccountName, label: appConfigLabel, contentType: 'text/plain' }

      // ── Feature flagging ─────────────────────────────────────────────────
      { name: 'DEPLOY_APP_CONFIG', value: string(deployAppConfig), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_KEY_VAULT', value: string(deployKeyVault), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_LOG_ANALYTICS', value: string(deployLogAnalytics), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_APP_INSIGHTS', value: string(deployAppInsights), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_SEARCH_SERVICE', value: string(deploySearchService), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_STORAGE_ACCOUNT', value: string(deployStorageAccount), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_COSMOS_DB', value: string(deployCosmosDb), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_CONTAINER_APPS', value: string(deployContainerApps), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_CONTAINER_REGISTRY', value: string(deployContainerRegistry), label: appConfigLabel, contentType: 'text/plain' }
      { name: 'DEPLOY_CONTAINER_ENV', value: string(deployContainerEnv), label: appConfigLabel, contentType: 'text/plain' }

      // ── Endpoints / URIs ──────────────────────────────────────────────────
      #disable-next-line BCP318
      { name: 'KEY_VAULT_URI',                   value: deployKeyVault ? keyVault.properties.vaultUri : '',                        label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'STORAGE_BLOB_ENDPOINT',           value: deployStorageAccount ? storageAccount.outputs.primaryBlobEndpoint : '',  label: appConfigLabel, contentType: 'text/plain' }
      { name: 'AI_FOUNDRY_ACCOUNT_ENDPOINT',     value: (deployAiFoundry) ? aiFoundryAccountEndpoint : '', label: appConfigLabel, contentType: 'text/plain' }      
      { name: 'AI_FOUNDRY_PROJECT_ENDPOINT',     value: (deployAiFoundry) ? aiFoundryProjectEndpoint : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'SEARCH_SERVICE_QUERY_ENDPOINT',   value: deploySearchService ? searchService.outputs.endpoint : '',              label: appConfigLabel, contentType: 'text/plain' }

      // ── Connections ───────────────────────────────────────────────────────
      #disable-next-line BCP318
      { name: 'SEARCH_CONNECTION_ID', value: deploySearchService && deployAiFoundry ? aiFoundryConnectionSearch.outputs.searchConnectionId : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'BING_CONNECTION_ID', value: deployGroundingWithBing && deployAiFoundry ? bingSearchConnection!.outputs.bingConnectionId : '', label: appConfigLabel, contentType: 'text/plain' }

      //── Managed Identity Principals ───────────────────────────────────────
      #disable-next-line BCP318
      { name: 'CONTAINER_ENV_PRINCIPAL_ID', value: deployContainerEnv ? ((_useUAI) ? containerEnvUAI.properties.principalId : (containerEnv.?identity.?principalId ?? '')) : '', label: appConfigLabel, contentType: 'text/plain' }
      #disable-next-line BCP318
      { name: 'SEARCH_SERVICE_PRINCIPAL_ID', value: deploySearchService ? ((_useUAI) ? searchServiceUAI.properties.principalId : searchService.outputs.systemAssignedMIPrincipalId!) : '', label: appConfigLabel, contentType: 'text/plain' }

      // ── Container Apps List & Model Deployments ────────────────────────────
      #disable-next-line BCP318
      { name: 'CONTAINER_APPS', value: deployContainerApps ? string(containerAppsSettings.outputs.containerAppsList) : '[]', label: appConfigLabel, contentType: 'application/json' }
      { name: 'MODEL_DEPLOYMENTS', value: string(_modelDeploymentSettings), label: appConfigLabel, contentType: 'application/json' }

    ]
    )
  }
}

//////////////////////////////////////////////////////////////////////////
// OUTPUTS
//////////////////////////////////////////////////////////////////////////

// ──────────────────────────────────────────────────────────────────────
// General / Deployment
// ──────────────────────────────────────────────────────────────────────
output TENANT_ID string = tenant().tenantId
output SUBSCRIPTION_ID string = subscription().subscriptionId
output AZURE_RESOURCE_GROUP string = resourceGroup().name
output LOCATION string = location
output ENVIRONMENT_NAME string = environmentName
output DEPLOYMENT_NAME string = deployment().name
output RESOURCE_TOKEN string = resourceToken
output NETWORK_ISOLATION bool = _networkIsolation
output USE_UAI bool = _useUAI
output USE_CAPP_API_KEY bool = _useCAppAPIKey
output RELEASE string = _manifest.tag

// ──────────────────────────────────────────────────────────────────────
// Feature flagging
// ──────────────────────────────────────────────────────────────────────
output DEPLOY_APP_CONFIG bool = deployAppConfig
output DEPLOY_SOFTWARE bool = deploySoftware
output DEPLOY_KEY_VAULT bool = deployKeyVault
output DEPLOY_LOG_ANALYTICS bool = deployLogAnalytics
output DEPLOY_APP_INSIGHTS bool = deployAppInsights
output DEPLOY_SEARCH_SERVICE bool = deploySearchService
output DEPLOY_STORAGE_ACCOUNT bool = deployStorageAccount
output DEPLOY_COSMOS_DB bool = deployCosmosDb
output DEPLOY_CONTAINER_APPS bool = deployContainerApps
output DEPLOY_CONTAINER_REGISTRY bool = deployContainerRegistry
output DEPLOY_CONTAINER_ENV bool = deployContainerEnv
output DEPLOY_VM_KEY_VAULT bool = deployVmKeyVault

@description('Name of the ACR Task agent pool when deployed. Empty when not deployed.')
output ACR_TASK_AGENT_POOL string = _deployAcrTaskAgentPool ? acrTaskAgentPoolName : ''

// ──────────────────────────────────────────────────────────────────────
// Endpoints / URIs
// ──────────────────────────────────────────────────────────────────────
#disable-next-line BCP318
output APP_CONFIG_ENDPOINT string = deployAppConfig ? appConfig.properties.endpoint : ''
