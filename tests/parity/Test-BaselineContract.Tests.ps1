<#
.SYNOPSIS
    Prevents manifest or parity baselines from advancing silently.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$manifest = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
$config = Get-Content (Join-Path $root 'parity\config.json') -Raw | ConvertFrom-Json
$inventory = Get-Content (Join-Path $root 'parity\inventory.json') -Raw | ConvertFrom-Json

if (
    $manifest.tag -ne 'v2.6.1' -or $manifest.ailz_tag -ne 'v2.6.1' -or
    $config.repositories.source.releaseTag -ne $manifest.tag -or
    $inventory.baseline.source.releaseTag -ne $manifest.tag -or
    $config.repositories.source.commitSha -ne '64195c01b70974fa7256c2f54a0035fb06804139' -or
    $config.repositories.terraform.commitSha -ne 'abe337894f93de3ddda525ea44898b33e1484070' -or
    $inventory.baseline.source.commitSha -ne $config.repositories.source.commitSha -or
    $inventory.baseline.terraform.commitSha -ne $config.repositories.terraform.commitSha
) {
    Write-Error 'Manifest, configuration, and inventory must advance together in an explicitly reviewed baseline change.'
    exit 1
}
Write-Host 'Baseline contract passed: manifest and immutable commits remain pinned.'
exit 0
