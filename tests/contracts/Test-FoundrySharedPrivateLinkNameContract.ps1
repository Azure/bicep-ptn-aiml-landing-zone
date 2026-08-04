<#
.SYNOPSIS
    Validates Foundry IQ shared private-link resource names stay within Azure's
    60-character limit.

.DESCRIPTION
    Regression test for a network-isolated deployment whose CAF-generated
    Search service name produced a 61-character `foundry_account` shared
    private-link name (and a 71-character `cognitiveservices_account` name).
    The deployment failed only after the other long-running resources had
    provisioned.
#>

[CmdletBinding()]
param(
    [string]$MainFile = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'main.bicep')
)

$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath $MainFile -Raw -Encoding utf8
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

Write-Host 'Foundry IQ shared private-link naming contract' -ForegroundColor Cyan

$expectedTokenDeclaration = @'
var searchFoundrySharedPrivateLinkNameToken = '${take(resourceNames.searchServiceName, 21)}-${take(uniqueString(resourceNames.searchServiceName), 6)}'
'@.Trim()

if (-not $source.Contains($expectedTokenDeclaration)) {
    Add-Failure 'The bounded, collision-resistant Search name token declaration is missing.'
}
else {
    Add-Pass 'The name token is bounded to 28 characters and includes a deterministic hash.'
}

$groups = @(
    'openai_account'
    'foundry_account'
    'cognitiveservices_account'
)
$tokenLength = 21 + 1 + 6
$maxResourceNameLength = 60

foreach ($group in $groups) {
    $expectedName = "name: 'spl-`${searchFoundrySharedPrivateLinkNameToken}-$group-1'"
    if (-not $source.Contains($expectedName)) {
        Add-Failure "Shared private link '$group' does not use the bounded name token."
        continue
    }

    $maximumLength = 'spl-'.Length + $tokenLength + 1 + $group.Length + '-1'.Length
    if ($maximumLength -gt $maxResourceNameLength) {
        Add-Failure "Shared private link '$group' can reach $maximumLength characters."
    }
    else {
        Add-Pass "Shared private link '$group' is bounded to $maximumLength characters."
    }
}

if ($source -match "name:\s*'spl-\`$\{resourceNames\.searchServiceName\}-(?:openai|foundry|cognitiveservices)_account-1'") {
    Add-Failure 'An unbounded Search service name is still used by a Foundry shared private link.'
}
else {
    Add-Pass 'No Foundry shared private link uses the unbounded Search service name.'
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) shared private-link naming contract check(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host "`nFoundry IQ shared private-link naming contract checks passed." -ForegroundColor Green
exit 0
