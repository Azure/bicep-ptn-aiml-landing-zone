<#
.SYNOPSIS
    Pre-flight validation for AI Landing Zone deployments.

.DESCRIPTION
    Validates the effective parameter set (azd env + main.parameters.json) BEFORE
    `azd provision` reaches Azure Resource Manager. Catches the common topology
    mistakes that otherwise surface as deep, late, hard-to-debug ARM errors:

      * Conflicting Private DNS settings (policy-managed + BYO overrides at the
        same time)
      * Mutually-exclusive hub-integration parameters
      * Invalid IP allow-list shape
      * Subnet prefixes that overflow the VNet address space or overlap each
        other
      * Subnets too small for the services that consume them
      * Observability parameters that would produce telemetry split-brain
      * BYO resources (VNet, Private DNS zones, Log Analytics, App Insights,
        route table) that the operator promised but that don't actually exist

    The script is **read-only**: it never modifies Azure state. It is safe to
    run from a `preprovision` hook, from CI, or interactively at any time.

.PARAMETER SubscriptionId
    Subscription to perform Azure lookups against. Defaults to the current
    `az account show` subscription.

.PARAMETER AzdEnv
    Name of the azd environment to read values from. Defaults to
    `$env:AZURE_ENV_NAME` (which azd sets), then to the current default env.

.PARAMETER ParametersFile
    Path to `main.parameters.json`. Defaults to the file at the repo root
    relative to this script.

.PARAMETER Strict
    Treat warnings as failures (exit 2 instead of 0 when only warnings are
    reported).

.PARAMETER SkipAzureLookups
    Skip every check that requires an `az` call. Use for offline testing.

.PARAMETER Skip
    Skip all checks. Equivalent to setting `$env:PREFLIGHT_SKIP='true'`.
    Provided as an emergency escape hatch for the `azd` preprovision hook.

.PARAMETER SkipRegional
    Skip only the regional-readiness block (provider/location support,
    jumpbox VM SKU availability, AI model quota, transient capacity warnings).
    Equivalent to setting `$env:LZ_PREFLIGHT_REGIONAL_SKIP='true'`. All other
    deterministic checks still run.

.EXAMPLE
    pwsh ./scripts/Invoke-PreflightChecks.ps1

    Run the default pre-flight against the current azd env.

.EXAMPLE
    pwsh ./scripts/Invoke-PreflightChecks.ps1 -Strict -SkipAzureLookups

    CI mode: only the deterministic parameter checks, fail on warnings.

.NOTES
    Exit codes
        0 — pass (possibly with warnings; warnings non-fatal unless -Strict)
        1 — fatal: at least one FAIL finding
        2 — warnings only, but -Strict was set
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$AzdEnv = $env:AZURE_ENV_NAME,
    [string]$ParametersFile,
    [switch]$Strict,
    [switch]$SkipAzureLookups,
    [switch]$Skip,
    [switch]$SkipRegional
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Emergency bypass
# --------------------------------------------------------------------------
if ($Skip -or $env:PREFLIGHT_SKIP -eq 'true' -or $env:PREFLIGHT_SKIP -eq '1') {
    Write-Host "[preflight] Skipped (PREFLIGHT_SKIP=true)." -ForegroundColor Yellow
    exit 0
}

# --------------------------------------------------------------------------
# Findings accumulator
# --------------------------------------------------------------------------
$script:Findings = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Finding {
    param(
        [Parameter(Mandatory)] [ValidateSet('PASS', 'INFO', 'WARN', 'FAIL')] [string]$Severity,
        [Parameter(Mandatory)] [string]$Code,
        [Parameter(Mandatory)] [string]$Message,
        [string]$Hint
    )
    $script:Findings.Add([pscustomobject]@{
            Severity = $Severity
            Code     = $Code
            Message  = $Message
            Hint     = $Hint
        }) | Out-Null
}

# --------------------------------------------------------------------------
# CIDR helpers (pure PowerShell, no external dependencies)
# --------------------------------------------------------------------------

function ConvertTo-IpUint32 {
    param([string]$Ip)
    $bytes = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
    if ($bytes.Length -ne 4) { throw "Only IPv4 supported; got '$Ip'." }
    [Array]::Reverse($bytes)
    return [System.BitConverter]::ToUInt32($bytes, 0)
}

function Get-CidrRange {
    param([Parameter(Mandatory)] [string]$Cidr)
    $parts = $Cidr -split '/', 2
    $ip = $parts[0]
    $prefix = if ($parts.Count -eq 2) { [int]$parts[1] } else { 32 }
    if ($prefix -lt 0 -or $prefix -gt 32) { throw "Invalid prefix length '$prefix' in '$Cidr'." }
    $ipVal = ConvertTo-IpUint32 -Ip $ip
    if ($prefix -eq 0) {
        $maskVal = [uint32]0
        $size = [uint64]4294967296
    }
    else {
        $hostBitCount = 32 - $prefix
        $hostMax = [uint32]([math]::Pow(2, $hostBitCount) - 1)
        $maskVal = [uint32]([uint64][uint32]::MaxValue - $hostMax)
        $size = [uint64]($hostMax + 1)
    }
    $start = [uint32]($ipVal -band $maskVal)
    $end = [uint32]($start + ($size - 1))
    [pscustomobject]@{ Start = [uint32]$start; End = $end; Prefix = $prefix; Cidr = $Cidr }
}

function Test-CidrOverlap {
    param([string]$A, [string]$B)
    $ra = Get-CidrRange -Cidr $A
    $rb = Get-CidrRange -Cidr $B
    return ($ra.Start -le $rb.End) -and ($rb.Start -le $ra.End)
}

function Test-CidrContains {
    param([string]$Outer, [string]$Inner)
    $ro = Get-CidrRange -Cidr $Outer
    $ri = Get-CidrRange -Cidr $Inner
    return ($ri.Start -ge $ro.Start) -and ($ri.End -le $ro.End)
}

# --------------------------------------------------------------------------
# Parameter resolution: read azd env values, layer over ${VAR=default} substitutions
# --------------------------------------------------------------------------

function Get-AzdEnvValues {
    if (-not (Get-Command azd -ErrorAction SilentlyContinue)) { return @{} }
    try {
        $azdArgs = @('env', 'get-values')
        if ($AzdEnv) { $azdArgs += @('--environment', $AzdEnv) }
        $raw = & azd @azdArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return @{} }
        $h = @{}
        foreach ($line in $raw) {
            if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*"?(.*?)"?\s*$') {
                $h[$matches[1]] = $matches[2]
            }
        }
        return $h
    }
    catch {
        return @{}
    }
}

