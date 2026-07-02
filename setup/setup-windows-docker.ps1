# setup-windows-docker.ps1 — Exasol Personal Local Starter Kit, Windows path.
#
# Installs and connects: Exasol Nano (container via Docker Desktop, Podman
# fallback), exapump, and the Exasol MCP server. Prints connection details
# when done.
#
# Usually launched by install.ps1, but runs standalone from a checkout too:
#   powershell -ExecutionPolicy Bypass -File setup\setup-windows-docker.ps1
#
# Safe to re-run: completed steps are skipped, failed steps are retried.

$ErrorActionPreference = "Stop"

# --- state and pinned versions -------------------------------------------------
$ExakitHome   = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME ".exasol-starter-kit" }
$LogDir       = Join-Path $ExakitHome "logs"
$CredsDir     = Join-Path $ExakitHome "credentials"
$ManifestPath = Join-Path $ExakitHome "manifest.json"
$BinDir       = if ($env:EXAKIT_BIN_DIR) { $env:EXAKIT_BIN_DIR } else { Join-Path $HOME ".local\bin" }

$NanoTag       = if ($env:EXAKIT_NANO_TAG) { $env:EXAKIT_NANO_TAG } else { "2026.2.0-nano.2" }
$NanoImage     = "docker.io/exasol/nano:$NanoTag"
$NanoContainer = if ($env:EXAKIT_NANO_CONTAINER) { $env:EXAKIT_NANO_CONTAINER } else { "exasol-nano" }
$NanoVolume    = if ($env:EXAKIT_NANO_VOLUME) { $env:EXAKIT_NANO_VOLUME } else { "exasol-nano-data" }
$DbPort        = if ($env:EXAKIT_DB_PORT) { $env:EXAKIT_DB_PORT } else { "8563" }
$ReadyTimeout  = 600

New-Item -ItemType Directory -Force -Path $ExakitHome, $LogDir, $CredsDir, $BinDir | Out-Null
$LogFile = Join-Path $LogDir ("install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

function Write-Log([string]$Level, [string]$Msg) {
    "{0} {1,-5} {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Msg | Add-Content $LogFile
}
function Info([string]$Msg)  { Write-Host "==> $Msg" -ForegroundColor Blue;   Write-Log "INFO" $Msg }
function Ok([string]$Msg)    { Write-Host "  + $Msg" -ForegroundColor Green;  Write-Log "OK" $Msg }
function Warn2([string]$Msg) { Write-Host "  ! $Msg" -ForegroundColor Yellow; Write-Log "WARN" $Msg }
function Fail([string]$Msg)  { Write-Host "  x $Msg" -ForegroundColor Red;    Write-Log "ERROR" $Msg
    Write-Host "Full log: $LogFile"; exit 1 }

# --- manifest helpers ------------------------------------------------------------
function Get-Manifest {
    if (Test-Path $ManifestPath) {
        try {
            return (Get-Content $ManifestPath -Raw | ConvertFrom-Json)
        } catch {
            Warn2 "The install manifest is corrupted (interrupted run?) — rebuilding it; existing components will be re-detected"
            Move-Item -Force $ManifestPath "$ManifestPath.corrupt-$(Get-Date -Format 'yyyyMMddHHmmss')"
        }
    }
    [pscustomobject]@{
            manifest_version = 1
            kit_level        = 1
            installed_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            os               = "windows"
            arch             = $env:PROCESSOR_ARCHITECTURE
            runtime          = [pscustomobject]@{}
            components       = [pscustomobject]@{}
            data             = [pscustomobject]@{ loaded = $false }
            steps_completed  = @()
            log_dir          = $LogDir
    }
}
# Atomic write: an interrupted run must never leave a truncated manifest.
function Save-Manifest($m) {
    $tmp = "$ManifestPath.tmp"
    $m | ConvertTo-Json -Depth 8 | Set-Content $tmp
    Move-Item -Force $tmp $ManifestPath
}
function Test-StepDone($m, [string]$Step) { $m.steps_completed -contains $Step }
function Set-StepDone($m, [string]$Step) {
    if (-not (Test-StepDone $m $Step)) { $m.steps_completed = @($m.steps_completed) + $Step }
    Save-Manifest $m
}

$manifest = Get-Manifest
Save-Manifest $manifest

Write-Host ""
Write-Host "  Exasol Personal Local Starter Kit — Windows setup" -ForegroundColor Cyan
Write-Host ""

# --- step 1: container runtime ------------------------------------------------------
$engine = $null
foreach ($candidate in @("docker", "podman")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) {
        & $candidate info *> $null
        if ($LASTEXITCODE -eq 0) { $engine = $candidate; break }
    }
}
if (-not $engine) {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Fail "Docker is installed but not running. Start Docker Desktop and re-run."
    }
    Fail "No container runtime found. Install Docker Desktop (https://docs.docker.com/desktop/) or Podman, then re-run."
}
Ok "Container runtime: $engine"

