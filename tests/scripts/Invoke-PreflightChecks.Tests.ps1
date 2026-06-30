<#
.SYNOPSIS
    Smoke tests for scripts/Invoke-PreflightChecks.ps1.

.DESCRIPTION
    Synthetic-input tests that exercise the deterministic checks (Test-Topology,
    Test-AllowedIpRanges, Test-LocalCidrSanity) without touching Azure.

    Usage:
        pwsh ./tests/scripts/Invoke-PreflightChecks.Tests.ps1

    Exits non-zero on any test failure.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Dot-source the script in test mode by creating a temporary stub that re-exports
# its functions. The real script ends with an `exit` so we cannot dot-source it
# directly. Instead, we use AST parsing to extract the function definitions and
# re-execute them in this scope.

$scriptPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath '..\scripts\Invoke-PreflightChecks.ps1'
$scriptPath = (Resolve-Path -Path $scriptPath).Path
$raw = Get-Content -Path $scriptPath -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$null, [ref]$null)

$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $funcs) {
    Invoke-Expression $f.Extent.Text
}

$script:TestFailures = 0
$script:TestsRun = 0

function Assert-True {
    param([Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] [bool]$Condition, [string]$Reason = '')
    $script:TestsRun++
    if ($Condition) {
        Write-Host ("  [PASS] {0}" -f $Name) -ForegroundColor Green
    }
    else {
        $suffix = if ($Reason) { " - $Reason" } else { '' }
        Write-Host ("  [FAIL] {0}{1}" -f $Name, $suffix) -ForegroundColor Red
        $script:TestFailures++
    }
}

function Reset-Findings {
    $script:Findings = [System.Collections.Generic.List[pscustomobject]]::new()
}

function Test-FindingPresent {
    param([string]$Code)
    return @($script:Findings | Where-Object Code -eq $Code).Count -gt 0
}

function Test-FindingAbsent {
    param([string]$Code)
    return @($script:Findings | Where-Object Code -eq $Code).Count -eq 0
}

# --------------------------------------------------------------------------
Write-Host 'CIDR helpers' -ForegroundColor Cyan

$r = Get-CidrRange -Cidr '192.168.0.0/24'
Assert-True 'Get-CidrRange 192.168.0.0/24 start' ($r.Start -eq (ConvertTo-IpUint32 '192.168.0.0'))
Assert-True 'Get-CidrRange 192.168.0.0/24 end' ($r.End -eq (ConvertTo-IpUint32 '192.168.0.255'))
Assert-True 'Get-CidrRange /0 covers everything' ((Get-CidrRange '0.0.0.0/0').End -eq [uint32]4294967295)

Assert-True 'Overlap detect adjacent /24s' (-not (Test-CidrOverlap '10.0.0.0/24' '10.0.1.0/24'))
Assert-True 'Overlap detect nested' (Test-CidrOverlap '10.0.0.0/16' '10.0.5.0/24')
Assert-True 'Contains: /16 contains /24 inside' (Test-CidrContains '10.0.0.0/16' '10.0.5.0/24')
Assert-True 'Contains: /16 does not contain /24 outside' (-not (Test-CidrContains '10.0.0.0/16' '10.1.0.0/24'))

# --------------------------------------------------------------------------
Write-Host 'Parameter expansion preserves structured values' -ForegroundColor Cyan

$envValues = @{ ENVIRONMENT_NAME = 'ailz-test' }
$expandedString = Expand-ParamValue -Raw 'rg-${ENVIRONMENT_NAME=default}' -EnvValues $envValues
Assert-True 'String parameters still expand env tokens' ($expandedString -eq 'rg-ailz-test')

$objectValue = [pscustomobject]@{ name = 'text-embedding-3-large'; capacity = 100 }
$expandedObject = Expand-ParamValue -Raw $objectValue -EnvValues $envValues
Assert-True 'Object parameter values are preserved' ([object]::ReferenceEquals($objectValue, $expandedObject))

$arrayValue = @(
    [pscustomobject]@{ model = [pscustomobject]@{ format = 'OpenAI'; name = 'text-embedding-3-large' }; sku = [pscustomobject]@{ name = 'Standard'; capacity = 100 } }
)
$expandedArray = Expand-ParamValue -Raw $arrayValue -EnvValues $envValues
Assert-True 'Array parameter values are preserved' (-not ($expandedArray -is [string]) -and @($expandedArray).Count -eq 1 -and $expandedArray[0].model.name -eq 'text-embedding-3-large')

$paramsFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("ailz-preflight-params-{0}.json" -f ([guid]::NewGuid()))
try {
    @'
{
  "parameters": {
    "resourceGroupName": {
      "value": "rg-${ENVIRONMENT_NAME=default}"
    },
    "modelDeploymentList": {
      "value": [
        {
          "model": {
            "format": "OpenAI",
            "name": "text-embedding-3-large"
          },
          "sku": {
            "name": "Standard",
            "capacity": 100
          }
        }
      ]
    }
  }
}
'@ | Set-Content -Path $paramsFile -Encoding utf8
    function Get-AzdEnvValues { return @{ ENVIRONMENT_NAME = 'ailz-test' } }
    Reset-Findings
    $effectiveParams = Get-EffectiveParameters -Path $paramsFile
    Assert-True 'Get-EffectiveParameters expands string values' ($effectiveParams['resourceGroupName'] -eq 'rg-ailz-test')
    Assert-True 'Get-EffectiveParameters preserves modelDeploymentList as array' (-not ($effectiveParams['modelDeploymentList'] -is [string]) -and @($effectiveParams['modelDeploymentList']).Count -eq 1 -and $effectiveParams['modelDeploymentList'][0].sku.capacity -eq 100)
}
finally {
    Remove-Item -Path $paramsFile -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
Write-Host 'Topology: policy + BYO DNS conflict' -ForegroundColor Cyan
Reset-Findings
Test-Topology -P @{
    policyManagedPrivateDns                  = $true
    existingPrivateDnsZoneOpenAiResourceId   = '/subscriptions/x/resourceGroups/y/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com'
    deploymentMode                           = 'standalone'
}
Assert-True 'FAIL DNS_POLICY_VS_BYO raised' (Test-FindingPresent 'DNS_POLICY_VS_BYO')

# --------------------------------------------------------------------------
Write-Host 'Topology: hub egress + existing RT mutex' -ForegroundColor Cyan
Reset-Findings
Test-Topology -P @{
    hubIntegrationEgressNextHopIp              = '10.100.0.4'
    hubIntegrationExistingRouteTableResourceId = '/subscriptions/x/resourceGroups/y/providers/Microsoft.Network/routeTables/rt-1'
    deploymentMode                             = 'ailz-integrated'
}
Assert-True 'FAIL EGRESS_MUTEX raised' (Test-FindingPresent 'EGRESS_MUTEX')

# --------------------------------------------------------------------------
Write-Host 'Topology: deployAzureFirewall + hub egress IP warns' -ForegroundColor Cyan
Reset-Findings
Test-Topology -P @{
    deployAzureFirewall              = $true
    hubIntegrationEgressNextHopIp    = '10.100.0.4'
}
Assert-True 'WARN FW_AND_EXTERNAL_EGRESS raised' (Test-FindingPresent 'FW_AND_EXTERNAL_EGRESS')

# --------------------------------------------------------------------------
Write-Host 'Topology: ailz-integrated without hub params warns' -ForegroundColor Cyan
Reset-Findings
Test-Topology -P @{
    deploymentMode = 'ailz-integrated'
}
Assert-True 'WARN AILZ_NO_HUB_PARAMS raised' (Test-FindingPresent 'AILZ_NO_HUB_PARAMS')

# --------------------------------------------------------------------------
Write-Host 'Topology: existing AppI without connection string fails' -ForegroundColor Cyan
Reset-Findings
Test-Topology -P @{
    existingApplicationInsightsResourceId      = '/subscriptions/x/resourceGroups/y/providers/Microsoft.Insights/components/appi-1'
    existingLogAnalyticsWorkspaceResourceId    = '/subscriptions/x/resourceGroups/y/providers/Microsoft.OperationalInsights/workspaces/law-1'
    existingApplicationInsightsConnectionString = ''
}
Assert-True 'FAIL APPI_NO_CONNSTR raised' (Test-FindingPresent 'APPI_NO_CONNSTR')

# --------------------------------------------------------------------------
Write-Host 'Topology: existing AppI without existing LAW (mixed not allowed) fails' -ForegroundColor Cyan
Reset-Findings
Test-Topology -P @{
    existingApplicationInsightsResourceId       = '/subscriptions/x/resourceGroups/y/providers/Microsoft.Insights/components/appi-1'
    existingApplicationInsightsConnectionString = 'InstrumentationKey=xxx;IngestionEndpoint=https://eastus.in.applicationinsights.azure.com'
    allowMixedObservabilityWorkspaces           = $false
}
Assert-True 'FAIL APPI_NO_LAW raised' (Test-FindingPresent 'APPI_NO_LAW')

# --------------------------------------------------------------------------
Write-Host 'Topology: existing AppI without LAW + mixed allowed is OK' -ForegroundColor Cyan
Reset-Findings
Test-Topology -P @{
    existingApplicationInsightsResourceId       = '/subscriptions/x/resourceGroups/y/providers/Microsoft.Insights/components/appi-1'
    existingApplicationInsightsConnectionString = 'InstrumentationKey=xxx;IngestionEndpoint=https://eastus.in.applicationinsights.azure.com'
    allowMixedObservabilityWorkspaces           = $true
}
Assert-True 'No APPI_NO_LAW when mixed allowed' (Test-FindingAbsent 'APPI_NO_LAW')

# --------------------------------------------------------------------------
Write-Host 'Topology: networkIsolation without ingress warns' -ForegroundColor Cyan
Reset-Findings
Test-Topology -P @{
    networkIsolation  = $true
    deployJumpbox     = $false
    deployVM          = $false
    allowedIpRanges   = @()
}
Assert-True 'WARN ISO_NO_INGRESS raised' (Test-FindingPresent 'ISO_NO_INGRESS')

# --------------------------------------------------------------------------
Write-Host 'IP allow-list: invalid CIDR' -ForegroundColor Cyan
Reset-Findings
Test-AllowedIpRanges -P @{ allowedIpRanges = @('not-a-cidr', '10.0.0.0/8') }
Assert-True 'FAIL IP_FORMAT raised' (Test-FindingPresent 'IP_FORMAT')

# --------------------------------------------------------------------------
Write-Host 'IP allow-list: 0.0.0.0/0 warns' -ForegroundColor Cyan
Reset-Findings
Test-AllowedIpRanges -P @{ allowedIpRanges = @('0.0.0.0/0') }
Assert-True 'WARN IP_ANY raised' (Test-FindingPresent 'IP_ANY')

# --------------------------------------------------------------------------
Write-Host 'IP allow-list: clean list passes' -ForegroundColor Cyan
Reset-Findings
Test-AllowedIpRanges -P @{ allowedIpRanges = @('203.0.113.5/32', '198.51.100.0/24') }
Assert-True 'No IP findings on clean list' ((@($script:Findings).Count) -eq 0)

# --------------------------------------------------------------------------
Write-Host 'Local CIDR sanity: subnet outside VNet' -ForegroundColor Cyan
Reset-Findings
Test-LocalCidrSanity -P @{
    vnetAddressPrefixes        = @('192.168.0.0/22')
    peSubnetPrefix             = '10.0.0.0/27'   # outside the VNet
    azureBastionSubnetPrefix   = '192.168.2.64/26'
    azureFirewallSubnetPrefix  = '192.168.2.128/26'
    acaEnvironmentSubnetPrefix = '192.168.1.0/24'
}
Assert-True 'FAIL SUBNET_OUTSIDE_VNET raised' (Test-FindingPresent 'SUBNET_OUTSIDE_VNET')

# --------------------------------------------------------------------------
Write-Host 'Local CIDR sanity: overlapping subnets' -ForegroundColor Cyan
Reset-Findings
Test-LocalCidrSanity -P @{
    vnetAddressPrefixes        = @('192.168.0.0/22')
    peSubnetPrefix             = '192.168.2.0/26'
    azureBastionSubnetPrefix   = '192.168.2.0/26'  # collides with pe
    acaEnvironmentSubnetPrefix = '192.168.1.0/24'
}
Assert-True 'FAIL SUBNET_OVERLAP raised' (Test-FindingPresent 'SUBNET_OVERLAP')

# --------------------------------------------------------------------------
Write-Host 'Local CIDR sanity: Bastion subnet too small' -ForegroundColor Cyan
Reset-Findings
Test-LocalCidrSanity -P @{
    vnetAddressPrefixes        = @('192.168.0.0/22')
    azureBastionSubnetPrefix   = '192.168.2.64/28'  # /28 — too small (need /26)
    acaEnvironmentSubnetPrefix = '192.168.1.0/24'
}
Assert-True 'FAIL SUBNET_TOO_SMALL raised for Bastion' (Test-FindingPresent 'SUBNET_TOO_SMALL')

# --------------------------------------------------------------------------
Write-Host 'Local CIDR sanity: defaults pass' -ForegroundColor Cyan
Reset-Findings
Test-LocalCidrSanity -P @{
    vnetAddressPrefixes           = @('192.168.0.0/22')
    agentSubnetPrefix             = '192.168.0.0/24'
    acaEnvironmentSubnetPrefix    = '192.168.1.0/24'
    peSubnetPrefix                = '192.168.2.0/26'
    azureBastionSubnetPrefix      = '192.168.2.64/26'
    azureFirewallSubnetPrefix     = '192.168.2.128/26'
    jumpboxSubnetPrefix           = '192.168.3.64/27'
    devopsBuildAgentsSubnetPrefix = '192.168.3.96/27'
}
Assert-True 'No CIDR findings on default layout' ((@($script:Findings).Count) -eq 0)

# --------------------------------------------------------------------------
Write-Host 'Regional readiness: Get-NormalizedLocation' -ForegroundColor Cyan
Assert-True 'Normalize "East US 2" -> eastus2' ((Get-NormalizedLocation 'East US 2') -eq 'eastus2')
Assert-True 'Normalize empty -> empty' ((Get-NormalizedLocation '') -eq '')

# --------------------------------------------------------------------------
Write-Host 'Regional readiness: env-var skip emits REGIONAL_SKIPPED INFO' -ForegroundColor Cyan
Reset-Findings
$env:LZ_PREFLIGHT_REGIONAL_SKIP = 'true'
$script:SkipAzureLookups = $false
$script:SkipRegional = $false
try {
    Test-RegionalReadiness -P @{ location = 'eastus2' }
}
finally {
    Remove-Item Env:LZ_PREFLIGHT_REGIONAL_SKIP -ErrorAction SilentlyContinue
}
Assert-True 'REGIONAL_SKIPPED INFO present' (Test-FindingPresent 'REGIONAL_SKIPPED')
Assert-True 'Only one finding emitted under skip' (@($script:Findings).Count -eq 1)

# --------------------------------------------------------------------------
Write-Host 'Regional readiness: model quota fails when requested capacity exceeds availability' -ForegroundColor Cyan
Reset-Findings
function Invoke-AzCliRaw {
    param([string[]]$Arguments)
    if (($Arguments -join ' ') -eq 'cognitiveservices usage list --location westus3 -o json') {
        return @(
            [pscustomobject]@{
                name         = [pscustomobject]@{ value = 'OpenAI.Standard.text-embedding-3-large' }
                currentValue = 300
                limit        = 350
            }
        )
    }
    return $null
}
Test-ModelQuota -Location 'westus3' -ModelDeployments @(
    [pscustomobject]@{
        model = [pscustomobject]@{
            format = 'OpenAI'
            name   = 'text-embedding-3-large'
        }
        sku   = [pscustomobject]@{
            name     = 'Standard'
            capacity = 100
        }
    }
)
Assert-True 'MODEL_QUOTA_INSUFFICIENT FAIL raised' (Test-FindingPresent 'MODEL_QUOTA_INSUFFICIENT')

# --------------------------------------------------------------------------
Write-Host 'Regional readiness: -SkipAzureLookups suppresses block entirely' -ForegroundColor Cyan
Reset-Findings
$script:SkipAzureLookups = $true
try {
    Test-RegionalReadiness -P @{ location = 'eastus2'; deployAiFoundry = $true; modelDeploymentList = @() }
}
finally {
    $script:SkipAzureLookups = $false
}
Assert-True 'No findings emitted under SkipAzureLookups' (@($script:Findings).Count -eq 0)

# --------------------------------------------------------------------------
Write-Host 'Regional readiness: missing location emits REGIONAL_NO_LOCATION WARN' -ForegroundColor Cyan
Reset-Findings
# Stub az lookups so we don't actually call the CLI.
function Invoke-AzCliRaw { param([string[]]$Arguments) return $null }
function Get-AzdEnvValues { return @{} }
$script:SkipAzureLookups = $false
$script:SkipRegional = $false
Test-RegionalReadiness -P @{ location = '' }
Assert-True 'REGIONAL_NO_LOCATION WARN raised' (Test-FindingPresent 'REGIONAL_NO_LOCATION')

# --------------------------------------------------------------------------
Write-Host ''
Write-Host ("Tests run: $script:TestsRun  Failures: $script:TestFailures") -ForegroundColor Cyan

if ($script:TestFailures -gt 0) { exit 1 } else { exit 0 }