function Expand-ParamValue {
    param(
        [string]$Raw,
        [hashtable]$EnvValues
    )
    if ($null -eq $Raw) { return $null }
    if ($Raw -isnot [string]) { return $Raw }
    # Match ${NAME} or ${NAME=default}
    $regex = [regex]'\$\{([A-Z0-9_]+)(?:=([^}]*))?\}'
    return $regex.Replace($Raw, {
            param($m)
            $name = $m.Groups[1].Value
            $def = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { '' }
            if ($EnvValues.ContainsKey($name) -and -not [string]::IsNullOrEmpty($EnvValues[$name])) {
                return $EnvValues[$name]
            }
            return $def
        })
}

function Get-EffectiveParameters {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -Path $Path)) {
        Add-Finding -Severity FAIL -Code 'PARAMS_FILE_MISSING' -Message "Parameters file '$Path' not found."
        return @{}
    }
    $jsonRaw = Get-Content -Path $Path -Raw
    try {
        $parsed = $jsonRaw | ConvertFrom-Json
    }
    catch {
        Add-Finding -Severity FAIL -Code 'PARAMS_FILE_INVALID' -Message "Parameters file '$Path' is not valid JSON: $_"
        return @{}
    }
    if (-not $parsed.parameters) {
        Add-Finding -Severity FAIL -Code 'PARAMS_FILE_NO_PARAMETERS' -Message "Parameters file '$Path' has no 'parameters' key."
        return @{}
    }

    $envValues = Get-AzdEnvValues
    $effective = @{}
    $unresolvedRegex = [regex]'\$\{[A-Z0-9_]+\}'

    foreach ($prop in $parsed.parameters.PSObject.Properties) {
        $name = $prop.Name
        $rawVal = $prop.Value.value
        $expanded = Expand-ParamValue -Raw $rawVal -EnvValues $envValues
        if ($expanded -is [string] -and $unresolvedRegex.IsMatch($expanded)) {
            Add-Finding -Severity WARN -Code 'PARAM_UNRESOLVED' `
                -Message "Parameter '$name' still has unresolved environment tokens after substitution: '$expanded'." `
                -Hint "Set the missing env vars via 'azd env set <NAME> <VALUE>', or supply a default in main.parameters.json."
        }
        $effective[$name] = $expanded
    }
    return $effective
}

function ConvertTo-Bool {
    param($V)
    if ($null -eq $V) { return $false }
    if ($V -is [bool]) { return $V }
    if ($V -is [string]) {
        switch ($V.Trim().ToLowerInvariant()) {
            'true' { return $true }
            '1' { return $true }
            'yes' { return $true }
            default { return $false }
        }
    }
    return [bool]$V
}

function Get-StringValue {
    param($V)
    if ($null -eq $V) { return '' }
    if ($V -is [string]) { return $V }
    return [string]$V
}

function Get-ArrayValue {
    param($V)
    if ($null -eq $V) { return @() }
    if ($V -is [System.Collections.IEnumerable] -and $V -isnot [string]) { return @($V) }
    if ($V -is [string]) {
        $s = $V.Trim()
        if ([string]::IsNullOrEmpty($s)) { return @() }
        if ($s.StartsWith('[')) {
            try { return @(($s | ConvertFrom-Json)) } catch { }
        }
        return @($s)
    }
    return @($V)
}

# --------------------------------------------------------------------------
# Deterministic topology checks (no Azure calls)
# --------------------------------------------------------------------------

function Test-Tooling {
    foreach ($t in 'pwsh', 'az') {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
            Add-Finding -Severity FAIL -Code 'TOOL_MISSING' -Message "'$t' is not on PATH." `
                -Hint "Install Azure CLI (https://aka.ms/installazcli) and PowerShell 7 (https://aka.ms/install-pwsh)."
        }
    }
    if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
        Add-Finding -Severity WARN -Code 'AZD_MISSING' -Message "'azd' is not on PATH — env-var values cannot be sourced from the azd environment." `
            -Hint "Install Azure Developer CLI (https://aka.ms/azd-install)."
    }
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Add-Finding -Severity WARN -Code 'PWSH_OLD' -Message "Running on PowerShell $($PSVersionTable.PSVersion). pwsh 7+ is recommended."
    }
}

function Test-Topology {
    param([hashtable]$P)

    # Private DNS conflict: policy-managed + BYO overrides
    $policyMgr = ConvertTo-Bool $P['policyManagedPrivateDns']
    $byoDnsParams = $P.Keys | Where-Object { $_ -like 'existingPrivateDnsZone*ResourceId' }
    $byoDnsSet = @($byoDnsParams | Where-Object { -not [string]::IsNullOrEmpty((Get-StringValue $P[$_])) })
    if ($policyMgr -and $byoDnsSet.Count -gt 0) {
        Add-Finding -Severity FAIL -Code 'DNS_POLICY_VS_BYO' `
            -Message "policyManagedPrivateDns=true conflicts with BYO Private DNS overrides: $($byoDnsSet -join ', ')." `
            -Hint "Pick one: either let policy manage Private DNS (clear all existingPrivateDnsZone*ResourceId), or supply BYO zones explicitly (set policyManagedPrivateDns=false)."
    }

    # Egress mutex
    $egressIp = Get-StringValue $P['hubIntegrationEgressNextHopIp']
    $existingRt = Get-StringValue $P['hubIntegrationExistingRouteTableResourceId']
    if (-not [string]::IsNullOrEmpty($egressIp) -and -not [string]::IsNullOrEmpty($existingRt)) {
        Add-Finding -Severity FAIL -Code 'EGRESS_MUTEX' `
            -Message "hubIntegrationEgressNextHopIp and hubIntegrationExistingRouteTableResourceId are mutually exclusive." `
            -Hint "Either let the spoke deploy its own route table pointing at the hub next-hop IP, OR bring an existing route table — not both."
    }

    # Local firewall + external egress
    $deployFw = ConvertTo-Bool $P['deployAzureFirewall']
    if ($deployFw -and -not [string]::IsNullOrEmpty($egressIp)) {
        Add-Finding -Severity WARN -Code 'FW_AND_EXTERNAL_EGRESS' `
            -Message "deployAzureFirewall=true with hubIntegrationEgressNextHopIp set: a local spoke firewall AND an external egress IP are both configured." `
            -Hint "In ailz-integrated topologies the hub firewall is typically the only egress point — consider deployAzureFirewall=false."
    }

    # deploymentMode = ailz-integrated declared but no hub integration
    $mode = Get-StringValue $P['deploymentMode']
    if ($mode -eq 'ailz-integrated') {
        $hubSignals = @(
            (Get-StringValue $P['hubIntegrationHubVnetResourceId']),
            (Get-StringValue $P['hubIntegrationEgressNextHopIp']),
            (Get-StringValue $P['hubIntegrationExistingRouteTableResourceId'])
        ) | Where-Object { -not [string]::IsNullOrEmpty($_) }
        if ($hubSignals.Count -eq 0) {
            Add-Finding -Severity WARN -Code 'AILZ_NO_HUB_PARAMS' `
                -Message "deploymentMode=ailz-integrated but none of (hubIntegrationHubVnetResourceId, hubIntegrationEgressNextHopIp, hubIntegrationExistingRouteTableResourceId) are set." `
                -Hint "Either set the hub integration parameters or change deploymentMode to 'standalone'."
        }
    }

    # Observability: existing App Insights without connection string
    $hasExistAppI = -not [string]::IsNullOrEmpty((Get-StringValue $P['existingApplicationInsightsResourceId']))
    $hasExistLaw = -not [string]::IsNullOrEmpty((Get-StringValue $P['existingLogAnalyticsWorkspaceResourceId']))
    $hasExistConn = -not [string]::IsNullOrEmpty((Get-StringValue $P['existingApplicationInsightsConnectionString']))
    $allowMixed = ConvertTo-Bool $P['allowMixedObservabilityWorkspaces']

    if ($hasExistAppI -and -not $hasExistConn) {
        Add-Finding -Severity FAIL -Code 'APPI_NO_CONNSTR' `
            -Message "existingApplicationInsightsResourceId is set but existingApplicationInsightsConnectionString is empty." `
            -Hint "Run 'az monitor app-insights component show -g <rg> -a <name> --query connectionString -o tsv' and set EXISTING_APPLICATION_INSIGHTS_CONNECTION_STRING."
    }
    if ($hasExistAppI -and -not $hasExistLaw -and -not $allowMixed) {
        Add-Finding -Severity FAIL -Code 'APPI_NO_LAW' `
            -Message "existingApplicationInsightsResourceId is set without a matching existingLogAnalyticsWorkspaceResourceId." `
            -Hint "Either also set EXISTING_LOG_ANALYTICS_WORKSPACE_RESOURCE_ID to the LAW that backs your App Insights, or set ALLOW_MIXED_OBSERVABILITY_WORKSPACES=true if the split is intentional."
    }

    # Network isolation without any access path
    $netIso = ConvertTo-Bool $P['networkIsolation']
    $deployJump = ConvertTo-Bool $P['deployJumpbox']
    $deployVmLegacy = ConvertTo-Bool $P['deployVM']
    $allowedIps = Get-ArrayValue $P['allowedIpRanges']
    if ($netIso -and -not $deployJump -and -not $deployVmLegacy -and $allowedIps.Count -eq 0) {
        Add-Finding -Severity WARN -Code 'ISO_NO_INGRESS' `
            -Message "networkIsolation=true but no jumpbox/VM is deployed and allowedIpRanges is empty." `
            -Hint "You will not have any way to reach the workload after deployment. Set DEPLOY_JUMPBOX=true, ALLOWED_IP_RANGES=<your-ip>, or plan to use an existing hub jumpbox via EXISTING_JUMPBOX_RESOURCE_ID."
    }
}

