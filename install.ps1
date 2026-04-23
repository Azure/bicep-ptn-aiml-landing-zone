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
  [string] $useUAI 
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
# Install PowerShell Core, Notepad++, WSL, Docker
# ------------------------------
write-host "Installing PowerShell Core"
choco install powershell-core -y --ignoredetectedreboot --force

write-host "Installing Notepad++"
choco install notepadplusplus -y --ignoredetectedreboot --force

# Detect OS family (Server vs Desktop) to choose the right Docker flavor
$os = Get-CimInstance Win32_OperatingSystem
$isServer = ($os.ProductType -ne 1)   # 1=Workstation, 2=Domain Controller, 3=Server
Write-Host ("Detected OS: {0} (ProductType={1}, IsServer={2})" -f $os.Caption, $os.ProductType, $isServer)

if ($isServer) {
    # --------- Windows Server: Docker Engine (Moby) + buildx for Linux images ---------
    $dockerStatus = [ordered]@{
        containersFeature = 'NotAttempted'
        mobyDownload      = 'NotAttempted'
        mobyExtract       = 'NotAttempted'
        serviceRegister   = 'NotAttempted'
        serviceRunning    = 'NotAttempted'
        buildxPlugin      = 'NotAttempted'
        buildxBootstrap   = 'NotAttempted'
    }

    Write-Host "`n==================== DOCKER ENGINE (MOBY) SETUP ====================" -ForegroundColor Cyan

    # Step 1: Enable Containers feature FIRST (required before dockerd can register as a service)
    Write-Host "[docker] Step 1/6: Enabling Windows 'Containers' feature..."
    try {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName Containers -ErrorAction Stop
        if ($feat.State -eq 'Enabled') {
            Write-Host "[docker] Containers feature already enabled" -ForegroundColor Green
            $dockerStatus.containersFeature = 'AlreadyEnabled'
        } else {
            $r = Enable-WindowsOptionalFeature -Online -FeatureName Containers -NoRestart -ErrorAction Stop
            Write-Host "[docker] Containers feature enabled (RestartNeeded=$($r.RestartNeeded))" -ForegroundColor Green
            $dockerStatus.containersFeature = if ($r.RestartNeeded) { 'EnabledRestartPending' } else { 'Enabled' }
        }
    } catch {
        Write-Host "[docker] ERROR enabling Containers feature: $_" -ForegroundColor Red
        $dockerStatus.containersFeature = "Error: $_"
    }

    # Step 2: Download Moby static binaries
    $dockerDir = "$env:ProgramFiles\docker"
    $mobyVersion = '27.3.1'
    $mobyUrl = "https://download.docker.com/win/static/stable/x86_64/docker-$mobyVersion.zip"
    $dockerZip = "$env:TEMP\docker.zip"
    Write-Host "[docker] Step 2/6: Downloading Moby $mobyVersion from $mobyUrl ..."
    try {
        Invoke-WebRequest -Uri $mobyUrl -OutFile $dockerZip -UseBasicParsing -ErrorAction Stop
        $size = (Get-Item $dockerZip).Length
        Write-Host "[docker] Download OK ($([math]::Round($size/1MB,2)) MB)" -ForegroundColor Green
        $dockerStatus.mobyDownload = 'OK'
    } catch {
        Write-Host "[docker] ERROR downloading Moby: $_" -ForegroundColor Red
        $dockerStatus.mobyDownload = "Error: $_"
    }

    # Step 3: Extract Moby to Program Files
    Write-Host "[docker] Step 3/6: Extracting Moby to $env:ProgramFiles ..."
    try {
        Expand-Archive -Path $dockerZip -DestinationPath $env:ProgramFiles -Force -ErrorAction Stop
        Remove-Item $dockerZip -Force -ErrorAction SilentlyContinue
        if (Test-Path "$dockerDir\dockerd.exe") {
            Write-Host "[docker] Moby extracted (dockerd.exe + docker.exe present)" -ForegroundColor Green
            $dockerStatus.mobyExtract = 'OK'
        } else {
            Write-Host "[docker] ERROR: dockerd.exe not found in $dockerDir after extract" -ForegroundColor Red
            $dockerStatus.mobyExtract = 'MissingBinaries'
        }
    } catch {
        Write-Host "[docker] ERROR extracting Moby: $_" -ForegroundColor Red
        $dockerStatus.mobyExtract = "Error: $_"
    }

    # Add docker dir to PATH (session + machine) — prepend so Moby's docker.exe wins over any choco-installed client
    $env:Path = "$dockerDir;$env:Path"
    try {
        $machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
        if ($machinePath -notlike "*$dockerDir*") {
            [Environment]::SetEnvironmentVariable('Path', "$dockerDir;$machinePath", 'Machine')
            Write-Host "[docker] Prepended $dockerDir to MACHINE Path"
        }
    } catch {
        Write-Host "[docker] WARN updating MACHINE Path: $_" -ForegroundColor Yellow
    }

    # Step 4: Register dockerd as a Windows service
    Write-Host "[docker] Step 4/6: Registering dockerd service..."
    if ($dockerStatus.mobyExtract -eq 'OK') {
        try {
            $existing = Get-Service -Name docker -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Host "[docker] docker service already registered, skipping --register-service"
            } else {
                & "$dockerDir\dockerd.exe" --register-service 2>&1 | ForEach-Object { Write-Host "[dockerd] $_" }
            }
            $dockerStatus.serviceRegister = 'OK'
        } catch {
            Write-Host "[docker] ERROR registering dockerd service: $_" -ForegroundColor Red
            $dockerStatus.serviceRegister = "Error: $_"
        }

        # Step 5: Start docker service and wait for Running state
        Write-Host "[docker] Step 5/6: Starting docker service..."
        try {
            Start-Service docker -ErrorAction Stop
            # Wait up to 60s for service to reach Running
            $deadline = (Get-Date).AddSeconds(60)
            do {
                Start-Sleep -Seconds 2
                $svc = Get-Service docker -ErrorAction SilentlyContinue
            } while ($svc -and $svc.Status -ne 'Running' -and (Get-Date) -lt $deadline)

            if ($svc -and $svc.Status -eq 'Running') {
                Write-Host "[docker] docker service is Running" -ForegroundColor Green
                $dockerStatus.serviceRunning = 'Running'
            } else {
                Write-Host "[docker] docker service did not reach Running within 60s (Status=$($svc.Status))" -ForegroundColor Yellow
                $dockerStatus.serviceRunning = "Status=$($svc.Status)"
            }
        } catch {
            Write-Host "[docker] ERROR starting docker service: $_" -ForegroundColor Red
            $dockerStatus.serviceRunning = "Error: $_"
        }
    } else {
        Write-Host "[docker] Skipping service register/start — Moby extract did not succeed" -ForegroundColor Yellow
    }

    # Step 6: Install docker-buildx plugin (for linux/amd64 builds via docker-container driver)
    $buildxDir    = "$env:ProgramData\docker\cli-plugins"
    $buildxVer    = 'v0.17.1'
    $buildxUrl    = "https://github.com/docker/buildx/releases/download/$buildxVer/buildx-$buildxVer.windows-amd64.exe"
    $buildxTarget = "$buildxDir\docker-buildx.exe"
    Write-Host "[docker] Step 6/6: Installing docker-buildx plugin $buildxVer ..."
    try {
        New-Item -ItemType Directory -Force -Path $buildxDir | Out-Null
        Invoke-WebRequest -Uri $buildxUrl -OutFile $buildxTarget -UseBasicParsing -ErrorAction Stop
        if (Test-Path $buildxTarget) {
            Write-Host "[docker] buildx plugin installed at $buildxTarget" -ForegroundColor Green
            $dockerStatus.buildxPlugin = 'OK'
        } else {
            $dockerStatus.buildxPlugin = 'Missing'
        }
    } catch {
        Write-Host "[docker] ERROR installing buildx plugin: $_" -ForegroundColor Red
        $dockerStatus.buildxPlugin = "Error: $_"
    }

    # Bootstrap linux/amd64 builder (only attempt if daemon is running)
    if ($dockerStatus.serviceRunning -eq 'Running' -and $dockerStatus.buildxPlugin -eq 'OK') {
        try {
            $dockerExe = "$dockerDir\docker.exe"
            & $dockerExe buildx version 2>&1 | ForEach-Object { Write-Host "[buildx] $_" }
            & $dockerExe buildx create --name linuxbuilder --driver docker-container --use 2>&1 | ForEach-Object { Write-Host "[buildx] $_" }
            & $dockerExe buildx inspect --bootstrap 2>&1 | ForEach-Object { Write-Host "[buildx] $_" }
            Write-Host "[docker] buildx linuxbuilder ready" -ForegroundColor Green
            $dockerStatus.buildxBootstrap = 'OK'
        } catch {
            Write-Host "[docker] buildx bootstrap will be completed on first use: $_" -ForegroundColor Yellow
            $dockerStatus.buildxBootstrap = "Deferred: $_"
        }
    } else {
        Write-Host "[docker] Skipping buildx bootstrap — service not running or plugin missing" -ForegroundColor Yellow
        $dockerStatus.buildxBootstrap = 'Skipped'
    }

    # Final Docker status summary (written to transcript + separate file for easy inspection)
    Write-Host "`n==================== DOCKER SETUP SUMMARY ====================" -ForegroundColor Cyan
    $dockerStatus.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-18}: {1}" -f $_.Key, $_.Value) }
    Write-Host "==============================================================`n" -ForegroundColor Cyan
    try {
        $dockerStatus | ConvertTo-Json | Out-File -FilePath 'C:\WindowsAzure\Logs\docker-setup-status.json' -Encoding UTF8 -Force
    } catch {}
} else {
    # --------- Windows Desktop (Win10/11): Docker Desktop + WSL2 ---------
    write-host "Enabling WSL features"
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart

    write-host "Updating WSL"
    Invoke-WebRequest -Uri "https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi" -OutFile ".\wsl_update_x64.msi"
    Start-Process "msiexec.exe" -ArgumentList "/i .\wsl_update_x64.msi /quiet" -NoNewWindow -Wait
    wsl.exe --update
    wsl.exe --set-default-version 2

    write-host "Installing Docker Desktop"
    choco install docker-desktop -y --ignoredetectedreboot --force
}


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

# Always reboot to complete Docker Desktop and WSL2 setup.
# Delay the reboot by 120 seconds so the Custom Script Extension (CSE) agent has
# enough time (~30s) to report the final Succeeded status back to ARM before the
# VM goes down. A shorter delay (or an immediate reboot) causes the ARM
# provisioningState to stay permanently at "Updating", which breaks
# `az vm extension wait` and any deployment that depends on CSE completion.
write-host "Installation completed successfully!";
write-host "Rebooting in 120 seconds to complete setup...";
shutdown /r /t 120 /c "Rebooting after CSE setup to activate Windows Containers feature"

Stop-Transcript
