<#
.SYNOPSIS
    Verify (and optionally register) Azure resource providers required by the
    AI Landing Zone Bicep template.

.DESCRIPTION
    Reports the RegistrationState of every Azure resource provider used by
    main.bicep and its modules. Fresh subscriptions commonly leave several
    of these in 'NotRegistered' state, which surfaces during `azd provision`
    as opaque ARM errors. Run this script before deploying to surface and
    optionally fix missing registrations.

    Default behavior is report-only. Use -Register to attempt registration
    of any provider not already Registered (idempotent), and -Wait to block
    until each registration completes. Because -Register mutates Azure
    state, the script supports the standard -WhatIf and -Confirm common
    parameters so you can preview or approve each registration.

    Requires PowerShell 7+ and Azure CLI signed in (az login).

.PARAMETER SubscriptionId
    Override the current Azure CLI subscription context.

.PARAMETER Providers
    Optional list of provider namespaces to check. When omitted, the curated
    default set used by main.bicep is checked and the user is prompted to
    override interactively with a comma-separated list.

.PARAMETER Register
    Attempt to register any provider not already Registered. Idempotent;
    safe to re-run.

.PARAMETER Wait
    When used with -Register, block until each provider reaches the
    Registered state (or the per-provider timeout elapses).

.PARAMETER NonInteractive
    Suppress the interactive provider prompt. Auto-detected when running
    inside CI (Azure Pipelines, GitHub Actions, or generic CI).

.PARAMETER TimeoutSeconds
    Per-provider registration timeout when -Wait is used. Default 600s.

.PARAMETER OutputFormat
    'Table' (default, colored) or 'Json' (machine-readable).

.EXAMPLE
    ./check-resource-providers.ps1
    Report-only run against the default provider set, with interactive
    prompt for custom overrides.

.EXAMPLE
    ./check-resource-providers.ps1 -Register -Wait
    Register every missing provider and wait until each one is Registered.

.EXAMPLE
    ./check-resource-providers.ps1 -Register -WhatIf
    Show which providers would be registered, without making any changes.

.EXAMPLE
    ./check-resource-providers.ps1 -Providers Microsoft.CognitiveServices,Microsoft.Search -NonInteractive
    Check only the two specified providers, no prompt.

.OUTPUTS
    System.Management.Automation.PSCustomObject (Json mode) or formatted
    table output (Table mode). Exit code 0 when all required providers are
    Registered (or in-flight), 2 when any provider needs attention, 1 on
    fatal errors.

.NOTES
    Requires PowerShell 7+. The script exits early with a guidance message
    on Windows PowerShell 5.x.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [string]$SubscriptionId,
    [string[]]$Providers,
    [switch]$Register,
    [switch]$Wait,
    [switch]$NonInteractive,
    [int]$TimeoutSeconds = 600,
    [ValidateSet('Table', 'Json')]
    [string]$OutputFormat = 'Table'
)

# This script requires PowerShell 7+. Fail fast in Windows PowerShell 5.x with a
# clear message pointing the user at `pwsh`, instead of a cryptic parse/runtime
# error if a future change introduces PS7-only syntax.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host 'ERROR: This script requires PowerShell 7 or later.' -ForegroundColor Red
    Write-Host ("You are running PowerShell {0}." -f $PSVersionTable.PSVersion) -ForegroundColor Red
    Write-Host ''
    Write-Host 'To run it, open a PowerShell 7 (pwsh) terminal and re-invoke the script:' -ForegroundColor Yellow
    Write-Host '  pwsh -NoProfile -ExecutionPolicy Bypass -File ./tools/check-resource-providers.ps1' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Install PowerShell 7: https://learn.microsoft.com/powershell/scripting/install/installing-powershell' -ForegroundColor DarkGray
    exit 1
}

# Optional prerequisite checker for AI Landing Zone Bicep deployments.
# Verifies that the Azure resource providers required by main.bicep are
# Registered in the target subscription. Fresh subscriptions often have
# several of these in 'NotRegistered' state, which causes opaque
# provisioning failures during `azd provision`.
#
# Default behavior: report only. Use -Register to register any missing
# providers (idempotent). Add -Wait to block until registration completes.

$ErrorActionPreference = 'Stop'