function Test-AllowedIpRanges {
    param([hashtable]$P)
    $list = Get-ArrayValue $P['allowedIpRanges']
    if ($list.Count -eq 0) { return }
    foreach ($entry in $list) {
        $cidr = (Get-StringValue $entry).Trim()
        if ([string]::IsNullOrEmpty($cidr)) { continue }
        if ($cidr -eq '0.0.0.0/0' -or $cidr -eq '0.0.0.0') {
            Add-Finding -Severity WARN -Code 'IP_ANY' `
                -Message "allowedIpRanges contains '$cidr' — this is equivalent to no restriction." `
                -Hint "Tighten the allow-list to specific developer or runner CIDRs."
            continue
        }
        if ($cidr -notmatch '^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$') {
            Add-Finding -Severity FAIL -Code 'IP_FORMAT' `
                -Message "allowedIpRanges entry '$cidr' is not a valid IPv4 CIDR." `
                -Hint "Use X.X.X.X or X.X.X.X/Y format."
            continue
        }
        try { Get-CidrRange -Cidr $cidr | Out-Null }
        catch {
            Add-Finding -Severity FAIL -Code 'IP_PARSE' -Message "allowedIpRanges entry '$cidr' did not parse: $_"
        }
    }
}

function Test-LocalCidrSanity {
    param([hashtable]$P)

    $vnetPrefixes = Get-ArrayValue $P['vnetAddressPrefixes'] | ForEach-Object { Get-StringValue $_ } | Where-Object { -not [string]::IsNullOrEmpty($_) }
    if ($vnetPrefixes.Count -eq 0) { return }

    # Validate VNet prefixes themselves
    foreach ($vp in $vnetPrefixes) {
        try { Get-CidrRange -Cidr $vp | Out-Null }
        catch {
            Add-Finding -Severity FAIL -Code 'VNET_CIDR_BAD' -Message "vnetAddressPrefixes entry '$vp' is not a valid CIDR: $_"
            return
        }
    }

    # Collect declared subnet prefixes
    $subnetKeys = @(
        'agentSubnetPrefix',
        'peSubnetPrefix',
        'acaEnvironmentSubnetPrefix',
        'azureBastionSubnetPrefix',
        'azureFirewallSubnetPrefix',
        'jumpboxSubnetPrefix',
        'devopsBuildAgentsSubnetPrefix'
    )
    $subnets = @()
    foreach ($k in $subnetKeys) {
        $v = Get-StringValue $P[$k]
        if ([string]::IsNullOrEmpty($v)) { continue }
        if ($v -notmatch '^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$') {
            Add-Finding -Severity FAIL -Code 'SUBNET_CIDR_BAD' -Message "Subnet '$k' value '$v' is not a valid CIDR."
            continue
        }
        try {
            $r = Get-CidrRange -Cidr $v
            $subnets += [pscustomobject]@{ Name = $k; Cidr = $v; Range = $r }
        }
        catch {
            Add-Finding -Severity FAIL -Code 'SUBNET_CIDR_BAD' -Message "Subnet '$k' value '$v' did not parse: $_"
        }
    }

    # Each subnet contained in a vnet prefix
    foreach ($s in $subnets) {
        $contained = $false
        foreach ($vp in $vnetPrefixes) {
            if (Test-CidrContains -Outer $vp -Inner $s.Cidr) { $contained = $true; break }
        }
        if (-not $contained) {
            Add-Finding -Severity FAIL -Code 'SUBNET_OUTSIDE_VNET' `
                -Message "Subnet '$($s.Name)' ($($s.Cidr)) is not contained in any vnetAddressPrefixes entry: $($vnetPrefixes -join ', ')." `
                -Hint "Either widen vnetAddressPrefixes to include this range, or adjust the subnet prefix to fit inside one of the configured VNet ranges."
        }
    }

    # Subnets do not overlap each other
    for ($i = 0; $i -lt $subnets.Count; $i++) {
        for ($j = $i + 1; $j -lt $subnets.Count; $j++) {
            if (Test-CidrOverlap -A $subnets[$i].Cidr -B $subnets[$j].Cidr) {
                Add-Finding -Severity FAIL -Code 'SUBNET_OVERLAP' `
                    -Message "Subnet overlap: '$($subnets[$i].Name)' ($($subnets[$i].Cidr)) overlaps '$($subnets[$j].Name)' ($($subnets[$j].Cidr))." `
                    -Hint "Re-partition the spoke VNet so each subnet has a unique range."
            }
        }
    }

    # Subnet minimum sizes (Azure platform requirements)
    $minPrefix = @{
        'azureBastionSubnetPrefix'      = 26   # Azure Bastion requires /26 or larger
        'azureFirewallSubnetPrefix'     = 26   # Azure Firewall requires /26 or larger
        'peSubnetPrefix'                = 28   # AVM PE requirement; we recommend /27
        'jumpboxSubnetPrefix'           = 29   # one NIC needs only a few addresses
        'devopsBuildAgentsSubnetPrefix' = 28   # build agents typically a handful of VMs
    }
    foreach ($s in $subnets) {
        $req = $minPrefix[$s.Name]
        if ($req -and $s.Range.Prefix -gt $req) {
            Add-Finding -Severity FAIL -Code 'SUBNET_TOO_SMALL' `
                -Message "Subnet '$($s.Name)' ($($s.Cidr)) is /$($s.Range.Prefix); Azure requires at least /$req for this purpose." `
                -Hint "Widen the prefix in main.parameters.json (or via the matching env var)."
        }
    }

    # ACA env subnet sizing — depends on workloadProfiles
    $aca = $subnets | Where-Object { $_.Name -eq 'acaEnvironmentSubnetPrefix' }
    if ($aca) {
        $wpRaw = $P['workloadProfiles']
        $hasWorkloadProfile = $false
        if ($null -ne $wpRaw) {
            $wpArr = @()
            try {
                if ($wpRaw -is [string]) {
                    $s = ($wpRaw -as [string]).Trim()
                    if ($s.StartsWith('[')) { $wpArr = $s | ConvertFrom-Json }
                }
                else { $wpArr = $wpRaw }
            }
            catch {}
            $hasWorkloadProfile = @($wpArr | Where-Object { $_ -and $_.workloadProfileType -and $_.workloadProfileType -ne 'Consumption' }).Count -gt 0
        }
        $required = if ($hasWorkloadProfile) { 27 } else { 27 }  # /27 minimum either way
        $recommended = if ($hasWorkloadProfile) { 23 } else { 27 }
        if ($aca.Range.Prefix -gt $required) {
            Add-Finding -Severity FAIL -Code 'ACA_SUBNET_TOO_SMALL' `
                -Message "acaEnvironmentSubnetPrefix is /$($aca.Range.Prefix); Container Apps environments require at least /$required." `
                -Hint "Widen the prefix."
        }
        elseif ($hasWorkloadProfile -and $aca.Range.Prefix -gt $recommended) {
            Add-Finding -Severity WARN -Code 'ACA_SUBNET_BELOW_RECOMMENDED' `
                -Message "acaEnvironmentSubnetPrefix is /$($aca.Range.Prefix) with workload-profile mode declared; Microsoft recommends /$recommended for workload-profile ACA." `
                -Hint "Consider widening to /$recommended; see https://aka.ms/aca/networking-subnet-size."
        }
    }
}

