<#
.SYNOPSIS
    Rank Azure regions by readiness to host the AI Landing Zone.

.DESCRIPTION
    For each candidate Azure region, checks: VM SKU availability and zones,
    regional vCPU quota headroom, Cosmos DB availability/AZ support, Azure AI
    Search SKU quota, Cognitive Services quota, and registration of the core
    services used by main.bicep. Outputs a sorted readiness ranking with
    per-region issues and a recommended region.

    Requires PowerShell 7+ (uses ForEach-Object -Parallel). The script fails
    fast with a guidance message on Windows PowerShell 5.x.

.PARAMETER VmSku
    Azure VM SKU to check capacity for. Defaults to 'Standard_D2s_v5' to
    match main.bicep's default vmSize.

.PARAMETER SearchSku
    Azure AI Search SKU to check quota for. Defaults to 'standard'.

.PARAMETER RequiredVcpuHeadroom
    Minimum free regional vCPU quota required to mark a region as Ready.

.PARAMETER Regions
    List of Azure regions to evaluate. When omitted, a curated default set is
    used and the user is prompted (interactively) to override with a comma-
    separated list.

.PARAMETER RequireCosmosAz
    When $true (default), only marks regions with Cosmos DB Availability Zone
    support as Ready. Set to $false to relax this requirement.

.PARAMETER EmitPipelineVariable
    Emit an `##vso[task.setvariable]` line for Azure Pipelines so the
    recommended region flows into downstream stages as `bestLocation`.

.PARAMETER NonInteractive
    Suppress the interactive region prompt. Auto-detected when running in CI.

.PARAMETER OutputFormat
    'Table' (default, colored) or 'Json' (machine-readable).

.PARAMETER Top
    Reserved for future use.

.PARAMETER ThrottleLimit
    Parallel worker count for the per-region checks.

.EXAMPLE
    ./azure_region_capacity_checker.ps1
    Runs against the default region set with an interactive prompt for
    custom overrides.

.EXAMPLE
    ./azure_region_capacity_checker.ps1 -Regions eastus2,westeurope -NonInteractive
    Checks only those two regions, no prompt.

.OUTPUTS
    System.Management.Automation.PSCustomObject (Json mode) or formatted
    table output (Table mode).

.NOTES
    Requires Azure CLI signed in (az login) and PowerShell 7+.
#>
[CmdletBinding()]
param(
    [string]$VmSku = 'Standard_D2s_v5',
    [string]$SearchSku = 'standard',
    [int]$RequiredVcpuHeadroom = 8,
    [string[]]$Regions = @(
        'eastus2',
        'swedencentral',
        'uksouth',
        'northeurope',
        'westeurope',
        'francecentral',
        'germanywestcentral',
        'canadacentral',
        'centralus',
        'westus3'
    ),
    [bool]$RequireCosmosAz = $true,
    [switch]$EmitPipelineVariable,
    [switch]$NonInteractive,
    [ValidateSet('Table', 'Json')]
    [string]$OutputFormat = 'Table',
    [int]$Top = 5,
    [int]$ThrottleLimit = 8
)

# This script requires PowerShell 7+ (uses ForEach-Object -Parallel and other v7
# language features). Fail fast in Windows PowerShell 5.x with a clear message
# pointing the user at `pwsh`, instead of letting them hit a cryptic parse error.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host 'ERROR: This script requires PowerShell 7 or later.' -ForegroundColor Red
    Write-Host ("You are running PowerShell {0}." -f $PSVersionTable.PSVersion) -ForegroundColor Red
    Write-Host ''
    Write-Host 'To run it, open a PowerShell 7 (pwsh) terminal and re-invoke the script:' -ForegroundColor Yellow
    Write-Host '  pwsh -NoProfile -ExecutionPolicy Bypass -File ./tools/azure_region_capacity_checker.ps1' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Install PowerShell 7: https://learn.microsoft.com/powershell/scripting/install/installing-powershell' -ForegroundColor DarkGray
    exit 1
}

$ErrorActionPreference = 'Stop'
$script:ProviderCache = @{}
$script:VmSkuCache = $null

function Assert-AzureCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is not installed. Install it first and run az login.'
    }

    az account show --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI is not signed in. Run az login first.'
    }
}

function ConvertTo-NormalizedLocation {
    param([string]$Location)

    return ($Location -replace '\s', '').ToLowerInvariant()
}

function Get-SubscriptionId {
    return (az account show --query id -o tsv)
}

function Get-ProviderLocations {
    param(
        [string]$Namespace,
        [string]$ResourceType
    )

    $key = "$Namespace/$ResourceType"
    if ($script:ProviderCache.ContainsKey($key)) {
        return $script:ProviderCache[$key]
    }

    $raw = az provider show --namespace $Namespace --query "resourceTypes[?resourceType=='$ResourceType'].locations | [0]" -o json 2>$null
    $locations = @()

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($raw)) {
        $parsed = $raw | ConvertFrom-Json
        if ($parsed) {
            $locations = @($parsed | ForEach-Object { ConvertTo-NormalizedLocation $_ } | Sort-Object -Unique)
        }
    }

    $script:ProviderCache[$key] = $locations
    return $locations
}

