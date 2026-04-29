<#
    Jumpbox Setup Script – Updated for Custom Script Extension (CSE)

    Fixes included:
      • Correct AZD installation path
      • Guaranteed azd execution via absolute path
      • PATH not loading inside CSE session
      • Adds azd folder to PATH for current session and machine level
      • Uses & "C:\Program Files\Azure Dev CLI\azd.exe" for all azd commands
      • Repo clone/checkout stability improvements
#>

Param (
  [Parameter(Mandatory = $true)]
  [string] $release,

  [string] $azureTenantID,
  [string] $azureSubscriptionID,
  [string] $AzureResourceGroupName,
  [string] $azureLocation,
  [string] $AzdEnvName,
  [string] $resourceToken,
  [string] $useUAI,

  # Optional: additional Git repositories to clone into C:\github\ on the
  # jumpbox. Useful for downstream solution accelerators that consume this
  # landing zone as a Bicep module / git submodule and need their own app
  # repository present on the VM for post-provisioning data-plane scripts.
  # Pass as comma-separated strings (CSE command-line friendly):
  #   -ExtraRepoUrls  "https://github.com/org/repo-a.git,https://github.com/org/repo-b.git"
  #   -ExtraRepoTags  "v1.0.0,main"
  #   -ExtraRepoNames "repo-a,repo-b"
  # Tags default to "main"; names default to the repo URL basename.
  [string] $ExtraRepoUrls  = '',
  [string] $ExtraRepoTags  = '',
  [string] $ExtraRepoNames = ''
)

Start-Transcript -Path C:\WindowsAzure\Logs\CMFAI_CustomScriptExtension.txt -Append

[Net.ServicePointManager]::SecurityProtocol = "tls12"

Write-Host "`n==================== PARAMETERS ====================" -ForegroundColor Cyan
$PSBoundParameters.GetEnumerator() | ForEach-Object {
    $name = $_.Key
    $value = if ([string]::IsNullOrWhiteSpace($_.Value)) { "<empty>" } else { $_.Value }
    Write-Host ("{0,-25}: {1}" -f $name, $value)
}
Write-Host "====================================================`n" -ForegroundColor Cyan


# ------------------------------
# Install Chocolatey
# ------------------------------
Set-ExecutionPolicy Bypass -Scope Process -Force
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

$env:Path += ";C:\ProgramData\chocolatey\bin"


# ------------------------------
# Install tooling (sequential — see issues #24, #30, #31)
# ------------------------------
# History:
#   * #24 (v1.1.1) parallelized the six choco installs via Start-Job to cut
#     CSE wall time. Worked but introduced two race classes:
#   * #30 (v1.1.3) — Windows Installer machine-wide mutex (`Global\_MSIExecute`)
#     contention on parallel MSI-backed packages → exit 1618 on losers.
#     Mitigated with Invoke-ChocoWithRetry (kept below).
#   * #31 (v1.1.3 amend) — *internal* Chocolatey file-lock race on
#     `C:\ProgramData\chocolatey\lib\chocolatey-compatibility.extension\.chocolateyPending`
#     (and similarly `chocolatey-core.extension`) when two jobs concurrently
#     auto-pull the same dependency package. This race surfaces as
#     ``Access to the path '...\.chocolateyPending' is denied.`` with choco
#     exiting 1 — NOT 1618 — so the retry helper bypasses it and the affected
#     package (e.g. powershell-core) is silently dropped.
#
# Fix (#31): stop parallelizing choco. Chocolatey is not designed for
# concurrent invocations on the same machine. We run the six installs in a
# sequential foreach loop, still through Invoke-ChocoWithRetry so genuine MSI
# 1618 contention from unrelated installers (e.g. Azure Update Manager)
# remains handled. The wall-time cost vs parallel is ~30–60 s, dominated
# anyway by Defender, antimalware, AZD-MSI download, and the post-CSE reboot.
#
# Implementation notes:
#   * AZD is installed via `choco install azd` instead of `aka.ms/install-azd.ps1`
#     so it goes through the same retry path. The path-discovery block below
#     still searches the legacy MSI locations as a fallback in case the
#     chocolatey package layout changes.
#   * Notepad++ was dropped — not used by any downstream automation.
#   * Quiet flags (`--no-progress --limitoutput --no-color`) cut log/console
#     overhead. `--ignoredetectedreboot --force` preserves existing behavior
#     (the script ends with a delayed reboot, see bottom of file).
$chocoArgs = @('-y','--ignoredetectedreboot','--force','--no-progress','--limitoutput','--no-color')

