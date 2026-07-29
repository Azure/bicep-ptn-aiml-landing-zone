<#
.SYNOPSIS
    Validates the accelerator-neutral hosted-agent infrastructure contract.

.DESCRIPTION
    Compiles main.bicep and compares its symbolic ARM resource graph with the
    merge-base fixture. All pre-existing resources must remain byte-stable.
    Only the two centralized RBAC deployment payloads may change, and both
    changes must be gated by deployHostedAgent.
#>

[CmdletBinding()]
param(
    [string]$MainFile = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'main.bicep'),
    [string]$FixtureFile = (Join-Path $PSScriptRoot 'fixtures\hosted-agent-resource-graph.json')
)

$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()
$compiledFile = Join-Path ([System.IO.Path]::GetTempPath()) "hosted-agent-contract-$([guid]::NewGuid()).json"

function Add-Failure {
    param([Parameter(Mandatory)] [string]$Message)
    $failures.Add($Message) | Out-Null
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Add-Pass {
    param([Parameter(Mandatory)] [string]$Message)
    Write-Host "  [PASS] $Message" -ForegroundColor Green
}

function Get-ObjectHash {
    param([Parameter(Mandatory)] $Value)
    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

try {
    if (-not (Test-Path -LiteralPath $FixtureFile)) {
        throw "Fixture not found: $FixtureFile"
    }
    $fixture = Get-Content -LiteralPath $FixtureFile -Raw | ConvertFrom-Json -Depth 20

    if (Get-Command az -ErrorAction SilentlyContinue) {
        $compilerVersionOutput = (& az bicep version 2>&1) -join "`n"
        if ($compilerVersionOutput -notmatch 'Bicep CLI version (?<version>\d+\.\d+\.\d+)') {
            throw "Unable to determine the Azure CLI Bicep version from: $compilerVersionOutput"
        }
        if ($Matches.version -ne $fixture.bicepVersion) {
            throw "Fixture requires Bicep $($fixture.bicepVersion), but Azure CLI uses $($Matches.version). Run 'az bicep install --version v$($fixture.bicepVersion)'."
        }
        $env:PYTHONIOENCODING = 'utf-8'
        & az bicep build --file $MainFile --outfile $compiledFile
    }
    elseif (Get-Command bicep -ErrorAction SilentlyContinue) {
        $compilerVersionOutput = (& bicep --version 2>&1) -join "`n"
        if ($compilerVersionOutput -notmatch 'Bicep CLI version (?<version>\d+\.\d+\.\d+)') {
            throw "Unable to determine the standalone Bicep version from: $compilerVersionOutput"
        }
        if ($Matches.version -ne $fixture.bicepVersion) {
            throw "Fixture requires Bicep $($fixture.bicepVersion), but the standalone CLI uses $($Matches.version)."
        }
        & bicep build $MainFile --outfile $compiledFile
    }
    else {
        throw 'Neither bicep nor az is available on PATH.'
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Bicep compilation failed with exit code $LASTEXITCODE."
    }
    $template = Get-Content -LiteralPath $compiledFile -Raw | ConvertFrom-Json -Depth 100

    Write-Host "Hosted-agent resource contract (baseline $($fixture.mergeBase))" -ForegroundColor Cyan

    if ($template.parameters.deployHostedAgent.defaultValue -ne $false) {
        Add-Failure 'deployHostedAgent must default to false.'
    }
    else {
        Add-Pass 'deployHostedAgent defaults to false.'
    }

    $expectedNames = @($fixture.resourceHashes.PSObject.Properties.Name) + @($fixture.allowedHostedMutations)
    $actualNames = @($template.resources.PSObject.Properties.Name)
    $missingNames = @($expectedNames | Where-Object { $_ -notin $actualNames })
    $addedNames = @($actualNames | Where-Object { $_ -notin $expectedNames })
    if ($missingNames.Count -gt 0 -or $addedNames.Count -gt 0) {
        Add-Failure "Symbolic resource graph changed. Missing: [$($missingNames -join ', ')]; added: [$($addedNames -join ', ')]."
    }
    else {
        Add-Pass "Symbolic resource graph matches the $($expectedNames.Count)-resource merge-base fixture."
    }

    foreach ($entry in $fixture.resourceHashes.PSObject.Properties) {
        if ($entry.Name -notin $actualNames) { continue }
        $actualHash = Get-ObjectHash -Value $template.resources.($entry.Name)
        if ($actualHash -ne $entry.Value) {
            Add-Failure "Pre-existing resource '$($entry.Name)' changed (expected $($entry.Value), got $actualHash)."
        }
    }
    if (-not ($failures | Where-Object { $_ -like "Pre-existing resource '*" })) {
        $stableResourceCount = @($fixture.resourceHashes.PSObject.Properties).Count
        Add-Pass "All $stableResourceCount non-hosted resource definitions are byte-stable."
    }

    $executorJson = $template.resources.assignExecutorRoles | ConvertTo-Json -Depth 100 -Compress
    $crossServiceJson = $template.resources.assignCrossServiceRoles | ConvertTo-Json -Depth 100 -Compress
    foreach ($check in @(
            @{
                Name = 'Executor receives Foundry Project Manager only when hosted enablement is selected.'
                Json = $executorJson
                Required = @("parameters('deployHostedAgent')", 'AzureAIProjectManager')
            },
            @{
                Name = 'Foundry project identity receives registry repository reader only when hosted enablement is selected.'
                Json = $crossServiceJson
                Required = @("parameters('deployHostedAgent')", "variables('_containerRegistryRepositoryReaderRoleId')")
            }
        )) {
        $missing = @($check.Required | Where-Object { -not $check.Json.Contains($_) })
        if ($missing.Count -gt 0) {
            Add-Failure "$($check.Name) Missing compiled tokens: $($missing -join ', ')."
        }
        else {
            Add-Pass $check.Name
        }
    }

    $source = Get-Content -LiteralPath $MainFile -Raw
    if (-not $source.Contains("var _containerRegistryRepositoryReaderRoleId = 'b93aa761-3e63-49ed-ac28-beffa264f7ac'")) {
        Add-Failure 'The hosted-agent registry pull role is not pinned to Container Registry Repository Reader.'
    }
    else {
        Add-Pass 'The hosted-agent registry pull role uses the least-privilege repository reader definition.'
    }

    foreach ($forbidden in @('deployAdminPanel', 'adminPanelApp', '_deployClassicApps', '_deployAdminPanelApp')) {
        if ($source.Contains($forbidden)) {
            Add-Failure "Forbidden product-topology token '$forbidden' remains in main.bicep."
        }
    }
    if (-not ($failures | Where-Object { $_ -like "Forbidden product-topology token*" })) {
        Add-Pass 'No administrative-panel or workload-removal topology tokens remain.'
    }

    foreach ($outputName in @(
            'AZURE_AI_PROJECT_RESOURCE_ID',
            'AZURE_AI_PROJECT_ENDPOINT',
            'AZURE_CONTAINER_REGISTRY_RESOURCE_ID',
            'AZURE_CONTAINER_REGISTRY_ENDPOINT',
            'HOSTED_AGENT_DEPLOYMENT'
        )) {
        if ($outputName -notin $template.outputs.PSObject.Properties.Name) {
            Add-Failure "Required hosted-agent handoff output '$outputName' is missing."
        }
    }
    if (-not ($failures | Where-Object { $_ -like "Required hosted-agent handoff output*" })) {
        Add-Pass 'Stable Foundry, registry, image/runtime, network, and private-build outputs are present.'
    }

    $registryJson = $template.resources.containerRegistry | ConvertTo-Json -Depth 100 -Compress
    if (-not $registryJson.Contains("variables('_publicNetworkAccess')") -or -not $registryJson.Contains('publicNetworkAccess')) {
        Add-Failure 'Container Registry no longer preserves network-isolation-driven public access controls.'
    }
    else {
        Add-Pass 'Private-registry public access controls remain in the unchanged registry resource.'
    }
}
finally {
    Remove-Item -LiteralPath $compiledFile -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) hosted-agent contract check(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host "`nHosted-agent contract checks passed." -ForegroundColor Green
exit 0
