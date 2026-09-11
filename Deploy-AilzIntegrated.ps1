<#
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
 #>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $EnvironmentName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Location,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $HubVnetResourceId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $EgressNextHopIp,

    [string] $ExistingLogAnalyticsWorkspaceResourceId,
    [string] $ExistingApplicationInsightsResourceId,
    [string] $ExistingApplicationInsightsConnectionString,
    [hashtable] $AdditionalEnvironmentVariables = @{},
    [switch] $PreviewOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Azd {
    param([Parameter(Mandatory)][string[]] $Arguments)

    & azd @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "azd failed with exit code $LASTEXITCODE."
    }
}

foreach ($command in @('az', 'azd', 'pwsh')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found. Install it and try again."
    }
}

if ([bool]$ExistingApplicationInsightsResourceId -ne [bool]$ExistingApplicationInsightsConnectionString) {
    throw 'ExistingApplicationInsightsResourceId and ExistingApplicationInsightsConnectionString must be supplied together.'
}

$settings = [ordered]@{
    AZURE_LOCATION                           = $Location
    DEPLOYMENT_MODE                         = 'ailz-integrated'
    NETWORK_ISOLATION                       = 'true'
    DEPLOY_AZURE_FIREWALL                   = 'false'
    HUB_INTEGRATION_HUB_VNET_RESOURCE_ID    = $HubVnetResourceId
    HUB_INTEGRATION_EGRESS_NEXT_HOP_IP      = $EgressNextHopIp
    EXISTING_LOG_ANALYTICS_WORKSPACE_RESOURCE_ID = $ExistingLogAnalyticsWorkspaceResourceId
    EXISTING_APPLICATION_INSIGHTS_RESOURCE_ID     = $ExistingApplicationInsightsResourceId
    EXISTING_APPLICATION_INSIGHTS_CONNECTION_STRING = $ExistingApplicationInsightsConnectionString
}

foreach ($name in $AdditionalEnvironmentVariables.Keys) {
    $settings[$name] = [string]$AdditionalEnvironmentVariables[$name]
}

Push-Location $PSScriptRoot
try {
    & az account show --output none
    if ($LASTEXITCODE -ne 0) {
        & az login
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI sign-in failed with exit code $LASTEXITCODE."
        }
    }

    & azd auth login --check-status
    if ($LASTEXITCODE -ne 0) {
        Invoke-Azd -Arguments @('auth', 'login')
    }

    & azd env select $EnvironmentName
    if ($LASTEXITCODE -ne 0) {
        Invoke-Azd -Arguments @('env', 'new', $EnvironmentName, '--location', $Location)
    }

    foreach ($setting in $settings.GetEnumerator()) {
        if (-not [string]::IsNullOrWhiteSpace([string]$setting.Value)) {
            Invoke-Azd -Arguments @('env', 'set', [string]$setting.Key, [string]$setting.Value)
        }
    }

    Invoke-Azd -Arguments @('provision', '--preview')
    if ($PreviewOnly) {
        return
    }

    if ((Read-Host 'Preview complete. Type DEPLOY to continue') -cne 'DEPLOY') {
        Write-Host 'Deployment cancelled.'
        return
    }

    Invoke-Azd -Arguments @('provision')
}
finally {
    Pop-Location
}