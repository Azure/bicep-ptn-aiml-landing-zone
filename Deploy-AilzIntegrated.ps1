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