# -- Default provider list ---------------------------------------------
# Derived from resource declarations in main.bicep + modules/.
# Always-needed providers cover the core platform; conditional providers
# cover feature-flagged services (Cosmos, AI Search, Bing, etc.). Keep
# this list inclusive -- registering an unused RP is free and harmless.
$defaultProviders = @(
    @{ Namespace = 'Microsoft.Resources';            Reason = 'Always required (resource group, deployments)' },
    @{ Namespace = 'Microsoft.Authorization';        Reason = 'Role assignments and role definitions' },
    @{ Namespace = 'Microsoft.Network';              Reason = 'VNet, subnets, NSGs, Private DNS, Private Endpoints, Bastion, NAT Gateway, Firewall, App Gateway' },
    @{ Namespace = 'Microsoft.ManagedIdentity';      Reason = 'User-assigned managed identities (useUAI=true and AGW UAI)' },
    @{ Namespace = 'Microsoft.Compute';              Reason = 'Jumpbox VM and VM extensions (deployJumpbox)' },
    @{ Namespace = 'Microsoft.Storage';              Reason = 'Storage accounts (workload + AI Foundry)' },
    @{ Namespace = 'Microsoft.KeyVault';             Reason = 'Key Vault (deployKeyVault / deployVmKeyVault)' },
    @{ Namespace = 'Microsoft.AppConfiguration';     Reason = 'App Configuration store (deployAppConfig)' },
    @{ Namespace = 'Microsoft.OperationalInsights';  Reason = 'Log Analytics workspace (deployLogAnalytics)' },
    @{ Namespace = 'Microsoft.Insights';             Reason = 'Application Insights, diagnostic settings, AMPLS (deployAppInsights / enablePrivateLogAnalytics)' },
    @{ Namespace = 'Microsoft.OperationsManagement'; Reason = 'Log Analytics solutions (LA workspace plumbing)' },
    @{ Namespace = 'Microsoft.AlertsManagement';     Reason = 'Smart detector alerts attached to Application Insights' },
    @{ Namespace = 'Microsoft.App';                  Reason = 'Container Apps + managed environment (deployContainerEnv / deployContainerApps)' },
    @{ Namespace = 'Microsoft.ContainerRegistry';    Reason = 'Azure Container Registry + ACR Tasks agent pool (deployContainerRegistry)' },
    @{ Namespace = 'Microsoft.CognitiveServices';    Reason = 'AI Foundry account/project, AI Services, Speech (deployAiFoundry / deploySpeechService)' },
    @{ Namespace = 'Microsoft.Search';               Reason = 'Azure AI Search (deploySearchService and AI Foundry-bundled search)' },
    @{ Namespace = 'Microsoft.DocumentDB';           Reason = 'Cosmos DB workload account + AI Foundry-bundled Cosmos (deployCosmosDb)' },
    @{ Namespace = 'Microsoft.Bing';                 Reason = 'Bing grounding (deployGroundingWithBing)' }
)

if (-not $Providers -or $Providers.Count -eq 0) {
    $providerSet = $null   # resolved later, after the optional interactive prompt
}
else {
    $providerSet = $Providers | ForEach-Object {
        $userNs = $_
        $match = $defaultProviders | Where-Object { $_.Namespace -eq $userNs } | Select-Object -First 1
        if ($match) { $match } else { @{ Namespace = $userNs; Reason = '(user-provided)' } }
    }
}

function Assert-AzureCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is not installed. Install it first and run az login.'
    }
    az account show --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI is not signed in. Run az login first.'
    }
}

function Resolve-Subscription {
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        az account set --subscription $SubscriptionId | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set Azure subscription to '$SubscriptionId'."
        }
    }
    return (az account show --query id -o tsv)
}

function Get-ProviderState {
    param([string]$Namespace)

    $raw = az provider show --namespace $Namespace --query "{state:registrationState}" -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        return 'Unknown'
    }
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed -or [string]::IsNullOrWhiteSpace($parsed.state)) {
        return 'Unknown'
    }
    return [string]$parsed.state
}