# Retry helper kept for genuine MSI 1618 contention (e.g. another concurrent
# installer on the host such as Azure Update Manager). It does NOT retry on
# Chocolatey-internal file-lock failures (#31), which were the parallelization
# race; those cannot occur once we serialize.
function Invoke-ChocoWithRetry {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('install','upgrade')][string]$Action,
        [Parameter(Mandatory=$true)][string]$Package,
        [Parameter(Mandatory=$true)][string[]]$ExtraArgs
    )
    $maxAttempts = 8
    $delay = 15
    for ($i = 1; $i -le $maxAttempts; $i++) {
        $output = & choco $Action $Package @ExtraArgs 2>&1 | Out-String
        $exit = $LASTEXITCODE
        Write-Output $output
        if ($exit -eq 0) {
            if ($i -gt 1) {
                Write-Output "[$Package] choco $Action succeeded on attempt $i/$maxAttempts after MSI lock contention."
            }
            return
        }
        $isMsiLockContention = ($output -match '\b1618\b') -or ($output -match 'Another installation currently in progress')
        if ($isMsiLockContention -and $i -lt $maxAttempts) {
            Write-Output "[$Package] MSI lock contention (exit=$exit, code 1618) on attempt $i/$maxAttempts; backing off ${delay}s..."
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 120)
            continue
        }
        if ($isMsiLockContention) {
            Write-Warning "[$Package] choco $Action exhausted $maxAttempts retries due to persistent MSI lock contention (exit=$exit)."
            return
        }
        Write-Warning "[$Package] choco $Action failed with exit=$exit (non-1618); not retrying."
        return
    }
}

$packages = @(
    @{ Name = 'vscode';          Action = 'upgrade' }
    @{ Name = 'azure-cli';       Action = 'install' }
    @{ Name = 'git';             Action = 'upgrade' }
    @{ Name = 'python311';       Action = 'install' }
    @{ Name = 'powershell-core'; Action = 'install' }
    @{ Name = 'azd';             Action = 'install' }
)

Write-Host "Starting sequential choco installs with MSI-retry hardening..."
foreach ($p in $packages) {
    Write-Host "`n--- choco $($p.Action) $($p.Name) ---"
    Invoke-ChocoWithRetry -Action $p.Action -Package $p.Name -ExtraArgs $chocoArgs
}
Write-Host "Sequential choco installs finished."

# Refresh PATH for the rest of this CSE run so the tools above are resolvable
# without waiting for the post-CSE reboot.
$env:PATH = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin;C:\Program Files\Git\cmd;C:\Program Files\Git\bin;C:\ProgramData\chocolatey\bin;$env:PATH"

Write-Host "Searching for installed AZD executable..."

$possibleAzdLocations = @(
    "C:\ProgramData\chocolatey\bin\azd.exe",
    "C:\ProgramData\chocolatey\lib\azd\tools\azd.exe",
    "C:\Program Files\Azure Dev CLI\azd.exe",
    "C:\Program Files (x86)\Azure Dev CLI\azd.exe",
    "C:\ProgramData\azd\bin\azd.exe",
    "C:\Windows\System32\azd.exe",
    "C:\Windows\azd.exe",
    "C:\Users\testvmuser\.azure-dev\bin\azd.exe",
    "$env:LOCALAPPDATA\Programs\Azure Dev CLI\azd.exe",
    "$env:LOCALAPPDATA\Azure Dev CLI\azd.exe"
)

$azdExe = $null

foreach ($path in $possibleAzdLocations) {
    if (Test-Path $path) {
        $azdExe = $path
        break
    }
}

if (-not $azdExe) {
    Write-Host "ERROR: azd.exe not found after installation. Installation path changed or MSI failed." -ForegroundColor Red
    Write-Host "Dumping filesystem search for troubleshooting..."
    Get-ChildItem -Path "C:\" -Recurse -Filter "azd.exe" -ErrorAction SilentlyContinue | Select-Object FullName
    exit 1
} else {
    Write-Host "AZD successfully located at: $azdExe" -ForegroundColor Green
}

# Add to PATH for immediate use
$env:PATH = "$(Split-Path $azdExe);$env:PATH"
Write-Host "Updated PATH for this session: $env:PATH"

$azdDir = Split-Path $azdExe

