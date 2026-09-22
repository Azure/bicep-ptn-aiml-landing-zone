# Code Disclaimer

THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.

This sample is not supported under any Microsoft standard support program or service. 
 The script is provided AS IS without warranty of any kind. Microsoft further disclaims all
 implied warranties including, without limitation, any implied warranties of merchantability
 or of fitness for a particular purpose. The entire risk arising out of the use or performance
 of the sample and documentation remains with you. In no event shall Microsoft, its authors,
 or anyone else involved in the creation, production, or delivery of the script be liable for 
 any damages whatsoever (including, without limitation, damages for loss of business profits, 
 business interruption, loss of business information, or other pecuniary loss) arising out of 
 the use of or inability to use the sample or documentation, even if Microsoft has been advised 
 of the possibility of such damages, rising out of the use of or inability to use the sample script, 
 even if Microsoft has been advised of the possibility of such damages.

# Azure AI Landing Zone integrated deployment

This repository deploys an Azure AI Landing Zone (AILZ) spoke into an existing
Azure Landing Zone hub. Use
[Deploy-AilzIntegrated.ps1](Deploy-AilzIntegrated.ps1) to configure the `azd`
environment, preview the infrastructure changes, and provision the deployment.

The script configures this topology automatically:

- `DEPLOYMENT_MODE=ailz-integrated`
- `NETWORK_ISOLATION=true`
- `DEPLOY_AZURE_FIREWALL=false`
- Spoke-to-hub peering using the supplied hub VNet resource ID
- Spoke egress through the supplied hub firewall or NVA private IP
- Optional internal Developer-tier API Management in a dedicated spoke subnet

## Prerequisites

Before running the script, confirm that you have:

