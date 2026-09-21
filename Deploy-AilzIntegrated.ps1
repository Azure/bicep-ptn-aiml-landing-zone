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

function Get-AzdEnvironmentValues {
    param([Parameter(Mandatory)][string] $EnvironmentName)

    $rawValues = & azd env get-values --environment $EnvironmentName
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read azd environment '$EnvironmentName'."
    }

    $values = @{}
    foreach ($line in $rawValues) {
        if ($line -notmatch '^\s*([A-Z0-9_]+)=(.*)$') {
            continue
        }

        $serializedValue = $matches[2].Trim()
        if ($serializedValue.StartsWith('"') -and $serializedValue.EndsWith('"')) {
            try {
                $values[$matches[1]] = [string]($serializedValue | ConvertFrom-Json)
                continue
            }
            catch {
                throw "Unable to parse azd environment value '$($matches[1])'."
            }
        }

        $values[$matches[1]] = $serializedValue
    }

    return $values
}

function Resolve-AzdParameterValue {
    param(
        $Value,
        [Parameter(Mandatory)][hashtable] $EnvironmentValues
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        $tokenPattern = [regex]'\$\{([A-Z0-9_]+)(?:=([^}]*))?\}'
        return $tokenPattern.Replace($Value, {
                param($match)

                $name = $match.Groups[1].Value
                if ($EnvironmentValues.ContainsKey($name)) {
                    return $EnvironmentValues[$name]
                }

                return $match.Groups[2].Value
            })
    }

    if ($Value -is [System.Collections.IList]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            $Value[$index] = Resolve-AzdParameterValue -Value $Value[$index] -EnvironmentValues $EnvironmentValues
        }
        return ,$Value
    }

    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            $property.Value = Resolve-AzdParameterValue -Value $property.Value -EnvironmentValues $EnvironmentValues
        }
    }

    return $Value
}

function Get-ResourceDescription {
    param([Parameter(Mandatory)][string] $ResourceId)

    $segments = $ResourceId.Trim('/') -split '/'
    $providerIndex = -1
    for ($index = 0; $index -lt $segments.Count; $index++) {
        if ($segments[$index] -ieq 'providers') {
            $providerIndex = $index
        }
    }

    if ($providerIndex -lt 0 -or $providerIndex + 2 -ge $segments.Count) {
        return $ResourceId
    }

    $resourceTypes = [System.Collections.Generic.List[string]]::new()
    $resourceNames = [System.Collections.Generic.List[string]]::new()
    for ($index = $providerIndex + 2; $index -lt $segments.Count; $index += 2) {
        $resourceTypes.Add($segments[$index])
        if ($index + 1 -lt $segments.Count) {
            $resourceNames.Add($segments[$index + 1])
        }
    }

    $resourceType = '{0}/{1}' -f $segments[$providerIndex + 1], ($resourceTypes -join '/')
    $resourceName = $resourceNames -join '/'
    $label = switch ($resourceType) {
        'Microsoft.CognitiveServices/accounts' { ' [Microsoft Foundry account]' }
        'Microsoft.CognitiveServices/accounts/projects' { ' [Microsoft Foundry project]' }
        default { '' }
    }

    return '{0} : {1}{2}' -f $resourceType, $resourceName, $label
}

function Invoke-CompletePreview {
    param([Parameter(Mandatory)][string] $EnvironmentName)

    $environmentValues = Get-AzdEnvironmentValues -EnvironmentName $EnvironmentName
    $resourceGroupName = [string]$environmentValues['AZURE_RESOURCE_GROUP']
    $subscriptionId = [string]$environmentValues['AZURE_SUBSCRIPTION_ID']
    if ([string]::IsNullOrWhiteSpace($resourceGroupName) -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw "The azd environment must define AZURE_RESOURCE_GROUP and AZURE_SUBSCRIPTION_ID."
    }

    $parametersPath = Join-Path $PSScriptRoot 'main.parameters.json'
    $templatePath = Join-Path $PSScriptRoot 'main.bicep'
    $parameterDocument = Get-Content -Path $parametersPath -Raw | ConvertFrom-Json
    $parameterDocument = Resolve-AzdParameterValue -Value $parameterDocument -EnvironmentValues $environmentValues
    $temporaryParametersFile = New-TemporaryFile

    try {
        $parameterDocument | ConvertTo-Json -Depth 100 | Set-Content -Path $temporaryParametersFile -Encoding utf8

        Write-Host ''
        Write-Host 'Generating complete ARM What-If resource inventory...'
        $whatIfOutput = & az deployment group what-if `
            --subscription $subscriptionId `
            --resource-group $resourceGroupName `
            --template-file $templatePath `
            --parameters "@$temporaryParametersFile" `
            --result-format ResourceIdOnly `
            --no-pretty-print `
            --only-show-errors `
            --output json
        if ($LASTEXITCODE -ne 0) {
            throw "Azure What-If failed with exit code $LASTEXITCODE."
        }

        $whatIfResult = ($whatIfOutput -join "`n") | ConvertFrom-Json
        $changes = @($whatIfResult.changes | Sort-Object -Property resourceId, changeType)
        $createCount = @($changes | Where-Object changeType -eq 'Create').Count

        Write-Host ''
        Write-Host "Complete ARM What-If resource inventory ($($changes.Count) changes; $createCount creates):"
        foreach ($change in $changes) {
            $description = Get-ResourceDescription -ResourceId ([string]$change.resourceId)
            Write-Host ('  {0,-11} {1}' -f ([string]$change.changeType).ToUpperInvariant(), $description)
        }
    }
    finally {
        Remove-Item -Path $temporaryParametersFile -Force -ErrorAction SilentlyContinue
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

    Invoke-CompletePreview -EnvironmentName $EnvironmentName
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