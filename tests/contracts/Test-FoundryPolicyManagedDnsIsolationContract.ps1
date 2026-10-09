<#
.SYNOPSIS
    Validates that policy-managed Private DNS keeps Microsoft Foundry private.

.DESCRIPTION
    Regression test for network-isolated deployments that create a Foundry
    private endpoint while a platform policy or central network team owns
    Private DNS. The Foundry account must disable public network access and
    retain agent subnet injection based on the private endpoint subnet alone.
    Local Private DNS zone IDs only control the endpoint DNS zone group.
#>

[CmdletBinding()]
param(
    [string]$AccountModule = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/ai-foundry/foundry/modules/account.bicep')
)

$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([Parameter(Mandatory)] [string]$Message)
    $failures.Add($Message) | Out-Null
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Add-Pass {
    param([Parameter(Mandatory)] [string]$Message)
    Write-Host "  [PASS] $Message" -ForegroundColor Green
}

function Assert-Contract {
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Message
    )

    if ($Condition) {
        Add-Pass $Message
    }
    else {
        Add-Failure $Message
    }
}

Write-Host 'Foundry policy-managed DNS isolation contract' -ForegroundColor Cyan

$compiledJson = & az bicep build --file $AccountModule --stdout 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to compile '$AccountModule'."
}

$template = ($compiledJson -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100
$privateNetworkingExpression = [string]$template.variables.privateNetworkingEnabled
$foundryAccountParameters = $template.resources.foundryAccount.properties.parameters
$publicNetworkAccessExpression = [string]$foundryAccountParameters.publicNetworkAccess
$networkInjectionsExpression = [string]$foundryAccountParameters.networkInjections

Assert-Contract `
    ($privateNetworkingExpression -ceq "[not(empty(parameters('privateEndpointSubnetResourceId')))]") `
    'Private networking is enabled by the private endpoint subnet without requiring local Private DNS zone IDs.'

Assert-Contract `
    ($publicNetworkAccessExpression -match "variables\('privateNetworkingEnabled'\).*'Disabled'.*'Enabled'") `
    'Foundry public network access is disabled whenever private networking is enabled.'

Assert-Contract `
    ($networkInjectionsExpression -match "variables\('privateNetworkingEnabled'\).*parameters\('agentSubnetResourceId'\)") `
    'Agent subnet injection remains enabled for the private endpoint topology.'

$parentModule = Join-Path (Split-Path -Parent $AccountModule) '..\main.bicep'
$parentSource = Get-Content -LiteralPath $parentModule -Raw
Assert-Contract `
    ($parentSource -match 'foundryAccountPrivateEndpointWithoutDns' -and $parentSource -match '!hasAllFoundryPrivateDnsZoneIds') `
    'The parent module retains the private-endpoint path without a local DNS zone group.'

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) contract assertion(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'All Foundry policy-managed DNS isolation assertions passed.' -ForegroundColor Green
exit 0
