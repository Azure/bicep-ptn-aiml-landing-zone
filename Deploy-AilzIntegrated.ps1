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
    [ValidateSet('Full', 'Slim')]
    [string] $PreviewOutput = 'Slim',
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
        'Microsoft.CognitiveServices/accounts/deployments' { ' [Microsoft Foundry model deployment]' }
        default { '' }
    }

    return '{0} : {1}{2}' -f $resourceType, $resourceName, $label
}

function Get-CompiledResourceDeclarations {
    param(
        [Parameter(Mandatory)] $Template,
        [string] $Path = 'main',
        [bool] $AncestorConditional = $false
    )

    $resourcesProperty = $Template.PSObject.Properties['resources']
    if ($null -eq $resourcesProperty) {
        return
    }

    $entries = if ($resourcesProperty.Value -is [pscustomobject]) {
        @($resourcesProperty.Value.PSObject.Properties | ForEach-Object {
                [pscustomobject]@{ Key = $_.Name; Resource = $_.Value }
            })
    }
    else {
        $resourceIndex = 0
        @($resourcesProperty.Value | ForEach-Object {
                [pscustomobject]@{ Key = "resource[$resourceIndex]"; Resource = $_ }
                $resourceIndex++
            })
    }

    foreach ($entry in $entries) {
        $typeProperty = $entry.Resource.PSObject.Properties['type']
        if ($null -eq $typeProperty) {
            continue
        }

        $resourceType = [string]$typeProperty.Value
        $resourcePath = '{0}/{1}' -f $Path, $entry.Key
        $conditionProperty = $entry.Resource.PSObject.Properties['condition']
        $isConditional = $AncestorConditional -or $null -ne $conditionProperty

        if ($resourceType -ieq 'Microsoft.Resources/deployments') {
            $propertiesProperty = $entry.Resource.PSObject.Properties['properties']
            $nestedTemplateProperty = if ($null -ne $propertiesProperty) {
                $propertiesProperty.Value.PSObject.Properties['template']
            }
            if ($null -ne $nestedTemplateProperty) {
                Get-CompiledResourceDeclarations `
                    -Template $nestedTemplateProperty.Value `
                    -Path $resourcePath `
                    -AncestorConditional $isConditional
            }
            continue
        }

        [pscustomobject]@{
            Conditional = $isConditional
            Path        = $resourcePath
            Type        = $resourceType
        }
    }
}

function Get-CompiledResourceDescription {
    param([Parameter(Mandatory)] $Declaration)

    $label = switch ([string]$Declaration.Type) {
        'Microsoft.CognitiveServices/accounts' { ' [Microsoft Foundry account]' }
        'Microsoft.CognitiveServices/accounts/projects' { ' [Microsoft Foundry project]' }
        'Microsoft.CognitiveServices/accounts/deployments' { ' [Microsoft Foundry model deployment]' }
        'Microsoft.CognitiveServices/accounts/capabilityHosts' { ' [Microsoft Foundry account capability host]' }
        'Microsoft.CognitiveServices/accounts/projects/capabilityHosts' { ' [Microsoft Foundry project capability host]' }
        'Microsoft.CognitiveServices/accounts/connections' { ' [Microsoft Foundry connection]' }
        'Microsoft.CognitiveServices/accounts/projects/connections' { ' [Microsoft Foundry project connection]' }
        default { '' }
    }

    return '{0} : {1}{2}' -f $Declaration.Type, $Declaration.Path, $label
}

function Get-WhatIfResourceChanges {
    param([Parameter(Mandatory)] $Node)

    $changes = [System.Collections.Generic.List[object]]::new()
    $visitNode = {
        param($CurrentNode)

        if ($null -eq $CurrentNode -or $CurrentNode -is [string]) {
            return
        }

        if ($CurrentNode -is [System.Collections.IEnumerable] -and $CurrentNode -isnot [pscustomobject]) {
            foreach ($item in $CurrentNode) {
                & $visitNode $item
            }
            return
        }

        $properties = $CurrentNode.PSObject.Properties
        if ($null -ne $properties['resourceId'] -and $null -ne $properties['changeType']) {
            $changes.Add($CurrentNode)
        }

        foreach ($property in $properties) {
            & $visitNode $property.Value
        }
    }

    & $visitNode $Node
    return $changes
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
    $temporaryTemplateFile = (New-TemporaryFile).FullName
    & az bicep build --file $templatePath --outfile $temporaryTemplateFile --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Bicep compilation failed with exit code $LASTEXITCODE."
    }

    $compiledTemplate = Get-Content -Path $temporaryTemplateFile -Raw | ConvertFrom-Json
    foreach ($property in @($parameterDocument.parameters.PSObject.Properties)) {
        $compiledParameter = $compiledTemplate.parameters.PSObject.Properties[$property.Name]
        if ($null -eq $compiledParameter) {
            $parameterDocument.parameters.PSObject.Properties.Remove($property.Name)
            continue
        }

        $typeProperty = $compiledParameter.Value.PSObject.Properties['type']
        if ($null -eq $typeProperty) {
            continue
        }

        $parameterType = [string]$typeProperty.Value
        $nullableProperty = $compiledParameter.Value.PSObject.Properties['nullable']
        $parameterValue = $property.Value.value
        if ($parameterValue -isnot [string]) {
            continue
        }

        $primitiveType = $parameterType.ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($parameterValue) -and $primitiveType -in @('bool', 'int')) {
            $parameterDocument.parameters.PSObject.Properties.Remove($property.Name)
        }
        elseif ($null -ne $nullableProperty -and $nullableProperty.Value -eq $true -and $parameterValue -eq 'null') {
            $property.Value.value = $null
        }
        elseif ($primitiveType -eq 'bool' -and $parameterValue -match '^(true|false)$') {
            $property.Value.value = [bool]::Parse($parameterValue)
        }
        elseif ($primitiveType -eq 'int' -and $parameterValue -match '^-?\d+$') {
            $property.Value.value = [int64]::Parse($parameterValue, [Globalization.CultureInfo]::InvariantCulture)
        }
    }
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
            --result-format FullResourcePayloads `
            --validation-level Template `
            --no-pretty-print `
            --only-show-errors `
            --output json
        if ($LASTEXITCODE -ne 0) {
            throw "Azure What-If failed with exit code $LASTEXITCODE."
        }

        $whatIfResult = ($whatIfOutput -join "`n") | ConvertFrom-Json
        $changes = @(Get-WhatIfResourceChanges -Node $whatIfResult |
            Sort-Object -Property resourceId, changeType -Unique)
        $createCount = @($changes | Where-Object changeType -eq 'Create').Count
        $declarations = @(Get-CompiledResourceDeclarations -Template $compiledTemplate |
            Sort-Object -Property Type, Path)

        Write-Host ''
        Write-Host "ARM What-If resource changes ($($changes.Count) changes; $createCount creates):"
        foreach ($change in $changes) {
            $description = Get-ResourceDescription -ResourceId ([string]$change.resourceId)
            Write-Host ('  {0,-11} {1}' -f ([string]$change.changeType).ToUpperInvariant(), $description)
        }

        Write-Host ''
        Write-Host "Complete compiled nested resource inventory ($($declarations.Count) declarations):"
        Write-Host '  INCLUDED entries are unconditional. CONDITIONAL entries depend on a template or module condition.'
        foreach ($declaration in $declarations) {
            $status = if ($declaration.Conditional) { 'CONDITIONAL' } else { 'INCLUDED' }
            $description = Get-CompiledResourceDescription -Declaration $declaration
            Write-Host ('  {0,-11} {1}' -f $status, $description)
        }
    }
    finally {
        Remove-Item -Path $temporaryParametersFile -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $temporaryTemplateFile -Force -ErrorAction SilentlyContinue
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

    if ($PreviewOutput -eq 'Full') {
        Invoke-CompletePreview -EnvironmentName $EnvironmentName
    }
    else {
        Invoke-Azd -Arguments @('provision', '--preview')
    }
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