# --------------------------------------------------------------------------
# Azure lookups (live, optional)
# --------------------------------------------------------------------------

function Invoke-AzCli {
    param([string[]]$Arguments)
    try {
        $out = & az @Arguments 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            return ($out -join "`n" | ConvertFrom-Json)
        }
        return $null
    }
    catch {
        return $null
    }
}

function Test-AzureContext {
    if ($SkipAzureLookups) { return $null }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return $null }
    $ctx = Invoke-AzCli -Arguments @('account', 'show', '-o', 'json')
    if (-not $ctx) {
        Add-Finding -Severity WARN -Code 'AZ_NOT_LOGGED_IN' `
            -Message "Could not determine the current Azure context — Azure resource lookups will be skipped." `
            -Hint "Run 'az login' before deploying."
        return $null
    }
    if ($SubscriptionId -and $ctx.id -ne $SubscriptionId) {
        Add-Finding -Severity WARN -Code 'AZ_SUB_MISMATCH' `
            -Message "Pre-flight is using subscription '$SubscriptionId' but the default az context is '$($ctx.id)'." `
            -Hint "Run 'az account set --subscription $SubscriptionId'."
    }
    return $ctx
}

function Test-AzureResources {
    param([hashtable]$P)

    if ($SkipAzureLookups) {
        Add-Finding -Severity INFO -Code 'AZURE_SKIPPED' -Message "Azure resource lookups skipped (-SkipAzureLookups)."
        return
    }
    $ctx = Test-AzureContext
    if (-not $ctx) { return }

    # BYO VNet (only when useExistingVNet=true)
    $useExistingVNet = ConvertTo-Bool $P['useExistingVNet']
    $deploySubnets = ConvertTo-Bool $P['deploySubnets']
    $existingVnetRid = Get-StringValue $P['existingVnetResourceId']
    if ($useExistingVNet) {
        if ([string]::IsNullOrEmpty($existingVnetRid)) {
            Add-Finding -Severity FAIL -Code 'BYO_VNET_NO_ID' `
                -Message "useExistingVNet=true but existingVnetResourceId is empty." `
                -Hint "Set EXISTING_VNET_RESOURCE_ID to the full ARM resource ID of the spoke VNet."
        }
        else {
            $vnet = Invoke-AzCli -Arguments @('network', 'vnet', 'show', '--ids', $existingVnetRid, '-o', 'json')
            if (-not $vnet) {
                Add-Finding -Severity WARN -Code 'BYO_VNET_LOOKUP_FAILED' `
                    -Message "Could not read existing VNet '$existingVnetRid' — verify the ID is correct and the current identity has Reader on it."
            }
            else {
                # Validate subnets present when deploySubnets=false
                if (-not $deploySubnets) {
                    $requiredSubnets = @{
                        'agentSubnetName'             = (Get-StringValue $P['agentSubnetName'])
                        'peSubnetName'                = (Get-StringValue $P['peSubnetName'])
                        'acaEnvironmentSubnetName'    = (Get-StringValue $P['acaEnvironmentSubnetName'])
                        'jumpboxSubnetName'           = (Get-StringValue $P['jumpboxSubnetName'])
                        'devopsBuildAgentsSubnetName' = (Get-StringValue $P['devopsBuildAgentsSubnetName'])
                    }
                    $deployBastion = ConvertTo-Bool $P['deployBastion']
                    $deployFw = ConvertTo-Bool $P['deployAzureFirewall']
                    if ($deployBastion) { $requiredSubnets['AzureBastionSubnet'] = 'AzureBastionSubnet' }
                    if ($deployFw) { $requiredSubnets['AzureFirewallSubnet'] = 'AzureFirewallSubnet' }

                    $existingNames = @($vnet.subnets | ForEach-Object { $_.name })
                    foreach ($req in $requiredSubnets.GetEnumerator()) {
                        if ([string]::IsNullOrEmpty($req.Value)) { continue }
                        if ($existingNames -notcontains $req.Value) {
                            Add-Finding -Severity FAIL -Code 'BYO_SUBNET_MISSING' `
                                -Message "Subnet '$($req.Value)' (parameter '$($req.Key)') not found in BYO VNet '$($vnet.name)'." `
                                -Hint "Either create the subnet, set DEPLOY_SUBNETS=true to let the deployment create it, or correct the *SubnetName parameter."
                        }
                    }
                    # ACA delegation check
                    $acaName = Get-StringValue $P['acaEnvironmentSubnetName']
                    $deployContainerEnv = ConvertTo-Bool $P['deployContainerEnv']
                    $netIso = ConvertTo-Bool $P['networkIsolation']
                    if ($deployContainerEnv -and $netIso -and (-not [string]::IsNullOrEmpty($acaName))) {
                        $acaSubnet = $vnet.subnets | Where-Object { $_.name -eq $acaName }
                        if ($acaSubnet) {
                            $delegation = $acaSubnet.delegations | Where-Object { $_.serviceName -eq 'Microsoft.App/environments' }
                            if (-not $delegation) {
                                Add-Finding -Severity FAIL -Code 'ACA_SUBNET_NO_DELEGATION' `
                                    -Message "BYO ACA environment subnet '$acaName' is missing delegation 'Microsoft.App/environments'." `
                                    -Hint "Run: az network vnet subnet update --ids <subnetId> --delegations Microsoft.App/environments"
                            }
                            if ($acaSubnet.serviceEndpoints -and @($acaSubnet.serviceEndpoints).Count -gt 0) {
                                Add-Finding -Severity WARN -Code 'ACA_SUBNET_HAS_SE' `
                                    -Message "BYO ACA environment subnet '$acaName' has service endpoints configured. Container Apps does not require any and they can interfere with private-endpoint routing." `
                                    -Hint "Remove service endpoints from this subnet unless you have a deliberate reason to keep them."
                            }
                        }
                    }
                }
            }
        }
    }

    # BYO Private DNS zones — validate naming
    $expectedZoneName = @{
        'existingPrivateDnsZoneCogSvcsResourceId'         = 'privatelink.cognitiveservices.azure.com'
        'existingPrivateDnsZoneOpenAiResourceId'          = 'privatelink.openai.azure.com'
        'existingPrivateDnsZoneAiServicesResourceId'      = 'privatelink.services.ai.azure.com'
        'existingPrivateDnsZoneSearchResourceId'          = 'privatelink.search.windows.net'
        'existingPrivateDnsZoneCosmosResourceId'          = 'privatelink.documents.azure.com'
        # blob/containerApps/acr zones include region/suffix tokens — match by prefix
        'existingPrivateDnsZoneBlobResourceId'            = 'privatelink.blob.'
        'existingPrivateDnsZoneKeyVaultResourceId'        = 'privatelink.vaultcore.azure.net'
        'existingPrivateDnsZoneAppConfigResourceId'       = 'privatelink.azconfig.io'
        'existingPrivateDnsZoneContainerAppsResourceId'   = 'privatelink.'
        'existingPrivateDnsZoneAcrResourceId'             = 'privatelink.'
        'existingPrivateDnsZoneAzureMonitorResourceId'    = 'privatelink.monitor.azure.com'
        'existingPrivateDnsZoneOmsOpsInsightsResourceId'  = 'privatelink.oms.opinsights.azure.com'
        'existingPrivateDnsZoneOdsOpsInsightsResourceId'  = 'privatelink.ods.opinsights.azure.com'
        'existingPrivateDnsZoneAzureAutomationResourceId' = 'privatelink.agentsvc.azure.automation.net'
        'existingPrivateDnsZoneAppInsightsResourceId'     = 'privatelink.applicationinsights.io'
    }
    foreach ($entry in $expectedZoneName.GetEnumerator()) {
        $rid = Get-StringValue $P[$entry.Key]
        if ([string]::IsNullOrEmpty($rid)) { continue }
        $segs = $rid.Trim('/').Split('/')
        if ($segs.Count -lt 8) {
            Add-Finding -Severity FAIL -Code 'DNS_ZONE_RID_BAD' -Message "'$($entry.Key)' value '$rid' is not a valid Private DNS zone resource ID."
            continue
        }
        $zoneName = $segs[-1]
        $expected = $entry.Value
        if ($expected.EndsWith('.')) {
            if (-not $zoneName.StartsWith($expected)) {
                Add-Finding -Severity FAIL -Code 'DNS_ZONE_NAME_MISMATCH' `
                    -Message "'$($entry.Key)' points at zone '$zoneName' but the parameter expects a zone whose name starts with '$expected'." `
                    -Hint "Verify the resource ID points at the correct Private DNS zone."
            }
        }
        else {
            if ($zoneName -ne $expected) {
                Add-Finding -Severity FAIL -Code 'DNS_ZONE_NAME_MISMATCH' `
                    -Message "'$($entry.Key)' points at zone '$zoneName' but the parameter expects '$expected'." `
                    -Hint "Verify the resource ID points at the correct Private DNS zone."
            }
        }
        # Existence check (read-only)
        $zone = Invoke-AzCli -Arguments @('network', 'private-dns', 'zone', 'show', '--ids', $rid, '-o', 'json')
        if (-not $zone) {
            Add-Finding -Severity WARN -Code 'DNS_ZONE_LOOKUP_FAILED' `
                -Message "Could not read Private DNS zone '$rid' — the deployment will fail later if this zone does not exist." `
                -Hint "Verify the ID and that the current identity has Reader on the zone."
        }
    }

    # Existing LAW / App Insights / Route Table / Hub VNet
    foreach ($pair in @(
            @{ Key = 'existingLogAnalyticsWorkspaceResourceId'; Code = 'LAW_LOOKUP_FAILED'; Kind = 'Log Analytics workspace' },
            @{ Key = 'existingApplicationInsightsResourceId'; Code = 'APPI_LOOKUP_FAILED'; Kind = 'Application Insights' },
            @{ Key = 'hubIntegrationExistingRouteTableResourceId'; Code = 'RT_LOOKUP_FAILED'; Kind = 'route table' },
            @{ Key = 'existingBastionResourceId'; Code = 'BASTION_LOOKUP_FAILED'; Kind = 'Bastion host' },
            @{ Key = 'existingNatGatewayResourceId'; Code = 'NATGW_LOOKUP_FAILED'; Kind = 'NAT Gateway' }
        )) {
        $rid = Get-StringValue $P[$pair.Key]
        if ([string]::IsNullOrEmpty($rid)) { continue }
        $resource = Invoke-AzCli -Arguments @('resource', 'show', '--ids', $rid, '-o', 'json')
        if (-not $resource) {
            Add-Finding -Severity WARN -Code $pair.Code `
                -Message "Could not read existing $($pair.Kind) at '$rid' — the deployment will fail later if it does not exist." `
                -Hint "Verify the ID and that the current identity has Reader on the resource."
        }
    }

    # Hub VNet address-space overlap
    $hubRid = Get-StringValue $P['hubIntegrationHubVnetResourceId']
    if (-not [string]::IsNullOrEmpty($hubRid)) {
        $hubVnet = Invoke-AzCli -Arguments @('network', 'vnet', 'show', '--ids', $hubRid, '-o', 'json')
        if (-not $hubVnet) {
            Add-Finding -Severity WARN -Code 'HUB_VNET_LOOKUP_FAILED' `
                -Message "Could not read hub VNet '$hubRid' — address-space overlap detection will be skipped." `
                -Hint "Verify the ID and that the current identity has Reader on the hub VNet's resource group."
        }
        else {
            $spokePrefixes = @(Get-ArrayValue $P['vnetAddressPrefixes'] | ForEach-Object { Get-StringValue $_ } | Where-Object { -not [string]::IsNullOrEmpty($_) })
            $hubPrefixes = @($hubVnet.addressSpace.addressPrefixes)
            foreach ($sp in $spokePrefixes) {
                foreach ($hp in $hubPrefixes) {
                    try {
                        if (Test-CidrOverlap -A $sp -B $hp) {
                            Add-Finding -Severity FAIL -Code 'HUB_SPOKE_OVERLAP' `
                                -Message "Spoke VNet prefix '$sp' overlaps hub VNet prefix '$hp'. Peering will fail." `
                                -Hint "Pick a non-overlapping VNET_ADDRESS_PREFIXES range for the spoke."
                        }
                    }
                    catch { }
                }
            }
        }
    }
}

# --------------------------------------------------------------------------
# Regional readiness (live, optional) — issue #72
# --------------------------------------------------------------------------
#
# Validates that the target region(s) and subscription can actually host the
# resources the landing zone is about to provision. Catches the "azd up returns
# an opaque ARM error 25 minutes in" class of failures by surfacing them as
# pre-flight findings:
#
#   * Subscription drift — `az` CLI default subscription does not match the
#     subscription recorded in the azd environment. Only fires when run from a
#     `preprovision` hook (i.e. an azd env is present).
#   * Provider/location support — for each resource type the landing zone
#     provisions, confirm the provider lists the chosen region as supported.
#   * Transient regional capacity — known to fail at provision time with
#     `InsufficientResourcesAvailable` (Search) or `ServiceUnavailable`
#     (Cosmos DB) even when the region is listed as supported; raised as WARN.
#   * Jumpbox VM SKU availability — when a jumpbox is requested, confirm the
#     requested VM size is offered (and not restricted) in the region for the
#     current subscription.
#   * AI model quota — for each entry in `modelDeploymentList`, call
#     `az cognitiveservices usage list --location <region>` and verify the
#     requested capacity fits in the available quota.
#
# Everything in this block is **read-only** and **non-blocking on WARN**. The
# whole block is skipped when `-SkipRegional`, `-SkipAzureLookups`, or
# `$env:LZ_PREFLIGHT_REGIONAL_SKIP=true` is set.
# --------------------------------------------------------------------------

function Get-NormalizedLocation {
    param([string]$Location)
    if ([string]::IsNullOrWhiteSpace($Location)) { return '' }
    return (($Location -replace '[^A-Za-z0-9]', '').ToLowerInvariant())
}

function Invoke-AzCliRaw {
    # Like Invoke-AzCli, but accepts callers that append their own '-o json' and
    # tolerates az subcommands that print warnings to stderr.
    param([string[]]$Arguments)
    try {
        $out = & az @Arguments 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            return ($out -join "`n" | ConvertFrom-Json)
        }
        return $null
    }
    catch {
        return $null
    }
}

function Test-ProviderLocation {
    param(
        [Parameter(Mandatory)] [string]$ProviderNamespace,
        [Parameter(Mandatory)] [string]$ResourceType,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$CodePrefix
    )
    if ([string]::IsNullOrWhiteSpace($Location)) {
        Add-Finding -Severity WARN -Code "${CodePrefix}_NO_LOCATION" `
            -Message "$DisplayName provider/location check skipped: no location resolved from parameters."
        return
    }
    $provider = Invoke-AzCliRaw -Arguments @('provider', 'show', '--namespace', $ProviderNamespace, '-o', 'json')
    if (-not $provider) {
        Add-Finding -Severity WARN -Code "${CodePrefix}_PROVIDER_LOOKUP" `
            -Message "Could not query provider $ProviderNamespace for $DisplayName." `
            -Hint "Ensure 'az' is logged in and the provider is registered (az provider register --namespace $ProviderNamespace)."
        return
    }
    if ($provider.registrationState -and $provider.registrationState -ne 'Registered') {
        Add-Finding -Severity FAIL -Code "${CodePrefix}_PROVIDER_UNREG" `
            -Message "Provider $ProviderNamespace ($DisplayName) is '$($provider.registrationState)', not 'Registered'." `
            -Hint "Run: az provider register --namespace $ProviderNamespace"
        return
    }
    $rt = @($provider.resourceTypes | Where-Object { $_.resourceType -eq $ResourceType } | Select-Object -First 1)
    if (-not $rt) {
        Add-Finding -Severity WARN -Code "${CodePrefix}_RT_MISSING" `
            -Message "Provider $ProviderNamespace did not report resource type $ResourceType."
        return
    }
    $target = Get-NormalizedLocation $Location
    $supported = @($rt.locations | ForEach-Object { Get-NormalizedLocation $_ }) -contains $target
    if (-not $supported) {
        Add-Finding -Severity FAIL -Code "${CodePrefix}_NOT_IN_REGION" `
            -Message "$DisplayName is not listed as supported in region '$Location' for this subscription." `
            -Hint "Pick a supported region or remove this resource from the deployment."
    }
}

function Test-VmSku {
    param(
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$VmSize
    )
    if ([string]::IsNullOrWhiteSpace($Location) -or [string]::IsNullOrWhiteSpace($VmSize)) { return }
    $skus = Invoke-AzCliRaw -Arguments @('vm', 'list-skus', '--location', $Location, '--size', $VmSize, '--all', '-o', 'json')
    if (-not $skus) {
        Add-Finding -Severity WARN -Code 'JUMPBOX_VM_LOOKUP' `
            -Message "Could not query VM SKU '$VmSize' availability in $Location." `
            -Hint "Run 'az vm list-skus --location $Location --size $VmSize --all' to investigate."
        return
    }
    $match = @($skus | Where-Object { $_.name -eq $VmSize } | Select-Object -First 1)
    if (-not $match) {
        Add-Finding -Severity FAIL -Code 'JUMPBOX_VM_NOT_FOUND' `
            -Message "Jumpbox VM size '$VmSize' is not offered in region '$Location'." `
            -Hint "Pick a different vmSize (AZURE_VM_SIZE) or a region that offers this SKU."
        return
    }
    $restrictions = @()
    if ($match.PSObject.Properties.Name -contains 'restrictions' -and $match.restrictions) {
        $restrictions = @($match.restrictions | Where-Object { $_ })
    }
    if ($restrictions.Count -gt 0) {
        $msgs = $restrictions | ForEach-Object {
            $reason = if ($_.reasonCode) { $_.reasonCode } else { 'Restricted' }
            "$reason ($($_.type): $($_.values -join ','))"
        }
        Add-Finding -Severity FAIL -Code 'JUMPBOX_VM_RESTRICTED' `
            -Message "Jumpbox VM size '$VmSize' is restricted in '${Location}': $($msgs -join '; ')." `
            -Hint "Pick a different vmSize or request a quota increase."
    }
}

function Test-ModelQuota {
    param(
        [Parameter(Mandatory)] $ModelDeployments,
        [Parameter(Mandatory)] [string]$Location
    )
    if ([string]::IsNullOrWhiteSpace($Location)) { return }
    $deployments = @($ModelDeployments | Where-Object { $_ -ne $null })
    if ($deployments.Count -eq 0) { return }

    $usage = Invoke-AzCliRaw -Arguments @('cognitiveservices', 'usage', 'list', '--location', $Location, '-o', 'json')
    if (-not $usage) {
        Add-Finding -Severity WARN -Code 'MODEL_QUOTA_LOOKUP' `
            -Message "Could not read Cognitive Services usage/quota for '$Location'." `
            -Hint "Run 'az cognitiveservices usage list --location $Location' and verify Microsoft.CognitiveServices is registered."
        return
    }

    $failures = @()
    foreach ($d in $deployments) {
        # Only OpenAI-format deployments report quota via usage list
        $fmt = $null
        if ($d.PSObject.Properties.Name -contains 'model' -and $d.model) {
            $fmt = $d.model.format
        }
        if ($fmt -ne 'OpenAI') { continue }

        $modelName = [string]$d.model.name
        $skuName = [string]$d.sku.name
        $capacity = [double]$d.sku.capacity
        $quotaName = "OpenAI.$skuName.$modelName"

        $quota = @($usage | Where-Object { $_.name.value -eq $quotaName } | Select-Object -First 1)
        if (-not $quota) {
            $failures += "No quota entry '$quotaName' in $Location."
            continue
        }
        $available = [double]$quota.limit - [double]$quota.currentValue
        if ($available -lt $capacity) {
            $failures += "$quotaName needs $capacity, $available available (used $($quota.currentValue) / limit $($quota.limit))."
        }
        else {
            Add-Finding -Severity PASS -Code 'MODEL_QUOTA_OK' `
                -Message "Quota OK for ${modelName} (${skuName}) in ${Location}: $available available, $capacity requested."
        }
    }

    if ($failures.Count -gt 0) {
        Add-Finding -Severity FAIL -Code 'MODEL_QUOTA_INSUFFICIENT' `
            -Message ("Insufficient AI model quota in '${Location}': " + ($failures -join ' ')) `
            -Hint "Request a quota increase (https://aka.ms/oai/quotaincrease), reduce sku.capacity in modelDeploymentList, or set AZURE_AI_FOUNDRY_LOCATION to a region with available quota."
    }
}

function Test-RegionalReadiness {
    param([hashtable]$P)

    if ($SkipAzureLookups) { return }
    if ($SkipRegional -or $env:LZ_PREFLIGHT_REGIONAL_SKIP -eq 'true' -or $env:LZ_PREFLIGHT_REGIONAL_SKIP -eq '1') {
        Add-Finding -Severity INFO -Code 'REGIONAL_SKIPPED' `
            -Message "Regional readiness checks skipped (LZ_PREFLIGHT_REGIONAL_SKIP=true)."
        return
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return }

    # Subscription consistency: only when invoked from an azd context where the
    # azd env recorded a subscription. When run standalone (no azd env, or no
    # AZURE_SUBSCRIPTION_ID in it), skip without complaint.
    $envValues = Get-AzdEnvValues
    $azdSubId = if ($envValues.ContainsKey('AZURE_SUBSCRIPTION_ID')) { $envValues['AZURE_SUBSCRIPTION_ID'] } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($azdSubId)) {
        $account = Invoke-AzCliRaw -Arguments @('account', 'show', '-o', 'json')
        if (-not $account) {
            Add-Finding -Severity FAIL -Code 'AZ_LOGIN_REQUIRED' `
                -Message "Azure CLI is not logged in." `
                -Hint "Run 'az login' (and 'az account set --subscription $azdSubId') before deploying."
        }
        elseif ($account.id -ne $azdSubId) {
            Add-Finding -Severity FAIL -Code 'AZ_SUB_DRIFT' `
                -Message "Azure CLI is using subscription '$($account.id)' but the azd environment expects '$azdSubId'." `
                -Hint "Run: az account set --subscription $azdSubId"
        }
    }

    # Resolve locations from the effective parameter set, falling back to the
    # primary `location` when service-specific overrides are empty.
    $location = Get-StringValue $P['location']
    $aiFoundryLocation = Get-StringValue $P['aiFoundryLocation']
    $cosmosLocation = Get-StringValue $P['cosmosLocation']
    if ([string]::IsNullOrWhiteSpace($aiFoundryLocation)) { $aiFoundryLocation = $location }
    if ([string]::IsNullOrWhiteSpace($cosmosLocation)) { $cosmosLocation = $location }

    if ([string]::IsNullOrWhiteSpace($location)) {
        Add-Finding -Severity WARN -Code 'REGIONAL_NO_LOCATION' `
            -Message "Regional readiness checks skipped: 'location' is empty." `
            -Hint "Set AZURE_LOCATION in the azd environment (azd env set AZURE_LOCATION <region>)."
        return
    }

    # Feature-flag resolution. Default-on flags follow main.parameters.json:
    # deployAiFoundry/deployCosmosDb/deployContainerApps/deployContainerEnv default true.
    # deploySearchService is gated by an env var; treat empty as true (matches the file default).
    $deployAiFoundry = ConvertTo-Bool (if ($null -ne $P['deployAiFoundry']) { $P['deployAiFoundry'] } else { $true })
    $deployCosmos = ConvertTo-Bool (if ($null -ne $P['deployCosmosDb']) { $P['deployCosmosDb'] } else { $true })
    $deployContainerApps = ConvertTo-Bool (if ($null -ne $P['deployContainerApps']) { $P['deployContainerApps'] } else { $true })
    $deployContainerEnv = ConvertTo-Bool (if ($null -ne $P['deployContainerEnv']) { $P['deployContainerEnv'] } else { $true })
    $searchRaw = Get-StringValue $P['deploySearchService']
    $deploySearch = if ([string]::IsNullOrWhiteSpace($searchRaw)) { $true } else { ConvertTo-Bool $searchRaw }
    $deployKeyVault = ConvertTo-Bool (if ($null -ne $P['deployKeyVault']) { $P['deployKeyVault'] } else { $true })
    $deployStorage = ConvertTo-Bool (if ($null -ne $P['deployStorageAccount']) { $P['deployStorageAccount'] } else { $true })
    $deployAppConfig = ConvertTo-Bool (if ($null -ne $P['deployAppConfig']) { $P['deployAppConfig'] } else { $true })
    $deployLogAnalytics = ConvertTo-Bool (if ($null -ne $P['deployLogAnalytics']) { $P['deployLogAnalytics'] } else { $true })

    # Provider/location support
    if ($deploySearch) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.Search' -ResourceType 'searchServices' `
            -Location $location -DisplayName 'Azure AI Search' -CodePrefix 'SEARCH'
        Add-Finding -Severity WARN -Code 'SEARCH_CAPACITY' `
            -Message "Azure AI Search transient regional capacity (InsufficientResourcesAvailable) is not exposed by any pre-create quota API; this preflight validates provider/location support only." `
            -Hint "If provisioning fails with InsufficientResourcesAvailable, retry in a different region — see https://azure.github.io/AI-Landing-Zones/bicep/regional-considerations/."
    }
    if ($deployCosmos) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.DocumentDB' -ResourceType 'databaseAccounts' `
            -Location $cosmosLocation -DisplayName 'Azure Cosmos DB' -CodePrefix 'COSMOS'
        Add-Finding -Severity WARN -Code 'COSMOS_CAPACITY' `
            -Message "Cosmos DB transient regional capacity (ServiceUnavailable on high-demand regions) is not exposed by a pre-create quota API; this preflight validates provider/location support only." `
            -Hint "If provisioning fails with ServiceUnavailable, retry in a different region — see https://azure.github.io/AI-Landing-Zones/bicep/regional-considerations/."
    }
    if ($deployContainerApps -or $deployContainerEnv) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.App' -ResourceType 'managedEnvironments' `
            -Location $location -DisplayName 'Azure Container Apps Environment' -CodePrefix 'ACA'
        Add-Finding -Severity WARN -Code 'ACA_WORKLOAD_PROFILE_CAPACITY' `
            -Message "Container Apps workload profiles (D-series/E-series) occasionally hit transient capacity limits in popular regions; this preflight validates provider/location support only." `
            -Hint "If environment creation fails on workload-profile capacity, retry or fall back to the Consumption profile."
    }
    if ($deployAiFoundry) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.CognitiveServices' -ResourceType 'accounts' `
            -Location $aiFoundryLocation -DisplayName 'Azure AI Foundry / Cognitive Services' -CodePrefix 'AIFOUNDRY'
    }
    if ($deployKeyVault) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.KeyVault' -ResourceType 'vaults' `
            -Location $location -DisplayName 'Azure Key Vault' -CodePrefix 'KV'
    }
    if ($deployStorage) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.Storage' -ResourceType 'storageAccounts' `
            -Location $location -DisplayName 'Azure Storage' -CodePrefix 'STORAGE'
    }
    if ($deployAppConfig) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.AppConfiguration' -ResourceType 'configurationStores' `
            -Location $location -DisplayName 'Azure App Configuration' -CodePrefix 'APPCONFIG'
    }
    if ($deployLogAnalytics) {
        Test-ProviderLocation -ProviderNamespace 'Microsoft.OperationalInsights' -ResourceType 'workspaces' `
            -Location $location -DisplayName 'Log Analytics' -CodePrefix 'LAW'
        Test-ProviderLocation -ProviderNamespace 'Microsoft.Insights' -ResourceType 'components' `
            -Location $location -DisplayName 'Application Insights' -CodePrefix 'APPI'
    }

    # Jumpbox VM SKU. deployJumpbox / deployVM are bool? — null means "follow the
    # legacy umbrella". Treat any truthy value as opt-in.
    $deployJump = ConvertTo-Bool $P['deployJumpbox']
    $deployVmLegacy = ConvertTo-Bool $P['deployVM']
    if ($deployJump -or $deployVmLegacy) {
        $vmSize = Get-StringValue $P['vmSize']
        if (-not [string]::IsNullOrWhiteSpace($vmSize)) {
            Test-VmSku -Location $location -VmSize $vmSize
        }
    }

    # Model quota
    if ($deployAiFoundry) {
        $models = $P['modelDeploymentList']
        if ($models) {
            Test-ModelQuota -ModelDeployments $models -Location $aiFoundryLocation
        }
    }
}