function Test-ServiceLocation {
    param(
        [string]$Namespace,
        [string]$ResourceType,
        [string]$Location
    )

    $supportedLocations = Get-ProviderLocations -Namespace $Namespace -ResourceType $ResourceType
    $canonical = ConvertTo-NormalizedLocation $Location

    return ($supportedLocations -contains $canonical)
}

function Initialize-VmSkuCache {
    param([string]$Sku)

    if ($script:VmSkuCache) { return }

    Write-Verbose "Prefetching VM SKU data for '$Sku' across all regions (single call)..."
    $raw = az vm list-skus --size $Sku --resource-type virtualMachines --all -o json 2>$null

    $map = @{}
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($raw)) {
        $items = $raw | ConvertFrom-Json
        foreach ($item in @($items)) {
            if ($item.name -ne $Sku) { continue }
            foreach ($loc in @($item.locations)) {
                $key = (ConvertTo-NormalizedLocation $loc)
                $zones = @()
                $locInfo = @($item.locationInfo) | Where-Object { (ConvertTo-NormalizedLocation $_.location) -eq $key } | Select-Object -First 1
                if ($locInfo) { $zones = @($locInfo.zones) }
                $restrictions = @($item.restrictions) | Where-Object {
                    $_.type -eq 'Zone' -or $_.type -eq 'Location' -and (
                        ($null -eq $_.restrictionInfo) -or
                        ($_.restrictionInfo.locations -contains $loc) -or
                        ($_.restrictionInfo.locations -contains $key)
                    )
                }
                $map[$key] = [PSCustomObject]@{
                    Zones = $zones
                    Restrictions = $restrictions
                }
            }
        }
    }

    $script:VmSkuCache = $map
}

function Get-VmReadiness {
    param(
        [string]$Location,
        [string]$Sku
    )

    Initialize-VmSkuCache -Sku $Sku
    $canonical = ConvertTo-NormalizedLocation $Location

    if (-not $script:VmSkuCache.ContainsKey($canonical)) {
        return [PSCustomObject]@{ Status = 'NotListed'; Zones = '-'; Reason = 'SKU not available in this region' }
    }

    $entry = $script:VmSkuCache[$canonical]
    $zones = @($entry.Zones)
    $zoneText = if ($zones.Count -gt 0) { $zones -join ',' } else { '-' }
    $restrictions = @($entry.Restrictions)

    if ($restrictions.Count -gt 0) {
        $reasons = ($restrictions | ForEach-Object { $_.reasonCode } | Sort-Object -Unique) -join ', '
        return [PSCustomObject]@{ Status = 'Restricted'; Zones = $zoneText; Reason = $reasons }
    }

    return [PSCustomObject]@{ Status = 'OK'; Zones = $zoneText; Reason = '' }
}

function Get-ComputeQuotaReadiness {
    param(
        [string]$Location,
        [int]$NeededVcpus
    )

    $canonical = ConvertTo-NormalizedLocation $Location
    $raw = az vm list-usage --location $canonical -o json 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        return [PSCustomObject]@{ Status = 'Unknown'; Available = -1; Limit = -1; Current = -1; Notes = 'Quota query failed' }
    }

    $usage = $raw | ConvertFrom-Json
    $total = $usage | Where-Object { $_.name.localizedValue -eq 'Total Regional vCPUs' -or $_.localName -eq 'Total Regional vCPUs' } | Select-Object -First 1

    if (-not $total) {
        return [PSCustomObject]@{ Status = 'Unknown'; Available = -1; Limit = -1; Current = -1; Notes = 'Regional vCPU quota not found' }
    }

    $available = [int]$total.limit - [int]$total.currentValue
    $status = if ($available -ge $NeededVcpus) { 'OK' } elseif ($available -gt 0) { 'Low' } else { 'Exhausted' }

    return [PSCustomObject]@{
        Status = $status
        Available = $available
        Limit = [int]$total.limit
        Current = [int]$total.currentValue
        Notes = ''
    }
}

function Get-CosmosReadiness {
    param([string]$Location)

    $canonical = ConvertTo-NormalizedLocation $Location
    $raw = az cosmosdb locations show --location $canonical --query "{online:properties.status, az:properties.isSubscriptionRegionAccessAllowedForAz, regular:properties.isSubscriptionRegionAccessAllowedForRegular, supportsAz:properties.supportsAvailabilityZone}" -o json 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        return [PSCustomObject]@{ online = 'Unknown'; az = $false; regular = $false; supportsAz = $false }
    }

    return $raw | ConvertFrom-Json
}