function Register-Provider {
    param([string]$Namespace, [switch]$Wait, [int]$TimeoutSeconds)

    $cmd = @('provider', 'register', '--namespace', $Namespace, '--output', 'none')
    if ($Wait) { $cmd += '--wait' }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    az @cmd 2>$null
    if ($LASTEXITCODE -ne 0) {
        return 'RegisterFailed'
    }

    if (-not $Wait) {
        return Get-ProviderState -Namespace $Namespace
    }

    while ((Get-Date) -lt $deadline) {
        $state = Get-ProviderState -Namespace $Namespace
        if ($state -eq 'Registered') { return 'Registered' }
        Start-Sleep -Seconds 5
    }
    return 'TimedOut'
}

$scriptStart = Get-Date

try {
    Assert-AzureCli
    $resolvedSubscription = Resolve-Subscription

    # -- Interactive provider selection -----------------------------------
    # Show the default provider set and let the user override with a custom
    # comma-separated list. Skipped automatically when:
    #   * `-Providers` was explicitly passed, or
    #   * `-NonInteractive` was passed, or
    #   * we appear to be running inside CI (Azure Pipelines / GitHub Actions / generic CI).
    $providersExplicitlyProvided = $PSBoundParameters.ContainsKey('Providers')
    $runningInCi = (-not [string]::IsNullOrWhiteSpace($env:TF_BUILD)) -or `
                   (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTIONS)) -or `
                   (-not [string]::IsNullOrWhiteSpace($env:CI))
    $canPrompt = (-not $NonInteractive) -and (-not $providersExplicitlyProvided) -and (-not $runningInCi)

    if ($canPrompt) {
        $sortedDefaults = @($defaultProviders | Sort-Object { $_.Namespace })
        $maxNsLen = ($sortedDefaults | ForEach-Object { $_.Namespace.Length } | Measure-Object -Maximum).Maximum
        Write-Host ''
        Write-Host ("Resource providers that will be checked (defaults, {0} total, alphabetical):" -f $sortedDefaults.Count) -ForegroundColor Cyan
        foreach ($p in $sortedDefaults) {
            Write-Host ("  - {0}  -  {1}" -f $p.Namespace.PadRight($maxNsLen), $p.Reason)
        }
        Write-Host ''
        Write-Host 'Press Enter to use these defaults, or enter a custom comma-separated list of resource provider namespaces.' -ForegroundColor Yellow
        Write-Host 'Example: Microsoft.CognitiveServices,Microsoft.Search,Microsoft.App' -ForegroundColor DarkGray
        $customProvidersInput = Read-Host 'Custom providers (Enter to keep defaults)'

        if (-not [string]::IsNullOrWhiteSpace($customProvidersInput)) {
            $customList = @($customProvidersInput.Split(',') |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($customList.Count -gt 0) {
                $providerSet = $customList | ForEach-Object {
                    $userNs = $_
                    $match = $defaultProviders | Where-Object { $_.Namespace -eq $userNs } | Select-Object -First 1
                    if ($match) { $match } else { @{ Namespace = $userNs; Reason = '(user-provided)' } }
                }
                Write-Host ('Using custom providers: ' + (($providerSet | ForEach-Object { $_.Namespace }) -join ', ')) -ForegroundColor Green
            }
            else {
                Write-Host 'No valid providers parsed from input; falling back to defaults.' -ForegroundColor DarkYellow
            }
        }
        else {
            Write-Host 'Using default providers.' -ForegroundColor DarkGray
        }
    }

    # Fall back to defaults if nothing was resolved (no -Providers, no prompt input).
    if ($null -eq $providerSet) {
        $providerSet = $defaultProviders
    }

    Write-Host ''
    Write-Host 'AI Landing Zone -- Resource Provider Prerequisite Check' -ForegroundColor Cyan
    Write-Host "Subscription: $resolvedSubscription"
    Write-Host "Providers to check: $($providerSet.Count)"
    if ($Register) {
        Write-Host "Mode: Register missing providers ($(if ($Wait) { 'waiting up to ' + $TimeoutSeconds + 's per provider' } else { 'fire-and-forget' }))" -ForegroundColor Yellow
    } else {
        Write-Host 'Mode: Report only (use -Register to fix missing providers)' -ForegroundColor DarkGray
    }
    Write-Host ''

    $results = foreach ($entry in $providerSet) {
        $ns = $entry.Namespace
        $reason = $entry.Reason
        $initialState = Get-ProviderState -Namespace $ns
        $action = 'None'
        $finalState = $initialState

        if ($Register -and $initialState -notin @('Registered', 'Registering')) {
            # ShouldProcess enables -WhatIf and -Confirm support: when -WhatIf
            # is supplied, the registration call is skipped and we surface a
            # 'WhatIfSkipped' action so the table still shows the intent.
            if ($PSCmdlet.ShouldProcess($ns, 'Register Azure resource provider')) {
                $action = 'Register'
                $finalState = Register-Provider -Namespace $ns -Wait:$Wait -TimeoutSeconds $TimeoutSeconds
            }
            else {
                $action = 'WhatIfSkipped'
            }
        }

        $ok = ($finalState -eq 'Registered')

        [PSCustomObject]@{
            Namespace    = $ns
            InitialState = $initialState
            Action       = $action
            FinalState   = $finalState
            Ok           = $ok
            Reason       = $reason
        }
    }

    if ($OutputFormat -eq 'Json') {
        $results | ConvertTo-Json -Depth 4
    }
    else {
        $headers = @('Namespace', 'Initial', 'Action', 'Final', 'OK', 'Used for')
        $widths = @{}
        foreach ($h in $headers) { $widths[$h] = $h.Length }
        foreach ($r in $results) {
            $row = @{
                Namespace = $r.Namespace
                Initial   = $r.InitialState
                Action    = $r.Action
                Final     = $r.FinalState
                OK        = if ($r.Ok) { 'Yes' } else { 'No' }
                'Used for' = $r.Reason
            }
            foreach ($h in $headers) {
                $len = ([string]$row[$h]).Length
                if ($len -gt $widths[$h]) { $widths[$h] = $len }
            }
        }

        $headerLine    = ($headers | ForEach-Object { $_.PadRight($widths[$_]) }) -join '  '
        $separatorLine = ($headers | ForEach-Object { ('-' * $widths[$_]) }) -join '  '
        Write-Host $headerLine
        Write-Host $separatorLine
        foreach ($r in $results) {
            $row = @{
                Namespace = $r.Namespace
                Initial   = $r.InitialState
                Action    = $r.Action
                Final     = $r.FinalState
                OK        = if ($r.Ok) { 'Yes' } else { 'No' }
                'Used for' = $r.Reason
            }
            $line = ($headers | ForEach-Object { ([string]$row[$_]).PadRight($widths[$_]) }) -join '  '
            $color = if ($r.Ok) { 'Green' } elseif ($r.FinalState -eq 'Registering') { 'Yellow' } else { 'Red' }
            Write-Host $line -ForegroundColor $color
        }
    }

    $missing = @($results | Where-Object { -not $_.Ok -and $_.FinalState -ne 'Registering' })
    $registering = @($results | Where-Object { $_.FinalState -eq 'Registering' })

    Write-Host ''
    if ($missing.Count -eq 0 -and $registering.Count -eq 0) {
        Write-Host 'All required resource providers are Registered.' -ForegroundColor Green
        $exitCode = 0
    }
    elseif ($registering.Count -gt 0 -and $missing.Count -eq 0) {
        Write-Host ("{0} provider(s) currently Registering -- re-run later or use -Register -Wait." -f $registering.Count) -ForegroundColor Yellow
        $exitCode = 0
    }
    else {
        Write-Host ("{0} provider(s) need attention:" -f $missing.Count) -ForegroundColor Red
        foreach ($m in $missing) {
            Write-Host ("  - {0} (state: {1}) -- {2}" -f $m.Namespace, $m.FinalState, $m.Reason) -ForegroundColor Red
        }
        if (-not $Register) {
            Write-Host ''
            Write-Host 'Re-run with -Register to attempt automatic registration:' -ForegroundColor DarkGray
            Write-Host '  ./tools/check-resource-providers.ps1 -Register -Wait' -ForegroundColor DarkGray
        }
        $exitCode = 2
    }

    exit $exitCode
}
catch {
    # Surface as a terminating error from this advanced script. The hosting
    # automation (Azure DevOps task, etc.) sees a non-zero exit code, the
    # exception, and the inner exception chain.
    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
        $_.Exception,
        'ResourceProviderCheckFailed',
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