# --------------------------------------------------------------------------

function Write-FindingsReport {
    $byCode = $script:Findings | Group-Object -Property Code | ForEach-Object { $_.Group | Select-Object -First 1 }  # one row per code
    $failCount = @($script:Findings | Where-Object Severity -eq 'FAIL').Count
    $warnCount = @($script:Findings | Where-Object Severity -eq 'WARN').Count
    $infoCount = @($script:Findings | Where-Object Severity -eq 'INFO').Count

    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host '  AI Landing Zone — Pre-Flight Check' -ForegroundColor Cyan
    Write-Host '================================================================' -ForegroundColor Cyan

    if ($script:Findings.Count -eq 0) {
        Write-Host '  All checks passed.' -ForegroundColor Green
    }
    else {
        foreach ($f in $script:Findings) {
            $color = switch ($f.Severity) { 'FAIL' { 'Red' } 'WARN' { 'Yellow' } 'INFO' { 'Cyan' } default { 'Gray' } }
            Write-Host ("  [{0,-4}] {1,-30} {2}" -f $f.Severity, $f.Code, $f.Message) -ForegroundColor $color
            if ($f.Hint) {
                Write-Host ("         hint: {0}" -f $f.Hint) -ForegroundColor DarkGray
            }
        }
    }
    Write-Host '----------------------------------------------------------------'
    Write-Host ("  Summary: {0} fail, {1} warn, {2} info" -f $failCount, $warnCount, $infoCount)
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host ''

    if ($failCount -gt 0) { return 1 }
    if ($Strict -and $warnCount -gt 0) { return 2 }
    return 0
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

if (-not $ParametersFile) {
    $ParametersFile = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'main.parameters.json'
}

Write-Host "[preflight] Parameters file: $ParametersFile"
if ($AzdEnv) { Write-Host "[preflight] azd environment: $AzdEnv" }
if ($SkipAzureLookups) { Write-Host "[preflight] Azure lookups: SKIPPED" -ForegroundColor Yellow }

Test-Tooling

$effective = Get-EffectiveParameters -Path $ParametersFile
if ($effective.Count -eq 0) {
    $code = Write-FindingsReport
    exit $code
}

Test-Topology -P $effective
Test-AllowedIpRanges -P $effective
Test-LocalCidrSanity -P $effective
Test-AzureResources -P $effective
Test-RegionalReadiness -P $effective

$exitCode = Write-FindingsReport
exit $exitCode