function Get-CognitiveQuotaReadiness {
    param(
        [string]$SubscriptionId,
        [string]$Location
    )

    $canonical = ConvertTo-NormalizedLocation $Location
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CognitiveServices/locations/$canonical/usages?api-version=2023-05-01"
    $raw = az rest --method get --url $url -o json 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        return [PSCustomObject]@{ Status = 'Unknown'; Notes = 'Cognitive quota API not available for this subscription or region' }
    }

    $payload = $raw | ConvertFrom-Json
    $items = @($payload.value)
    if ($items.Count -eq 0) {
        return [PSCustomObject]@{ Status = 'Unknown'; Notes = 'No cognitive usage records returned' }
    }

    $hasHeadroom = $false
    $nearLimit = $false

    foreach ($item in $items) {
        $current = [double]($item.currentValue)
        $limit = [double]($item.limit)

        if ($limit -gt $current) {
            $hasHeadroom = $true
        }

        if ($limit -gt 0 -and (($limit - $current) / $limit) -lt 0.1) {
            $nearLimit = $true
        }
    }

    if ($hasHeadroom -and -not $nearLimit) {
        return [PSCustomObject]@{ Status = 'Headroom'; Notes = 'Cognitive quota headroom detected' }
    }

    if ($hasHeadroom) {
        return [PSCustomObject]@{ Status = 'Tight'; Notes = 'Quota exists but appears close to limit' }
    }

    return [PSCustomObject]@{ Status = 'AtLimit'; Notes = 'No cognitive quota headroom detected' }
}

$scriptStart = Get-Date