try {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($machinePath -notlike "*$azdDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$machinePath;$azdDir", "Machine")
        Write-Host "Added $azdDir to MACHINE Path"
    } else {
        Write-Host "AZD directory already present in MACHINE Path"
    }
} catch {
    Write-Host "Failed to update MACHINE Path: $_" -ForegroundColor Yellow
}

try {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -and $userPath -notlike "*$azdDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$azdDir", "User")
        Write-Host "Added $azdDir to USER Path"
    } elseif (-not $userPath) {
        [Environment]::SetEnvironmentVariable("Path", $azdDir, "User")
        Write-Host "Initialized USER Path with AZD directory"
    } else {
        Write-Host "AZD directory already present in USER Path"
    }
} catch {
    Write-Host "Failed to update USER Path: $_" -ForegroundColor Yellow
}


# ------------------------------
# Docker intentionally NOT installed on this jumpbox.
#
# Rationale (see issue #14 — ACR Task agent pool for NI image builds):
#   - Windows Server's Moby engine cannot run privileged Linux containers required
#     by BuildKit, so `docker buildx` against linux/amd64 images never worked here.
#   - Docker Desktop is not supported on Windows Server and requires a paid Docker
#     Subscription above ~250 employees / ~$10M revenue.
#   - Image builds now run in the ACR Tasks agent pool deployed alongside ACR
#     (Bicep param: deployAcrTaskAgentPool). See the ACR_TASK_AGENT_POOL azd output.
#
# To build and push images from this jumpbox (or any client with ARM egress):
#   az acr build -r <acr> --agent-pool <ACR_TASK_AGENT_POOL> -t myapp:latest -f Dockerfile .
#
# To pause billing between builds:
#   az acr agentpool update -r <acr> -n <ACR_TASK_AGENT_POOL> --count 0
# ------------------------------
Write-Host "`n==================== IMAGE BUILD GUIDANCE ====================" -ForegroundColor Cyan
Write-Host "Docker is NOT installed on this jumpbox by design."
Write-Host "Use ACR Tasks agent pool for image builds:"
Write-Host "  az acr build -r <acr> --agent-pool <pool-name> -t myapp:latest -f Dockerfile ."
Write-Host "==============================================================`n" -ForegroundColor Cyan


# ------------------------------
# Clone Bicep PTN AIML Landing Zone repo
# ------------------------------
# All `git clone` invocations in this script run via Invoke-GitCloneWithTimeout
# (defined below) — see issues #32 and #33. A plain `git clone` over HTTPS has
# no upper bound on idle/zombie connections, and the Azure VM Guest Agent
# serializes every Run-Command behind the active CSE. So a single hanging
# clone can keep CSE in `Transitioning` for hours and freeze the entire VM
# operation queue (including operator remediation via `az vm run-command
# invoke`). The helper wraps each clone in a `Start-Job` with a hard wall
# clock cap, after which the job is forcibly stopped.
#
# The `Start-Job` child has no TTY, so Git Credential Manager can stall on
# discovery prompts that never resolve (#33 Bug A). We therefore force
# `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=Never`, and disable
# `credential.helper` for this child invocation. Cold-start TLS on freshly
# booted NI VMs (Defender + post-choco) can take >60 s to complete the first
# byte, so `GIT_HTTP_LOW_SPEED_TIME` is loosened to 180 s and the wall clock
# to 900 s (#33 Bug B). The real `git` exit code is captured via a sentinel
# line in the job's output stream, with a `.git` directory existence
# fallback, so genuine non-zero exits are not silently swallowed (#33 Bug C).
# One automatic retry with a 15 s back-off covers single transient failures
# without becoming an infinite retry loop.
function Invoke-GitCloneWithTimeout {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$Tag,
        [Parameter(Mandatory=$true)][string]$Destination,
        [int]$TimeoutSec       = 900,
        [int]$LowSpeedTimeSec  = 180,
        [int]$LowSpeedLimitBps = 1000,
        [int]$MaxAttempts      = 2
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "[clone] attempt ${attempt}/${MaxAttempts}: $Url (tag=$Tag) -> $Destination (timeout=${TimeoutSec}s)"
        if (Test-Path $Destination) {
            Remove-Item $Destination -Recurse -Force -ErrorAction SilentlyContinue
        }

        $job = Start-Job -ScriptBlock {
            param($u, $t, $d, $lim, $tsec)
            # No TTY in Start-Job: silence any chance of an interactive prompt.
            $env:GIT_TERMINAL_PROMPT = '0'
            $env:GCM_INTERACTIVE     = 'Never'
            # Disable Git Credential Manager for this public-clone path.
            # Avoids GCM discovery RTTs that can stall a cold TLS in NI subnets.
            $env:GIT_CONFIG_COUNT     = '1'
            $env:GIT_CONFIG_KEY_0     = 'credential.helper'
            $env:GIT_CONFIG_VALUE_0   = ''
            # Abort only on truly stuck transfers, not on cold TLS startup.
            $env:GIT_HTTP_LOW_SPEED_LIMIT = "$lim"
            $env:GIT_HTTP_LOW_SPEED_TIME  = "$tsec"
            & git clone -b $t --depth 1 --no-tags $u $d 2>&1
            "__GIT_EXIT__:$LASTEXITCODE"   # surface the real exit code
        } -ArgumentList $Url, $Tag, $Destination, $LowSpeedLimitBps, $LowSpeedTimeSec

        $finished = Wait-Job $job -Timeout $TimeoutSec
        if (-not $finished) {
            Write-Warning "[clone] wall-clock timeout (${TimeoutSec}s) on attempt $attempt"
            Stop-Job  $job -ErrorAction SilentlyContinue
            Receive-Job $job -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            $exit = 124  # convention: 124 == timeout
        }
        else {
            $output = Receive-Job $job
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            $output | ForEach-Object { Write-Output $_ }
            $marker = $output | Where-Object { $_ -match '^__GIT_EXIT__:(\-?\d+)$' } | Select-Object -Last 1
            if ($marker -and $marker -match '^__GIT_EXIT__:(\-?\d+)$') {
                $exit = [int]$Matches[1]
            }
            elseif (Test-Path (Join-Path $Destination '.git')) {
                $exit = 0
            }
            else {
                $exit = 1
            }
        }

        if ($exit -eq 0) {
            $script:LASTEXITCODE = 0
            return
        }
        Write-Warning "[clone] attempt $attempt failed (exit=$exit)"
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds 15 }
        else { $script:LASTEXITCODE = $exit; return }
    }
}

