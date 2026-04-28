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
# Install tooling
# ------------------------------
write-host "Installing Visual Studio Code"
choco upgrade vscode -y --ignoredetectedreboot --force

write-host "Installing Azure CLI"
choco install azure-cli -y --ignoredetectedreboot --force

# Add Azure CLI to PATH immediately
$env:PATH = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin;$env:PATH"


write-host "Installing Git"
choco upgrade git -y --ignoredetectedreboot --force
$env:PATH = "C:\Program Files\Git\cmd;$env:PATH"


write-host "Installing Python 3.11"
choco install python311 -y --ignoredetectedreboot --force

Write-Host "Installing AZD..."
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-RestMethod 'https://aka.ms/install-azd.ps1' | Invoke-Expression"

Write-Host "Searching for installed AZD executable..."

$possibleAzdLocations = @(
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
# Install PowerShell Core, Notepad++
# ------------------------------
write-host "Installing PowerShell Core"
choco install powershell-core -y --ignoredetectedreboot --force

write-host "Installing Notepad++"
choco install notepadplusplus -y --ignoredetectedreboot --force

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
write-host "Cloning Bicep PTN AIML Landing Zone repo"
mkdir C:\github -ea SilentlyContinue
cd C:\github
git clone https://github.com/azure/bicep-ptn-aiml-landing-zone -b $release --depth 1 ai-lz


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
        git clone -b $tag --depth 1 $repoUrl "C:\github\$repoName"
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
# instead of the value itself (issue #22 repro).
if (-not [string]::IsNullOrWhiteSpace($ExtraRepoUrls)) {
    $extraUrls  = @($ExtraRepoUrls  -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $extraTags  = if ([string]::IsNullOrWhiteSpace($ExtraRepoTags))  { @() } else { @($ExtraRepoTags  -split ',' | ForEach-Object { $_.Trim() }) }
    $extraNames = if ([string]::IsNullOrWhiteSpace($ExtraRepoNames)) { @() } else { @($ExtraRepoNames -split ',' | ForEach-Object { $_.Trim() }) }

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
            git clone -b $tag --depth 1 $url "C:\github\$name"
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
