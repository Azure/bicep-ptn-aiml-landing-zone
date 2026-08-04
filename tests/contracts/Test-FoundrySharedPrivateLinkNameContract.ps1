<#
.SYNOPSIS
    Validates Foundry IQ shared private-link resource names stay within Azure's
    60-character limit while preserving existing names when they already fit.

.DESCRIPTION
    Regression test for a live network-isolated deployment (Azure/GPT-RAG#592,
    Azure/GPT-RAG#597) whose CAF-generated Search service name produced a
    61-character `foundry_account` shared private-link name (and a
    71-character `cognitiveservices_account` name). The deployment failed only
    after the other long-running resources had provisioned.

    This compiles main.bicep (the "compiled-template" contract) and:
      - Simulates a maximum-length (60-character) Search service name and
        proves all three shared private-link names stay <=60 characters,
        are pairwise distinct, and are deterministic.
      - Replays the exact live-failure Search service name length and proves
        the previously overflowing `foundry_account`/`cognitiveservices_account`
        names are now bounded, while an ordinary/short Search service name
        keeps its plain, pre-existing name unchanged (backward compatibility).
      - Asserts the shared private-link resource's `type`, `apiVersion`,
        `dependsOn`, and `copy` targets are unchanged from the pre-fix
        contract.
#>

[CmdletBinding()]
param(
    [string]$MainFile = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'main.bicep')
)

$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()
$compiledFile = Join-Path ([System.IO.Path]::GetTempPath()) "foundry-spl-name-contract-$([guid]::NewGuid()).json"