$ramGb = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($ramGb -lt 4 -and $env:EXAKIT_FORCE -ne "1") {
    Fail "Exasol Nano needs at least 4 GB RAM (detected: $ramGb GB). Set EXAKIT_FORCE=1 to try anyway."
}

# --- step 2: Nano container -----------------------------------------------------------
function Test-NanoReady {
    (& $engine logs $NanoContainer 2>&1 | Select-String -SimpleMatch "Database is now up and running!") -ne $null
}

if ((Test-StepDone $manifest "runtime") -and ((& $engine container inspect -f "{{.State.Running}}" $NanoContainer 2>$null) -eq "true")) {
    Ok "Step 1/4  Exasol Nano container — already running, skipping"
} else {
    Info "Step 1/4  Exasol Nano container"
    $exists = $false
    & $engine container inspect $NanoContainer *> $null
    if ($LASTEXITCODE -eq 0) { $exists = $true }

    if ($exists) {
        Info "Found existing Nano container — starting it"
        & $engine start $NanoContainer *>> $LogFile
        if ($LASTEXITCODE -ne 0) { Fail "Could not start existing container $NanoContainer (see log)" }
    } else {
        $portBusy = Test-NetConnection -ComputerName 127.0.0.1 -Port $DbPort -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($portBusy) {
            Fail "Port $DbPort is already in use by another application. Stop it or set EXAKIT_DB_PORT, then re-run."
        }
        Info "Pulling image $NanoImage"
        & $engine pull $NanoImage *>> $LogFile
        if ($LASTEXITCODE -ne 0) { Fail "Image pull failed: $NanoImage" }
        Ok "Image pulled"

        $pwFile = Join-Path $CredsDir "nano_sys_password"
        if (-not (Test-Path $pwFile)) {
            $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".ToCharArray()
            $password = -join (1..24 | ForEach-Object { $chars | Get-Random })
            Set-Content -Path $pwFile -Value $password -NoNewline
        }

        Info "Starting Nano container ($NanoContainer)"
        & $engine run -d --name $NanoContainer `
            --shm-size=512mb `
            --pids-limit=-1 `
            -p "127.0.0.1:${DbPort}:8563" `
            -v "${NanoVolume}:/exa" `
            -v "${pwFile}:/run/secrets/sys_password:ro" `
            $NanoImage init sys_password_file=/run/secrets/sys_password *>> $LogFile
        if ($LASTEXITCODE -ne 0) { Fail "Container failed to start (see log)" }
    }

    Info "Waiting for the database to come up (timeout: ${ReadyTimeout}s)"
    $waited = 0
    while ($waited -lt $ReadyTimeout) {
        if ((& $engine container inspect -f "{{.State.Running}}" $NanoContainer 2>$null) -ne "true") {
            Fail "Nano container stopped unexpectedly. Check: $engine logs $NanoContainer"
        }
        if (Test-NanoReady) { break }
        Start-Sleep -Seconds 5
        $waited += 5
        if ($waited % 30 -eq 0) { Info "Still starting... (${waited}s)" }
    }
    if (-not (Test-NanoReady)) { Fail "Database did not become ready within ${ReadyTimeout}s. Check: $engine logs $NanoContainer" }
    Ok "Database is up (took ~${waited}s)"

    $manifest.runtime = [pscustomobject]@{
        type          = "nano"
        engine        = $engine
        image         = $NanoImage
        container     = $NanoContainer
        volume        = $NanoVolume
        dsn           = "127.0.0.1:$DbPort"
        user          = "sys"
        password_file = (Join-Path $CredsDir "nano_sys_password")
        tls           = "self-signed"
        status        = "healthy"
    }
    Set-StepDone $manifest "runtime"
}

# --- step 3: exapump (module lands with the data-loading work) --------------------------
Info "Step 2/4  exapump — module not included in this kit build yet, skipping"

# --- step 4: MCP server (module lands with the agent-bridge work) ------------------------
Info "Step 3/4  MCP server — module not included in this kit build yet, skipping"

# --- step 5: pending team assets ----------------------------------------------------------
$KitRoot = Split-Path $PSScriptRoot -Parent
foreach ($pending in @("sql\01_create_schema.sql", "data\data-dictionary.md")) {
    $p = Join-Path $KitRoot $pending
    if (-not (Test-Path $p) -or (Get-Item $p).Length -eq 0) {
        Info "Pending: $pending is not in this kit build yet"
    }
}

# --- done -------------------------------------------------------------------------------
Ok "Setup complete"
Write-Host ""
Write-Host "  --------------------------------------------------------"
Write-Host "   Exasol Starter Kit — connection details"
Write-Host "  --------------------------------------------------------"
Write-Host "   Runtime:      nano ($engine)"
Write-Host "   DSN:          127.0.0.1:$DbPort"
Write-Host "   User:         sys"
Write-Host "   Password:     stored in $(Join-Path $CredsDir 'nano_sys_password')"
Write-Host "   TLS:          enabled (self-signed certificate)"
Write-Host "   Manifest:     $ManifestPath"
Write-Host "   Logs:         $LogDir"
Write-Host "  --------------------------------------------------------"
Write-Host ""