try {
    Assert-AzureCli
    $subscriptionId = Get-SubscriptionId

    # -- Interactive region selection ------------------------------------
    # Show the default region set and let the user override with a custom
    # comma-separated list. Skipped automatically when:
    #   * `-Regions` was explicitly passed (programmatic use), or
    #   * `-NonInteractive` was passed, or
    #   * we appear to be running inside CI (Azure Pipelines / GitHub Actions / generic CI).
    $regionsExplicitlyProvided = $PSBoundParameters.ContainsKey('Regions')
    $runningInCi = (-not [string]::IsNullOrWhiteSpace($env:TF_BUILD)) -or `
                   (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTIONS)) -or `
                   (-not [string]::IsNullOrWhiteSpace($env:CI))
    $canPrompt = (-not $NonInteractive) -and (-not $regionsExplicitlyProvided) -and (-not $runningInCi)

    if ($canPrompt) {
        $sortedDefaults = @($Regions | Sort-Object -Unique)
        Write-Host ''
        Write-Host ("Regions that will be checked (defaults, {0} total, alphabetical):" -f $sortedDefaults.Count) -ForegroundColor Cyan
        foreach ($r in $sortedDefaults) {
            Write-Host ("  - {0}" -f $r)
        }
        Write-Host ''
        Write-Host 'Press Enter to use these defaults, or enter a custom comma-separated list of Azure regions.' -ForegroundColor Yellow
        Write-Host 'Example: eastus2,westeurope,southcentralus' -ForegroundColor DarkGray
        $customRegionsInput = Read-Host 'Custom regions (Enter to keep defaults)'

        if (-not [string]::IsNullOrWhiteSpace($customRegionsInput)) {
            $customList = @($customRegionsInput.Split(',') |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($customList.Count -gt 0) {
                $Regions = $customList
                Write-Host ('Using custom regions: ' + ($Regions -join ', ')) -ForegroundColor Green
            }
            else {
                Write-Host 'No valid regions parsed from input; falling back to defaults.' -ForegroundColor DarkYellow
            }
        }
        else {
            Write-Host 'Using default regions.' -ForegroundColor DarkGray
        }
    }

    $serviceChecks = @(
        @{ Name = 'AI Foundry'; Namespace = 'Microsoft.CognitiveServices'; ResourceType = 'accounts' },
        @{ Name = 'Container Apps'; Namespace = 'Microsoft.App'; ResourceType = 'managedEnvironments' },
        @{ Name = 'AI Search'; Namespace = 'Microsoft.Search'; ResourceType = 'searchServices' },
        @{ Name = 'App Config'; Namespace = 'Microsoft.AppConfiguration'; ResourceType = 'configurationStores' },
        @{ Name = 'Storage'; Namespace = 'Microsoft.Storage'; ResourceType = 'storageAccounts' },
        @{ Name = 'Cosmos DB'; Namespace = 'Microsoft.DocumentDB'; ResourceType = 'databaseAccounts' },
        @{ Name = 'Key Vault'; Namespace = 'Microsoft.KeyVault'; ResourceType = 'vaults' },
        @{ Name = 'Container Registry'; Namespace = 'Microsoft.ContainerRegistry'; ResourceType = 'registries' },
        @{ Name = 'Log Analytics'; Namespace = 'Microsoft.OperationalInsights'; ResourceType = 'workspaces' },
        @{ Name = 'App Insights'; Namespace = 'Microsoft.Insights'; ResourceType = 'components' }
    )

    Write-Host ''
    Write-Host 'Azure Region Readiness and Best-Location Check' -ForegroundColor Cyan
    Write-Host "Subscription: $subscriptionId"
    Write-Host "VM SKU: $VmSku"
    Write-Host "Azure Search SKU: $SearchSku"
    Write-Host "Required VM headroom: $RequiredVcpuHeadroom vCPUs"
    Write-Host "Cosmos requirement: $(if ($RequireCosmosAz) { 'Availability Zones required' } else { 'Regular account support only' })"
    Write-Host "Regions to evaluate: $($Regions.Count)"
    Write-Host ''

    # Prefetch global caches once so parallel workers only do per-region calls.
    Write-Verbose 'Prefetching service support data...'
    foreach ($svc in $serviceChecks) {
        [void](Get-ProviderLocations -Namespace $svc.Namespace -ResourceType $svc.ResourceType)
    }
    Initialize-VmSkuCache -Sku $VmSku

    $providerCacheSnapshot = @{}
    foreach ($k in $script:ProviderCache.Keys) { $providerCacheSnapshot[$k] = $script:ProviderCache[$k] }
    $vmSkuCacheSnapshot = @{}
    foreach ($k in $script:VmSkuCache.Keys) { $vmSkuCacheSnapshot[$k] = $script:VmSkuCache[$k] }

    $useParallel = ($PSVersionTable.PSVersion.Major -ge 7)
    Write-Verbose ("Running checks in parallel (throttle={0})..." -f $ThrottleLimit)
    Write-Host ''

    $regionWorker = {
        param($region, $serviceChecks, $providerCache, $vmSkuCache, $subscriptionId, $VmSku, $SearchSku, $RequiredVcpuHeadroom, $RequireCosmosAz)

        function ConvertTo-NormalizedLocation { param([string]$LocationValue) return ($LocationValue -replace '\s','').ToLowerInvariant() }

        $canonical = ConvertTo-NormalizedLocation $region
        $missingServices = @()
        foreach ($svc in $serviceChecks) {
            $key = "$($svc.Namespace)/$($svc.ResourceType)"
            $locs = @()
            if ($providerCache.ContainsKey($key)) { $locs = $providerCache[$key] }
            if ($locs -notcontains $canonical) { $missingServices += $svc.Name }
        }

        # VM SKU readiness from prebuilt cache
        if ($vmSkuCache.ContainsKey($canonical)) {
            $entry = $vmSkuCache[$canonical]
            $zones = @($entry.Zones)
            $zoneText = if ($zones.Count -gt 0) { $zones -join ',' } else { '-' }
            $restrictions = @($entry.Restrictions)
            if ($restrictions.Count -gt 0) {
                $reasons = ($restrictions | ForEach-Object { $_.reasonCode } | Sort-Object -Unique) -join ', '
                $vm = [PSCustomObject]@{ Status = 'Restricted'; Zones = $zoneText; Reason = $reasons }
            } else {
                $vm = [PSCustomObject]@{ Status = 'OK'; Zones = $zoneText; Reason = '' }
            }
        } else {
            $vm = [PSCustomObject]@{ Status = 'NotListed'; Zones = '-'; Reason = 'SKU not available in this region' }
        }

        # Compute quota
        $raw = az vm list-usage --location $canonical -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            $computeQuota = [PSCustomObject]@{ Status = 'Unknown'; Available = -1; Limit = -1; Current = -1; Notes = 'Quota query failed' }
        } else {
            $usage = $raw | ConvertFrom-Json
            $total = $usage | Where-Object { $_.name.localizedValue -eq 'Total Regional vCPUs' -or $_.localName -eq 'Total Regional vCPUs' } | Select-Object -First 1
            if (-not $total) {
                $computeQuota = [PSCustomObject]@{ Status = 'Unknown'; Available = -1; Limit = -1; Current = -1; Notes = 'Regional vCPU quota not found' }
            } else {
                $available = [int]$total.limit - [int]$total.currentValue
                $status = if ($available -ge $RequiredVcpuHeadroom) { 'OK' } elseif ($available -gt 0) { 'Low' } else { 'Exhausted' }
                $computeQuota = [PSCustomObject]@{ Status = $status; Available = $available; Limit = [int]$total.limit; Current = [int]$total.currentValue; Notes = '' }
            }
        }

        # Cosmos readiness
        $raw = az cosmosdb locations show --location $canonical --query "{online:properties.status, az:properties.isSubscriptionRegionAccessAllowedForAz, regular:properties.isSubscriptionRegionAccessAllowedForRegular, supportsAz:properties.supportsAvailabilityZone}" -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            $cosmos = [PSCustomObject]@{ online = 'Unknown'; az = $false; regular = $false; supportsAz = $false }
        } else {
            $cosmos = $raw | ConvertFrom-Json
        }

        # Cognitive quota
        $url = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.CognitiveServices/locations/$canonical/usages?api-version=2023-05-01"
        $raw = az rest --method get --url $url -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            $cognitiveQuota = [PSCustomObject]@{ Status = 'Unknown'; Notes = 'Cognitive quota API not available' }
        } else {
            $payload = $raw | ConvertFrom-Json
            $items = @($payload.value)
            if ($items.Count -eq 0) {
                $cognitiveQuota = [PSCustomObject]@{ Status = 'Unknown'; Notes = 'No cognitive usage records returned' }
            } else {
                $hasHeadroom = $false; $nearLimit = $false
                foreach ($item in $items) {
                    $c = [double]($item.currentValue); $l = [double]($item.limit)
                    if ($l -gt $c) { $hasHeadroom = $true }
                    if ($l -gt 0 -and (($l - $c) / $l) -lt 0.1) { $nearLimit = $true }
                }
                if ($hasHeadroom -and -not $nearLimit) {
                    $cognitiveQuota = [PSCustomObject]@{ Status = 'Headroom'; Notes = 'Cognitive quota headroom detected' }
                } elseif ($hasHeadroom) {
                    $cognitiveQuota = [PSCustomObject]@{ Status = 'Tight'; Notes = 'Quota exists but appears close to limit' }
                } else {
                    $cognitiveQuota = [PSCustomObject]@{ Status = 'AtLimit'; Notes = 'No cognitive quota headroom detected' }
                }
            }
        }

        # Azure Search SKU quota/capability
        $searchSkuValue = if ([string]::IsNullOrWhiteSpace($SearchSku)) { 'standard' } else { $SearchSku }
        $searchSkuCanonical = $searchSkuValue.ToLowerInvariant()
        $url = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Search/locations/$canonical/usages?api-version=2025-05-01"
        $raw = az rest --method get --url $url -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            $searchQuota = [PSCustomObject]@{ Status = 'Unknown'; Current = -1; Limit = -1; Notes = 'Azure Search usage API not available' }
        } else {
            $payload = $raw | ConvertFrom-Json
            $items = @($payload.value)
            if ($items.Count -eq 0) {
                $searchQuota = [PSCustomObject]@{ Status = 'Unknown'; Current = -1; Limit = -1; Notes = 'No Azure Search usage records returned' }
            } else {
                $target = $items | Where-Object { ($_.name.value -as [string]).ToLowerInvariant() -eq $searchSkuCanonical } | Select-Object -First 1
                if (-not $target) {
                    $searchQuota = [PSCustomObject]@{ Status = 'Unavailable'; Current = -1; Limit = -1; Notes = "Azure Search SKU '$SearchSku' not listed for this region" }
                } else {
                    $current = [int]$target.currentValue
                    $limit = [int]$target.limit
                    $available = $limit - $current
                    if ($limit -le 0 -or $available -le 0) {
                        $searchQuota = [PSCustomObject]@{ Status = 'AtLimit'; Current = $current; Limit = $limit; Notes = "Azure Search SKU '$SearchSku' quota is unavailable or exhausted" }
                    } else {
                        $ratio = $available / [double]$limit
                        if ($ratio -lt 0.1) {
                            $searchQuota = [PSCustomObject]@{ Status = 'Tight'; Current = $current; Limit = $limit; Notes = "Azure Search SKU '$SearchSku' quota is nearly exhausted" }
                        } else {
                            $searchQuota = [PSCustomObject]@{ Status = 'Headroom'; Current = $current; Limit = $limit; Notes = "Azure Search SKU '$SearchSku' quota headroom detected" }
                        }
                    }
                }
            }
        }

        $cosmosReady = if ($RequireCosmosAz) { ($cosmos.online -eq 'Online') -and [bool]$cosmos.az } else { ($cosmos.online -eq 'Online') -and [bool]$cosmos.regular }
        $serviceReady = ($missingServices.Count -eq 0)

        # Score is 0..100. Weights sum to 100 for a perfect region.
        $score = 0
        # Required services (max 40)
        if ($serviceReady) {
            $score += 40
        }
        else {
            $missingRatio = $missingServices.Count / [double]$serviceChecks.Count
            $score += [int][Math]::Round(40 * (1 - [Math]::Min(1, $missingRatio)))
        }
        # VM SKU availability (max 20)
        switch ($vm.Status) {
            'OK'         { $score += 20 }
            'Restricted' { $score += 8 }
            default      { } # NotListed / Unknown => 0
        }
        # Regional vCPU quota (max 15)
        switch ($computeQuota.Status) {
            'OK'        { $score += 15 }
            'Low'       { $score += 5 }
            'Unknown'   { $score += 10 }
            default     { } # Exhausted => 0
        }
        # Cosmos readiness (max 10)
        if ($cosmosReady) { $score += 10 }
        # Cognitive Services quota (max 7)
        switch ($cognitiveQuota.Status) {
            'Headroom' { $score += 7 }
            'Tight'    { $score += 3 }
            'Unknown'  { $score += 4 }
            default    { } # AtLimit => 0
        }
        # Azure Search quota/capability (max 5)
        switch ($searchQuota.Status) {
            'Headroom'  { $score += 5 }
            'Tight'     { $score += 2 }
            'Unknown'   { $score += 3 }
            default     { } # AtLimit/Unavailable => 0
        }
        # Availability Zones (max 3)
        if ($vm.Zones -ne '-') { $score += 3 }

        if ($score -lt 0)   { $score = 0 }
        if ($score -gt 100) { $score = 100 }

        $recommended = $serviceReady -and ($vm.Status -eq 'OK') -and ($computeQuota.Status -in @('OK', 'Unknown')) -and $cosmosReady -and ($cognitiveQuota.Status -ne 'AtLimit') -and ($searchQuota.Status -notin @('AtLimit', 'Unavailable'))

        $recColor = if ($recommended) { 'Green' } else { 'DarkYellow' }
        Write-Host ("[done] {0} ({1}) => score={2}, VM={3}, vCPUquota={4}, CosmosReady={5}, Cog={6}, Search={7}, recommended={8}" -f $region, $canonical, $score, $vm.Status, $computeQuota.Status, $cosmosReady, $cognitiveQuota.Status, $searchQuota.Status, $recommended) -ForegroundColor $recColor

        [PSCustomObject]@{
            Region = $region
            CanonicalLocation = $canonical
            Recommended = $recommended
            Score = $score
            VmStatus = $vm.Status
            VmZones = $vm.Zones
            VcpuQuota = $computeQuota.Status
            AvailableVcpus = $computeQuota.Available
            CosmosOnline = $cosmos.online
            CosmosReady = $cosmosReady
            CognitiveQuota = $cognitiveQuota.Status
            SearchSkuQuota = $searchQuota.Status
            MissingServices = if ($missingServices.Count -gt 0) { $missingServices -join ', ' } else { '-' }
            Notes = @($vm.Reason, $computeQuota.Notes, $cognitiveQuota.Notes, $searchQuota.Notes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '; '
        }
    }

    if ($useParallel) {
        $workerText = $regionWorker.ToString()
        $report = $Regions | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $region = $_
            $worker = [ScriptBlock]::Create($using:workerText)
            & $worker $region $using:serviceChecks $using:providerCacheSnapshot $using:vmSkuCacheSnapshot $using:subscriptionId $using:VmSku $using:SearchSku $using:RequiredVcpuHeadroom $using:RequireCosmosAz
        }
    }
    else {
        # Unreachable in practice -- the PS7+ guard at the top of the script
        # exits before we get here. Kept as a defensive sequential fallback in
        # case the guard is ever relaxed.
        $report = foreach ($region in $Regions) {
            & $regionWorker $region $serviceChecks $providerCacheSnapshot $vmSkuCacheSnapshot $subscriptionId $VmSku $SearchSku $RequiredVcpuHeadroom $RequireCosmosAz
        }
    }

    $sorted = $report | Sort-Object @{ Expression = 'Recommended'; Descending = $true }, @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'AvailableVcpus'; Descending = $true }, Region

    if ($OutputFormat -eq 'Json') {
        $sorted | ConvertTo-Json -Depth 5
    }
    else {
        function Truncate { param([string]$s, [int]$max)
            if ([string]::IsNullOrEmpty($s)) { return '' }
            if ($s.Length -le $max) { return $s }
            return $s.Substring(0, [Math]::Max(1, $max - 1)) + '~'
        }

        function Write-ColoredTable {
            param(
                [Parameter(Mandatory)] [object[]]$Rows,
                [Parameter(Mandatory)] [hashtable[]]$Columns
            )

            if ($Rows.Count -eq 0) { return }

            $display = foreach ($r in $Rows) {
                $o = [ordered]@{}
                foreach ($c in $Columns) {
                    $o[$c.Header] = Truncate ([string]$r.($c.Source)) $c.Max
                }
                [pscustomobject]@{ Cells = [pscustomobject]$o; Rec = [bool]$r.__RecBool }
            }

            $widths = @{}
            foreach ($c in $Columns) { $widths[$c.Header] = $c.Header.Length }
            foreach ($d in $display) {
                foreach ($c in $Columns) {
                    $len = ([string]$d.Cells.($c.Header)).Length
                    if ($len -gt $widths[$c.Header]) { $widths[$c.Header] = $len }
                }
            }

            $headers = $Columns | ForEach-Object { $_.Header }
            $headerLine    = ($headers | ForEach-Object { $_.PadRight($widths[$_]) }) -join '  '
            $separatorLine = ($headers | ForEach-Object { ('-' * $widths[$_]) }) -join '  '
            Write-Host $headerLine
            Write-Host $separatorLine

            foreach ($d in $display) {
                $line = ($headers | ForEach-Object { ([string]$d.Cells.$_).PadRight($widths[$_]) }) -join '  '
                if ($d.Rec) { Write-Host $line -ForegroundColor Green } else { Write-Host $line }
            }
        }

        # Build human-readable status and issues for each region.
        function Get-RegionIssues {
            param([PSCustomObject]$r)
            $issues = [System.Collections.Generic.List[string]]::new()

            # VM SKU
            switch ($r.VmStatus) {
                'Restricted' { $issues.Add("VM SKU '$VmSku' is restricted ($($r.Notes -replace ';.*',''))") }
                'NotListed'  { $issues.Add("VM SKU '$VmSku' is not available") }
            }

            # vCPU quota
            switch ($r.VcpuQuota) {
                'Exhausted' { $issues.Add("vCPU quota exhausted (0 of $($r.AvailableVcpus) available)") }
                'Low'       { $issues.Add("vCPU quota is low ($($r.AvailableVcpus) available, need $RequiredVcpuHeadroom)") }
                'Unknown'   { $issues.Add('vCPU quota could not be verified') }
            }

            # Cosmos DB
            if (-not $r.CosmosReady) {
                if ($r.CosmosOnline -ne 'Online') {
                    $issues.Add('Cosmos DB is not online in this region')
                } elseif ($RequireCosmosAz) {
                    $issues.Add('Cosmos DB availability-zone support is not enabled for your subscription')
                } else {
                    $issues.Add('Cosmos DB is not accessible for your subscription in this region')
                }
            }

            # Cognitive Services
            switch ($r.CognitiveQuota) {
                'AtLimit' { $issues.Add('AI Services (Cognitive) quota fully consumed') }
                'Tight'   { $issues.Add('AI Services (Cognitive) quota is nearly exhausted') }
                'Unknown' { $issues.Add('AI Services (Cognitive) quota could not be verified') }
            }

            # Azure Search
            switch ($r.SearchSkuQuota) {
                'AtLimit'     { $issues.Add("Azure Search SKU '$SearchSku' quota is exhausted") }
                'Tight'       { $issues.Add("Azure Search SKU '$SearchSku' quota is nearly exhausted") }
                'Unavailable' { $issues.Add("Azure Search SKU '$SearchSku' is unavailable in this region") }
                'Unknown'     { $issues.Add('Azure Search SKU quota could not be verified') }
            }

            # Missing services
            if ($r.MissingServices -and $r.MissingServices -ne '-') {
                $issues.Add("Missing Azure services: $($r.MissingServices)")
            }

            return $issues
        }

        function Get-StatusEmoji {
            param([bool]$ok)
            if ($ok) { return 'Pass' } else { return 'FAIL' }
        }

        $sortedDisplay = $sorted | ForEach-Object {
            $issues = Get-RegionIssues $_
            $statusText = if ([bool]$_.Recommended) { 'Ready' } else { 'Not Ready' }
            $issuesSummary = if ($issues.Count -eq 0) { 'No issues' } else { $issues -join '; ' }

            [PSCustomObject]@{
                Region            = $_.Region
                Score             = "$($_.Score)/100"
                Status            = $statusText
                'VM SKU'          = $(switch ($_.VmStatus) { 'OK' { 'Available' }; 'Restricted' { 'Restricted' }; default { 'Unavailable' } })
                'VM Zones'        = if ($_.VmZones -ne '-') { $_.VmZones } else { 'None' }
                'vCPU Headroom'   = $(switch ($_.VcpuQuota) { 'OK' { "$($_.AvailableVcpus) available" }; 'Low' { "$($_.AvailableVcpus) (low)" }; 'Exhausted' { 'Exhausted' }; default { 'Unknown' } })
                'Cosmos DB'       = if ([bool]$_.CosmosReady) { 'Ready' } else { 'Not Ready' }
                'AI Services'     = $(switch ($_.CognitiveQuota) { 'Headroom' { 'Available' }; 'Tight' { 'Near Limit' }; 'AtLimit' { 'At Limit' }; default { 'Unknown' } })
                'AI Search'       = $(switch ($_.SearchSkuQuota) { 'Headroom' { 'Available' }; 'Tight' { 'Near Limit' }; 'AtLimit' { 'At Limit' }; 'Unavailable' { 'Unavailable' }; default { 'Unknown' } })
                Issues            = $issuesSummary
                __RecBool         = [bool]$_.Recommended
                __Issues          = $issues
                __Raw             = $_
            }
        }

        $summaryCols = @(
            @{ Header = 'Region';        Source = 'Region';        Max = 20 },
            @{ Header = 'Score';         Source = 'Score';         Max = 7  },
            @{ Header = 'Status';        Source = 'Status';        Max = 10 },
            @{ Header = 'VM SKU';        Source = 'VM SKU';        Max = 12 },
            @{ Header = 'VM Zones';      Source = 'VM Zones';      Max = 8  },
            @{ Header = 'vCPU Headroom'; Source = 'vCPU Headroom'; Max = 16 },
            @{ Header = 'Cosmos DB';     Source = 'Cosmos DB';     Max = 10 },
            @{ Header = 'AI Services';   Source = 'AI Services';   Max = 11 },
            @{ Header = 'AI Search';     Source = 'AI Search';     Max = 11 }
        )

        Write-Host ''
        Write-Host '===========================================' -ForegroundColor Cyan
        Write-Host '  Region Readiness Summary' -ForegroundColor Cyan
        Write-Host '===========================================' -ForegroundColor Cyan
        Write-Host ''
        Write-ColoredTable -Rows @($sortedDisplay) -Columns $summaryCols

        # Per-region issue details for regions with problems.
        $problemRegions = @($sortedDisplay | Where-Object { $_.Status -eq 'Not Ready' })
        if ($problemRegions.Count -gt 0) {
            Write-Host ''
            Write-Host '===========================================' -ForegroundColor Yellow
            Write-Host '  Regions With Issues (details)' -ForegroundColor Yellow
            Write-Host '===========================================' -ForegroundColor Yellow

            foreach ($r in $problemRegions) {
                Write-Host ''
                Write-Host "  $($r.Region) " -NoNewline -ForegroundColor White
                Write-Host "(score: $($r.Score))" -ForegroundColor DarkGray
                $idx = 0
                foreach ($issue in $r.__Issues) {
                    $idx++
                    Write-Host "    $idx. $issue" -ForegroundColor Yellow
                }
            }
        }

        # Ready regions quick list.
        $readyRegions = @($sortedDisplay | Where-Object { $_.Status -eq 'Ready' })
        if ($readyRegions.Count -gt 0) {
            Write-Host ''
            Write-Host '===========================================' -ForegroundColor Green
            Write-Host '  Ready Regions (no issues detected)' -ForegroundColor Green
            Write-Host '===========================================' -ForegroundColor Green
            foreach ($r in $readyRegions) {
                Write-Host "    $($r.Region) (score: $($r.Score), zones: $($r.'VM Zones'))" -ForegroundColor Green
            }
        }
    }

    $best = $sorted | Where-Object { $_.Recommended } | Select-Object -First 1
    Write-Host ''

    if ($best) {
        Write-Host '===========================================' -ForegroundColor Green
        Write-Host "  Recommended: $($best.Region)" -ForegroundColor Green
        Write-Host '===========================================' -ForegroundColor Green
        Write-Host "  Score:         $($best.Score)/100" -ForegroundColor Green
        Write-Host "  VM SKU:        $VmSku available" -ForegroundColor Green
        Write-Host "  vCPU Quota:    $($best.VcpuQuota) ($($best.AvailableVcpus) vCPUs free)" -ForegroundColor Green
        Write-Host "  Cosmos DB:     Ready (AZ=$(if ($RequireCosmosAz) { 'required and met' } else { 'not required' }))" -ForegroundColor Green
        Write-Host "  AI Services:   $($best.CognitiveQuota)" -ForegroundColor Green
        Write-Host "  AI Search:     $($best.SearchSkuQuota) (SKU=$SearchSku)" -ForegroundColor Green

        if ($EmitPipelineVariable) {
            Write-Host ''
            Write-Host "##vso[task.setvariable variable=bestLocation]$($best.CanonicalLocation)"
            Write-Host 'Azure DevOps variable emitted: bestLocation' -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '===========================================' -ForegroundColor Red
        Write-Host '  No recommended region found!' -ForegroundColor Red
        Write-Host '===========================================' -ForegroundColor Red
        Write-Warning 'None of the evaluated regions passed all checks. Try a broader region set or relax constraints (e.g. -RequireCosmosAz:$false).'
    }

    Write-Host ''
    Write-Host 'Note: This check reflects current quota and service registration state. Actual deployment may still encounter transient capacity limits.' -ForegroundColor DarkGray
}
catch {
    # Surface as a terminating error from this advanced script (CmdletBinding),
    # so the hosting automation sees a non-zero exit code, the exception, and
    # the inner exception chain. Preferred over `Write-Error + exit 1` per
    # PowerShell cmdlet guidelines.
    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
        $_.Exception,
        'RegionCapacityCheckFailed',
        [System.Management.Automation.ErrorCategory]::OperationStopped,
        $null
    )
    $PSCmdlet.ThrowTerminatingError($errorRecord)
}
finally {
    $duration = (Get-Date) - $scriptStart
    Write-Host ''
    Write-Host ("Script duration: {0:hh\:mm\:ss\.fff} ({1:N1}s)" -f $duration, $duration.TotalSeconds) -ForegroundColor Cyan
}