write-host "Cloning Bicep PTN AIML Landing Zone repo"
mkdir C:\github -ea SilentlyContinue
cd C:\github
Invoke-GitCloneWithTimeout -Url 'https://github.com/azure/bicep-ptn-aiml-landing-zone' -Tag $release -Destination 'C:\github\ai-lz'
if ($LASTEXITCODE -ne 0) {
    throw "Failed to clone Bicep PTN AIML Landing Zone repo (release=$release, exit=$LASTEXITCODE). Cannot continue jumpbox bootstrap."
}


# ------------------------------
# Azure Login
# ------------------------------
write-host "Logging into Azure"
az login --identity

write-host "Logging into AZD"
& $azdExe auth login --managed-identity


# ------------------------------
# AZD initialization
# ------------------------------
cd C:\github\ai-lz\
write-host "Initializing AZD environment"

& $azdExe init -e $AzdEnvName --subscription $azureSubscriptionID --location $azureLocation

& $azdExe env set AZURE_TENANT_ID $azureTenantID
& $azdExe env set AZURE_RESOURCE_GROUP $AzureResourceGroupName
& $azdExe env set AZURE_SUBSCRIPTION_ID $azureSubscriptionID
& $azdExe env set AZURE_LOCATION $azureLocation
& $azdExe env set AZURE_AI_FOUNDRY_LOCATION $azureLocation
& $azdExe env set APP_CONFIG_ENDPOINT "https://appcs-$resourceToken.azconfig.io"
& $azdExe env set NETWORK_ISOLATION true
& $azdExe env set USE_UAI $useUAI
& $azdExe env set RESOURCE_TOKEN $resourceToken
& $azdExe env set DEPLOY_SOFTWARE false


# ------------------------------
# Clone dependent repos
# ------------------------------
$manifest = Get-Content "C:\github\ai-lz\manifest.json" | ConvertFrom-Json