function Add-Failure {
    param([Parameter(Mandatory)] [string]$Message)
    $failures.Add($Message) | Out-Null
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Add-Pass {
    param([Parameter(Mandatory)] [string]$Message)
    Write-Host "  [PASS] $Message" -ForegroundColor Green
}

# Mirrors the Bicep expression:
#   '${take(searchServiceName, 21)}-${take(uniqueString(searchServiceName), 6)}'
# uniqueString() always returns a 13-character deterministic hash; take(..., 6)
# always yields exactly 6 characters regardless of its value, so the *length*
# of the token can be computed without reimplementing ARM's uniqueString hash.
function Get-BoundedTokenLength {
    param([Parameter(Mandatory)] [int]$SearchServiceNameLength)
    return [Math]::Min(21, $SearchServiceNameLength) + 1 + 6
}

# Mirrors the Bicep expression:
#   length('spl-${searchServiceName}-${groupId}-1') <= 60
#     ? 'spl-${searchServiceName}-${groupId}-1'
#     : 'spl-${token}-${groupId}-1'
function Get-SharedPrivateLinkNameLength {
    param(
        [Parameter(Mandatory)] [int]$SearchServiceNameLength,
        [Parameter(Mandatory)] [string]$GroupId,
        [int]$MaxLength = 60
    )
    $directLength = 'spl-'.Length + $SearchServiceNameLength + 1 + $GroupId.Length + '-1'.Length
    if ($directLength -le $MaxLength) {
        return @{ Length = $directLength; UsedDirectName = $true }
    }
    $tokenLength = Get-BoundedTokenLength -SearchServiceNameLength $SearchServiceNameLength
    $boundedLength = 'spl-'.Length + $tokenLength + 1 + $GroupId.Length + '-1'.Length
    return @{ Length = $boundedLength; UsedDirectName = $false }
}

Write-Host 'Foundry IQ shared private-link naming contract' -ForegroundColor Cyan

$groups = @(
    'openai_account'
    'foundry_account'
    'cognitiveservices_account'
)
$maxResourceNameLength = 60

try {
    if (Get-Command az -ErrorAction SilentlyContinue) {
        $env:PYTHONIOENCODING = 'utf-8'
        & az bicep build --file $MainFile --outfile $compiledFile
    }
    elseif (Get-Command bicep -ErrorAction SilentlyContinue) {
        & bicep build $MainFile --outfile $compiledFile
    }
    else {
        throw 'Neither bicep nor az is available on PATH.'
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Bicep compilation failed with exit code $LASTEXITCODE."
    }
    $template = Get-Content -LiteralPath $compiledFile -Raw | ConvertFrom-Json -Depth 100

    # --- 1. Compiled-template structural checks -----------------------------

    $tokenExpr = $template.variables.searchFoundrySharedPrivateLinkNameToken
    if ($tokenExpr -notmatch "take\(variables\('resourceNames'\)\.searchServiceName,\s*21\)" -or
        $tokenExpr -notmatch "take\(uniqueString\(variables\('resourceNames'\)\.searchServiceName\),\s*6\)") {
        Add-Failure 'The bounded, collision-resistant Search name token no longer truncates the Search name to 21 characters plus a 6-character deterministic hash.'
    }
    else {
        Add-Pass 'The fallback name token is bounded to 28 characters (21-char Search name prefix + 6-char deterministic hash).'
    }

    if ($tokenExpr -match 'utcNow|newGuid') {
        Add-Failure 'The fallback name token references a non-deterministic ARM function (utcNow/newGuid).'
    }
    else {
        Add-Pass 'The fallback name token uses only deterministic ARM functions (no utcNow/newGuid).'
    }

    if ($template.variables.searchFoundrySharedPrivateLinkMaxNameLength -ne $maxResourceNameLength) {
        Add-Failure "The shared private-link max-name-length variable is $($template.variables.searchFoundrySharedPrivateLinkMaxNameLength), expected $maxResourceNameLength."
    }
    else {
        Add-Pass "The shared private-link max-name-length variable is $maxResourceNameLength."
    }

    $resourcesExpr = $template.variables.searchFoundrySharedPrivateLinkResources
    if ($resourcesExpr -match 'utcNow|newGuid') {
        Add-Failure 'The shared private-link name/group array references a non-deterministic ARM function (utcNow/newGuid).'
    }
    else {
        Add-Pass 'The shared private-link name/group array uses only deterministic ARM functions (no utcNow/newGuid).'
    }

    $directNameLiterals = [System.Collections.Generic.List[string]]::new()
    $boundedNameLiterals = [System.Collections.Generic.List[string]]::new()
    foreach ($group in $groups) {
        $directFormat = "format('spl-{0}-$group-1', variables('resourceNames').searchServiceName)"
        $boundedFormat = "format('spl-{0}-$group-1', variables('searchFoundrySharedPrivateLinkNameToken'))"
        $guard = "lessOrEquals(length($directFormat), variables('searchFoundrySharedPrivateLinkMaxNameLength'))"
        $ternary = "if($guard, $directFormat, $boundedFormat)"

        if (-not $resourcesExpr.Contains($ternary)) {
            Add-Failure "Shared private link '$group' does not preserve its plain name when it fits, with a bounded fallback when it does not."
            continue
        }
        Add-Pass "Shared private link '$group' preserves its plain name when it fits <= $maxResourceNameLength chars, else falls back to the bounded token."
        $directNameLiterals.Add($directFormat) | Out-Null
        $boundedNameLiterals.Add($boundedFormat) | Out-Null
    }

    if (($directNameLiterals | Select-Object -Unique).Count -eq $groups.Count -and
        ($boundedNameLiterals | Select-Object -Unique).Count -eq $groups.Count) {
        Add-Pass 'All three shared private-link names (direct and bounded forms) are pairwise distinct by construction (distinct groupId suffix).'
    }
    else {
        Add-Failure 'Two or more shared private-link names collide on their direct or bounded name expression.'
    }

    $splResource = $template.resources.searchFoundrySharedPrivateLinks
    $expectedType = 'Microsoft.Search/searchServices/sharedPrivateLinkResources'
    $expectedApiVersion = '2025-05-01'
    if ($null -eq $splResource) {
        Add-Failure 'The searchFoundrySharedPrivateLinks resource is missing from the compiled template.'
    }
    else {
        if ($splResource.type -ne $expectedType) {
            Add-Failure "searchFoundrySharedPrivateLinks type changed: expected '$expectedType', got '$($splResource.type)'."
        }
        elseif ($splResource.apiVersion -ne $expectedApiVersion) {
            Add-Failure "searchFoundrySharedPrivateLinks apiVersion changed: expected '$expectedApiVersion', got '$($splResource.apiVersion)'."
        }
        elseif ((@($splResource.dependsOn) -join ',') -ne (@('aiFoundry', 'searchService') -join ',')) {
            Add-Failure "searchFoundrySharedPrivateLinks dependsOn changed: expected [aiFoundry, searchService], got [$($splResource.dependsOn -join ', ')]."
        }
        elseif ($splResource.copy.mode -ne 'serial' -or $splResource.copy.batchSize -ne 1) {
            Add-Failure "searchFoundrySharedPrivateLinks copy loop changed: expected serial mode with batchSize 1, got mode='$($splResource.copy.mode)' batchSize=$($splResource.copy.batchSize)."
        }
        elseif ($splResource.copy.count -ne "[length(variables('searchFoundrySharedPrivateLinkResources'))]") {
            Add-Failure "searchFoundrySharedPrivateLinks copy count no longer targets the gated resources array: got '$($splResource.copy.count)'."
        }
        else {
            Add-Pass 'searchFoundrySharedPrivateLinks keeps its type, apiVersion, dependsOn, and gated serial copy loop unchanged.'
        }
    }

    # --- 2. Maximum-length Search service name simulation --------------------

    $maxLengthSearchName = 'a' * 60
    foreach ($group in $groups) {
        $result = Get-SharedPrivateLinkNameLength -SearchServiceNameLength $maxLengthSearchName.Length -GroupId $group
        if ($result.Length -gt $maxResourceNameLength) {
            Add-Failure "With a maximum-length (60-char) Search service name, '$group' would reach $($result.Length) characters."
        }
        else {
            Add-Pass "With a maximum-length (60-char) Search service name, '$group' is bounded to $($result.Length) characters (direct name used: $($result.UsedDirectName))."
        }
    }

    # Determinism: recomputing with the same input yields the same length and
    # the same direct/bounded decision every time (pure function of inputs).
    $first = Get-SharedPrivateLinkNameLength -SearchServiceNameLength $maxLengthSearchName.Length -GroupId 'cognitiveservices_account'
    $second = Get-SharedPrivateLinkNameLength -SearchServiceNameLength $maxLengthSearchName.Length -GroupId 'cognitiveservices_account'
    if ($first.Length -ne $second.Length -or $first.UsedDirectName -ne $second.UsedDirectName) {
        Add-Failure 'The shared private-link naming scheme is not deterministic for identical inputs.'
    }
    else {
        Add-Pass 'The shared private-link naming scheme is deterministic for identical inputs.'
    }

    # Pairwise distinctness for the maximum-length scenario (all three fall
    # back to the bounded token, differing only by their literal groupId
    # suffix, which keeps them distinct even though the token is shared).
    $maxLengthNames = $groups | ForEach-Object { "spl-$('a' * (Get-BoundedTokenLength -SearchServiceNameLength $maxLengthSearchName.Length))-$_-1" }
    if (($maxLengthNames | Select-Object -Unique).Count -eq $groups.Count) {
        Add-Pass 'The three bounded shared private-link names are pairwise distinct for a maximum-length Search service name.'
    }
    else {
        Add-Failure 'Two or more bounded shared private-link names collide for a maximum-length Search service name.'
    }

    # --- 3. Live-failure evidence replay (Azure/GPT-RAG#592, #597) -----------
    # The reported CAF-generated Search service name was 39 characters, giving
    # a pre-fix foundry_account name of 61 chars and cognitiveservices_account
    # of 71 chars (both over the 60-char limit); openai_account fit exactly at
    # 60 and was unaffected.

    $reportedSearchNameLength = 39
    $expectedPreFixLengths = @{
        'openai_account'            = 60
        'foundry_account'           = 61
        'cognitiveservices_account' = 71
    }
    foreach ($group in $groups) {
        $preFixLength = 'spl-'.Length + $reportedSearchNameLength + 1 + $group.Length + '-1'.Length
        if ($preFixLength -ne $expectedPreFixLengths[$group]) {
            Add-Failure "Live-failure replay: expected the unbounded pre-fix '$group' name to reach $($expectedPreFixLengths[$group]) characters for the reported 39-char Search service name, computed $preFixLength."
            continue
        }
        $result = Get-SharedPrivateLinkNameLength -SearchServiceNameLength $reportedSearchNameLength -GroupId $group
        if ($result.Length -gt $maxResourceNameLength) {
            Add-Failure "Live-failure replay: '$group' still reaches $($result.Length) characters (>$maxResourceNameLength) for the reported 39-char Search service name."
        }
        else {
            Add-Pass "Live-failure replay: '$group' is now bounded to $($result.Length) characters for the reported 39-char Search service name (pre-fix was $preFixLength)."
        }
    }

    # --- 4. Backward compatibility: ordinary/short names keep their plain name

    $ordinaryCafName = 'srch-abc123-dev-eus2-001'
    $allDirect = $true
    foreach ($group in $groups) {
        $result = Get-SharedPrivateLinkNameLength -SearchServiceNameLength $ordinaryCafName.Length -GroupId $group
        if (-not $result.UsedDirectName) { $allDirect = $false }
    }
    if ($allDirect) {
        Add-Pass "An ordinary/short Search service name ('$ordinaryCafName', $($ordinaryCafName.Length) chars) keeps the plain, pre-existing shared private-link name for all three groups."
    }
    else {
        Add-Failure "An ordinary/short Search service name ('$ordinaryCafName') unexpectedly falls back to the bounded token for at least one group, changing existing deployments' resource names unnecessarily."
    }

    # --- 5. Regression guard: every direct-name usage is length-guarded -----
    # The plain, unbounded name literal ('spl-${resourceNames.searchServiceName}-
    # <group>-1') is expected to still appear in source as the "fits" branch of
    # the ternary, guarded by a `length(...) <= searchFoundrySharedPrivateLinkMaxNameLength`
    # check. What must NOT happen is that literal being assigned to `name:`
    # unconditionally (the pre-fix, v2.4.1 defect).

    $source = Get-Content -LiteralPath $MainFile -Raw
    $unconditionalPattern = "name:\s*'spl-\`$\{resourceNames\.searchServiceName\}-(?:openai|foundry|cognitiveservices)_account-1'"
    $guardedPattern = "length\('spl-\`$\{resourceNames\.searchServiceName\}-(?:openai|foundry|cognitiveservices)_account-1'\)\s*<=\s*searchFoundrySharedPrivateLinkMaxNameLength"
    $guardedMatches = [regex]::Matches($source, $guardedPattern).Count
    if ($source -match $unconditionalPattern) {
        Add-Failure 'A Foundry shared private link assigns the unbounded Search service name to `name:` unconditionally (no length guard).'
    }
    elseif ($guardedMatches -ne $groups.Count) {
        Add-Failure "Expected $($groups.Count) length-guarded direct-name branches in source, found $guardedMatches."
    }
    else {
        Add-Pass "All $guardedMatches Foundry shared private link direct names are guarded by a length(...) <= $maxResourceNameLength check (no unconditional unbounded name)."
    }
}
finally {
    Remove-Item -LiteralPath $compiledFile -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) shared private-link naming contract check(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host "`nFoundry IQ shared private-link naming contract checks passed." -ForegroundColor Green
exit 0