1. [PowerShell 7 or later](https://learn.microsoft.com/powershell/scripting/install/installing-powershell).
2. [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).
3. [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd).
4. Azure `Contributor` and `User Access Administrator` roles at the deployment
  scope.
5. Accepted the Responsible AI terms for Azure AI services.
6. The full Azure resource ID of the existing hub VNet.
7. The private IP address of the hub Azure Firewall or other next-hop NVA.
8. A non-overlapping address range available for the new spoke VNet. The
  default spoke range in this checkout is `192.168.0.0/21`.
9. Hub firewall policy rules that allow the spoke address range to reach the
  required Azure services.

Open PowerShell 7 in the repository root before following the steps below.

## Deployment script parameters

The script has four required parameters. The remaining parameters are optional.

| Parameter | Required | Description | Example |
| --- | --- | --- | --- |
| `EnvironmentName` | Yes | Name of the local `azd` environment to create or reuse. Use a short name that identifies the workload and lifecycle environment. Reusing a name also reuses values saved by earlier runs. | `ailz-dev` |
| `Location` | Yes | Primary Azure region for the deployment. Use an Azure region name without spaces. Resource availability and organizational policy may restrict the allowed regions. | `eastus2` |
| `HubVnetResourceId` | Yes | Full Azure resource ID of the existing hub virtual network. The deployment uses it to create the spoke-to-hub peering. | `/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Network/virtualNetworks/<hub-vnet>` |
| `EgressNextHopIp` | Yes | Private IPv4 address of the hub Azure Firewall or network virtual appliance that receives the spoke's default route. Do not use its public IP. | `10.100.0.4` |
| `ExistingLogAnalyticsWorkspaceResourceId` | No | Full resource ID of a hub-managed Log Analytics workspace to reuse. Leave it out to deploy a new workspace. | `/subscriptions/.../providers/Microsoft.OperationalInsights/workspaces/<name>` |
| `ExistingApplicationInsightsResourceId` | No | Full resource ID of an existing Application Insights component to reuse. It must be supplied together with `ExistingApplicationInsightsConnectionString`. Leave both out to deploy a new component. | `/subscriptions/.../providers/Microsoft.Insights/components/<name>` |
| `ExistingApplicationInsightsConnectionString` | No | Connection string belonging to the reused Application Insights component. Store it in a PowerShell variable before invoking the script so it is not typed directly into the command. | `$applicationInsightsConnectionString` |
| `DeployApiManagement` | No | Deploy a Developer-tier API Management service with internal VNet injection into the AILZ spoke. Disabled by default. | `-DeployApiManagement` |
| `ApiManagementPublisherEmail` | Conditional | Publisher contact email. Required when `DeployApiManagement` is enabled. | `api-owners@contoso.com` |
| `ApiManagementPublisherName` | No | Publisher display name. Defaults to `AI Landing Zone`. | `Contoso API Team` |
| `ApiManagementIngressSourceAddressPrefixes` | No | Hub firewall private IP CIDRs allowed to reach the internal APIM gateway after DNAT. Defaults to `EgressNextHopIp/32`; pass every firewall instance IP when the hub uses multiple addresses. | `@("10.100.0.4/32")` |
| `AdditionalEnvironmentVariables` | No | PowerShell hashtable containing additional `azd` environment values supported by `main.parameters.json`, such as subscription, resource group, private DNS zone IDs, or feature flags. Values persist in the selected local `azd` environment. | `@{ AZURE_SUBSCRIPTION_ID = "<id>" }` |
| `PreviewOutput` | No | Preview detail level. `Full` displays ARM What-If changes plus every nested compiled resource declaration. `Slim` (default) displays the original condensed `azd provision --preview` summary. | `Full` |
| `PreviewOnly` | No | Switch that stops after `azd provision --preview`. Without it, the script displays the preview and then asks you to type `DEPLOY` before provisioning. | `-PreviewOnly` |

### Find the required values

List the Azure regions available to your subscription:

```powershell
az account list-locations --query "[].name" --output table
```

Get the hub VNet resource ID:

```powershell
$hubVnetResourceId = az network vnet show `
  --resource-group "<hub-resource-group>" `
  --name "<hub-vnet-name>" `
  --query id `
  --output tsv
```

Get the private IP of an Azure Firewall in the hub:

```powershell
$egressNextHopIp = az network firewall show `
  --resource-group "<hub-resource-group>" `
  --name "<hub-firewall-name>" `
  --query "ipConfigurations[0].privateIPAddress" `
  --output tsv
```

Pass those variables directly to the script:

```powershell
./Deploy-AilzIntegrated.ps1 `
  -EnvironmentName "ailz-dev" `
  -Location "eastus2" `
  -HubVnetResourceId $hubVnetResourceId `
  -EgressNextHopIp $egressNextHopIp `
  -PreviewOnly
```

If the hub uses a network virtual appliance instead of Azure Firewall, obtain
its private forwarding IP from the platform or networking team.

## Deploy

### 1. Preview the deployment

Replace the example values, then run:

```powershell
./Deploy-AilzIntegrated.ps1 `
  -EnvironmentName "ailz-dev" `
  -Location "eastus2" `
  -HubVnetResourceId "/subscriptions/<subscription-id>/resourceGroups/<hub-resource-group>/providers/Microsoft.Network/virtualNetworks/<hub-vnet-name>" `
  -EgressNextHopIp "10.100.0.4" `
  -PreviewOnly
```

The script signs in when needed, creates or selects the named `azd`
environment, sets the integrated-topology values, and displays two preview
sections:

- `ARM What-If resource changes` is Azure's evaluated change set for resources
  ARM expands during What-If.
- `Complete compiled nested resource inventory` recursively lists every
  resource declaration in the compiled template, including resources such as
  Microsoft Foundry accounts, projects, model deployments, capability hosts,
  and connections that ARM may omit when nested deployments exceed What-If's
  expansion depth. `INCLUDED` entries are unconditional; `CONDITIONAL` entries
  remain subject to their template or parent-module conditions.

`-PreviewOnly` guarantees that this invocation does not provision resources.
Pass `-PreviewOutput Slim` when the condensed `azd` resource summary is
preferred. Omitting `-PreviewOutput` uses `Full`.

Review both sections for deleted or replaced resources, unexpected role
assignments, public network access, incorrect regions, and changes outside the
intended resource group. Treat ARM What-If as the authoritative evaluated
change set and the compiled inventory as the exhaustive declaration audit.

### 2. Provision the deployment

Run the same command without `-PreviewOnly`:

```powershell
./Deploy-AilzIntegrated.ps1 `
  -EnvironmentName "ailz-dev" `
  -Location "eastus2" `
  -HubVnetResourceId "/subscriptions/<subscription-id>/resourceGroups/<hub-resource-group>/providers/Microsoft.Network/virtualNetworks/<hub-vnet-name>" `
  -EgressNextHopIp "10.100.0.4"
```

The script runs the preview again. Type exactly `DEPLOY` when prompted to start
provisioning. Any other response cancels the deployment.

### 3. Complete hub integration

After provisioning:

1. Create the reverse hub-to-spoke VNet peering. The template creates only the
  spoke-to-hub direction.
2. Link the hub-managed private DNS zones to the spoke VNet when Azure Policy
  does not manage those links.
3. Verify that the hub firewall permits the spoke source range and that its DNS
  configuration resolves the private endpoints.
4. Test access from a host with network connectivity to the spoke, such as a
  hub jumpbox reached through Azure Bastion.

See the [hub-and-spoke deployment walkthrough](https://azure.github.io/AI-Landing-Zones/bicep/hub-and-spoke/)
for the post-deployment network checks.

## Optional configuration

### Deploy API Management

Enable API Management and provide its publisher contact email:

```powershell
./Deploy-AilzIntegrated.ps1 `
  -EnvironmentName "ailz-dev" `
  -Location "eastus2" `
  -HubVnetResourceId $hubVnetResourceId `
  -EgressNextHopIp $egressNextHopIp `
  -DeployApiManagement `
  -ApiManagementPublisherEmail "api-owners@contoso.com" `
  -PreviewOnly
```

The deployment uses the Developer SKU and internal VNet mode. It creates the
dedicated `api-management-subnet` at `192.168.3.128/27`, an NSG for required
Azure control-plane and load-balancer traffic plus HTTPS from the approved hub
firewall CIDRs, and a dedicated route table. The default route sends workload
and APIM dependency egress to the hub firewall. The required `ApiManagement`
service-tag route sends control-plane responses directly to the Internet to
keep TCP 3443 symmetric; this is the sole intentional forced-tunneling
exception. Set `-ApiManagementPublisherName` to override the default publisher
name.

The platform team must complete these hub-owned changes before the gateway is
usable:

1. Configure hub firewall DNAT for TCP 443 to the APIM private VIP. Azure
  Firewall source-NATs DNAT traffic, so the APIM NSG permits the firewall
  private IP `/32` by default. Pass
  `-ApiManagementIngressSourceAddressPrefixes` when multiple firewall private
  IPs can source the traffic.
2. Permit the documented APIM VNet dependency service tags, ports, and FQDNs
  in the hub firewall policy. See the [APIM VNet configuration
  reference](https://learn.microsoft.com/azure/api-management/virtual-network-reference).
3. Publish A records that resolve the APIM gateway, management, portal,
  developer portal, and SCM host names to its private VIP in DNS visible from
  the hub and spoke.
4. Validate that direct spoke access to TCP 443 is denied and that requests
  succeed only through the hub firewall listener.

Disabling `DeployApiManagement` does not delete existing resources because ARM
deployments are incremental. After exporting any APIM data-plane configuration,
delete the APIM service and its dedicated subnet, NSG, and route table through
an approved cleanup change.

### Select the subscription and resource group

Pass additional `azd` environment values in a PowerShell hashtable:

```powershell
./Deploy-AilzIntegrated.ps1 `
  -EnvironmentName "ailz-dev" `
  -Location "eastus2" `
  -HubVnetResourceId "/subscriptions/<subscription-id>/resourceGroups/<hub-resource-group>/providers/Microsoft.Network/virtualNetworks/<hub-vnet-name>" `
  -EgressNextHopIp "10.100.0.4" `
  -AdditionalEnvironmentVariables @{
    AZURE_SUBSCRIPTION_ID = "<subscription-id>"
    AZURE_RESOURCE_GROUP  = "<spoke-resource-group-name>"
  } `
  -PreviewOnly
```

Without these values, `azd` uses the subscription and resource group associated
with the selected environment. Check them before deployment:

```powershell
azd env get-value AZURE_SUBSCRIPTION_ID
azd env get-value AZURE_RESOURCE_GROUP
az account show --query "{subscription:name, subscriptionId:id}" --output table
```

Use targeted `azd env get-value` commands instead of printing the entire
environment because it may contain the Application Insights connection string.

### Reuse hub observability

To reuse an existing Log Analytics workspace:

```powershell
-ExistingLogAnalyticsWorkspaceResourceId "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>"
```

To reuse Application Insights, both its resource ID and connection string are
required:

```powershell
-ExistingApplicationInsightsResourceId "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Insights/components/<component-name>" `
-ExistingApplicationInsightsConnectionString $applicationInsightsConnectionString
```

Obtain the connection string without placing it directly in the command:

```powershell
$applicationInsightsConnectionString = az monitor app-insights component show `
  --resource-group "<resource-group>" `
  --app "<component-name>" `
  --query connectionString `
  --output tsv
```

### Reuse private DNS zones or set other values

Use `-AdditionalEnvironmentVariables` for private DNS zone IDs and any other
environment-substituted setting supported by
[main.parameters.json](main.parameters.json):

```powershell
-AdditionalEnvironmentVariables @{
  EXISTING_PRIVATE_DNS_ZONE_BLOB_RESOURCE_ID     = "/subscriptions/.../privateDnsZones/privatelink.blob.core.windows.net"
  EXISTING_PRIVATE_DNS_ZONE_KEYVAULT_RESOURCE_ID = "/subscriptions/.../privateDnsZones/privatelink.vaultcore.azure.net"
  DNS_ZONE_LINK_SUFFIX                           = "spoke01"
}
```

Use the exact variable names from the
[AILZ parameter reference](https://azure.github.io/AI-Landing-Zones/bicep/parameterization/).
For hub integration in this checkout, the authoritative names are
`HUB_INTEGRATION_HUB_VNET_RESOURCE_ID` and
`HUB_INTEGRATION_EGRESS_NEXT_HOP_IP`.

These values persist in the local `azd` environment. Do not pass passwords,
tokens, or other application secrets through `-AdditionalEnvironmentVariables`;
store application secrets in Azure Key Vault.

## Troubleshooting

### `Required command '<name>' was not found`

Install the named prerequisite, open a new PowerShell 7 session, and verify it:

```powershell
pwsh --version
az version
azd version
```

### Script execution is disabled

Allow the script only for the current PowerShell process, then rerun it:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Do not weaken the machine-wide execution policy unless your organization has
approved that change.

### Azure sign-in opens the wrong tenant

Sign in to the required tenant before running the script:

```powershell
az login --tenant "<tenant-id>"
azd auth login --tenant-id "<tenant-id>"
```

Then verify and select the intended subscription:

```powershell
az account set --subscription "<subscription-id>"
az account show --output table
```

Also pass `AZURE_SUBSCRIPTION_ID` through `-AdditionalEnvironmentVariables` so
the `azd` environment targets the same subscription.

### `azd env select` reports that the environment does not exist

This message is expected the first time an environment name is used. The script
creates it immediately afterward. Investigate only if the subsequent
`azd env new` command also fails.

### An existing environment uses unexpected settings

The script reuses an environment when `-EnvironmentName` already exists. It
updates the values supplied on the current run, but it does not remove unrelated
values saved by an earlier run. Inspect the relevant value directly:

```powershell
azd env get-value <VARIABLE_NAME>
```

Use a new, unique `-EnvironmentName` for a clean deployment environment, or
correct the stale value by passing it in `-AdditionalEnvironmentVariables`.

### `ExistingApplicationInsightsResourceId and ... must be supplied together`

Supply both Application Insights parameters shown in the observability example,
or remove both parameters to deploy a new Application Insights component.

### Preflight reports an invalid resource ID or missing resource

Confirm that every ID starts with `/subscriptions/`, uses the correct
subscription and resource group, and refers to a resource visible to the signed-
in identity. Test a resource ID with:

```powershell
az resource show --ids "<resource-id>" --output table
```

### Preflight reports overlapping CIDR ranges

The default spoke range in this checkout is `192.168.0.0/21`. Choose a range
that does not overlap the hub or any connected network. The
`vnetAddressPrefixes` parameter is not currently exposed as an `azd` environment
variable, so add this entry inside the `parameters` object in
[main.parameters.json](main.parameters.json):

```json
"vnetAddressPrefixes": {
  "value": [
    "10.200.0.0/21"
  ]
},
```

Keep enough address space for the template's subnets, rerun with `-PreviewOnly`,
and confirm that preflight accepts the new range before provisioning.

### Authorization or role-assignment failure

Confirm that the signed-in identity has both `Contributor` and `User Access
Administrator` at the target scope. Azure Policy may also deny resource types,
regions, SKUs, public access settings, or role assignments; review the detailed
deployment error and work with the landing-zone platform owner rather than
bypassing policy.

### Hub peering or private endpoint DNS does not work

The deployment creates only spoke-to-hub peering. Create the reverse peering and
confirm that hub Private DNS zones are linked to the spoke or managed by Azure
Policy. Verify that custom DNS servers can resolve Azure Private DNS and that
network security rules permit the traffic.

### Preview succeeds but provisioning fails

A preview validates the proposed control-plane changes but does not guarantee
quota, capacity, data-plane access, or eventual service availability. Read the
first Azure resource error, correct that condition, and rerun the same script.
The script returns a failing exit code when `azd` fails; it does not hide the
underlying deployment error.

## Related documentation

- [How to deploy Azure AI Landing Zones](https://azure.github.io/AI-Landing-Zones/bicep/how-to-deploy/#ai-landing-zone-integrated-deployment)
- [AILZ parameter reference](https://azure.github.io/AI-Landing-Zones/bicep/parameterization/)
- [Hub-and-spoke topology](https://azure.github.io/AI-Landing-Zones/bicep/hub-and-spoke/)
- [Permissions](https://azure.github.io/AI-Landing-Zones/bicep/permissions/)