foreach ($repo in $manifest.components) {
    $repoName = $repo.name
    $repoUrl  = $repo.repo
    $tag      = $repo.tag

    if (Test-Path "C:\github\$repoName") {
        write-host "Updating existing repository: $repoName"
        cd "C:\github\$repoName"
        git fetch --all
        git checkout $tag
    }
    else {
        write-host "Cloning repository: $repoName ($tag)"
        Invoke-GitCloneWithTimeout -Url $repoUrl -Tag $tag -Destination "C:\github\$repoName"
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path "C:\github\$repoName")) {
            write-warning "git clone failed for component repository '$repoName' ($tag) from '$repoUrl' (exit code $LASTEXITCODE). Skipping .azure context copy and safe-directory config."
            continue
        }
        copy-item C:\github\ai-lz\.azure C:\github\$repoName -recurse -force
    }

    git config --global --add safe.directory "C:/github/$repoName"
}

# ------------------------------
# Clone extra repos derived from manifest.json#components (forwarded by main.bicep)
# ------------------------------
# The Bicep module derives -ExtraRepoUrls/-ExtraRepoTags/-ExtraRepoNames from
# the consumer's overlay `manifest.json#components`, so downstream solution
# accelerators (e.g. GPT-RAG, live-voice-practice) keep a single source of
# truth (their manifest.json) for both release versioning and jumpbox repo
# bootstrapping. See issues #21 and #22.
#
# Note: each split is wrapped in @(...) to force array context. Without it,
# PowerShell 5.1 collapses a single-element pipeline result into a scalar
# string, and `$arr[0]` then returns the FIRST CHARACTER of the URL/tag/name
# instead of the value itself (issues #22, #23 repro).
#
# Important: the @(...) MUST be on the right-hand side of a plain assignment.
# In the form `$x = if (...) { @(...) } else { @(...) }`, the `if` is an
# expression and PowerShell 5.1's pipeline output processor unwraps the
# single-element result back to a scalar — that was the residual bug from
# v1.1.1 caught in #23. So we use plain `if` statements with `@(...)` on
# the assignment RHS instead of `if`-as-expression.
if (-not [string]::IsNullOrWhiteSpace($ExtraRepoUrls)) {
    $extraUrls = @($ExtraRepoUrls -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $extraTags = @()
    if (-not [string]::IsNullOrWhiteSpace($ExtraRepoTags)) {
        $extraTags = @($ExtraRepoTags -split ',' | ForEach-Object { $_.Trim() })
    }

    $extraNames = @()
    if (-not [string]::IsNullOrWhiteSpace($ExtraRepoNames)) {
        $extraNames = @($ExtraRepoNames -split ',' | ForEach-Object { $_.Trim() })
    }

    for ($i = 0; $i -lt $extraUrls.Count; $i++) {
        $url  = $extraUrls[$i]
        $tag  = if ($i -lt $extraTags.Count  -and $extraTags[$i])  { $extraTags[$i]  } else { 'main' }
        $name = if ($i -lt $extraNames.Count -and $extraNames[$i]) { $extraNames[$i] } else { (($url -split '/')[-1]) -replace '\.git$','' }

        if (Test-Path "C:\github\$name") {
            write-host "Updating existing extra repository: $name"
            cd "C:\github\$name"
            git fetch --all
            git checkout $tag
        }
        else {
            write-host "Cloning extra repository: $name ($tag) from $url"
            Invoke-GitCloneWithTimeout -Url $url -Tag $tag -Destination "C:\github\$name"
            # Surface git clone failures in the CSE transcript. The CSE itself
            # will not fail because of this (we don't want a single failed
            # extra clone to roll back the entire jumpbox bootstrap), but the
            # operator gets a clear signal in C:\WindowsAzure\Logs\.
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path "C:\github\$name")) {
                write-warning "git clone failed for extra repository '$name' ($tag) from '$url' (exit code $LASTEXITCODE). Skipping .azure context copy and safe-directory config."
                continue
            }
            copy-item C:\github\ai-lz\.azure "C:\github\$name" -recurse -force
        }

        git config --global --add safe.directory "C:/github/$name"
    }
}

# Reboot to finalize Chocolatey-installed tools (Git, Python, VS Code, PowerShell Core)
# that flagged a pending reboot. Delay by 120s so the Custom Script Extension (CSE)
# agent has enough time (~30s) to report the final Succeeded status back to ARM
# before the VM goes down. A shorter delay (or an immediate reboot) causes the ARM
# provisioningState to stay permanently at "Updating", which breaks
# `az vm extension wait` and any deployment that depends on CSE completion.
write-host "Installation completed successfully!";
write-host "Rebooting in 120 seconds to complete setup...";
shutdown /r /t 120 /c "Rebooting after CSE setup to finalize installed tooling"

Stop-Transcript
