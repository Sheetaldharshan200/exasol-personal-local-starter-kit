# install.ps1 - Exasol Personal Local Starter Kit, one-command installer (Windows).
#
#   irm https://raw.githubusercontent.com/Sheetaldharshan200/exasol-personal-local-starter-kit/main/install.ps1 | iex
#
# IMPORTANT: this file must NOT have a UTF-8 BOM. It is only ever executed
# via `irm | iex` (as a fetched string, never read from disk with -File), and
# a BOM that survives into that string as a literal U+FEFF character breaks
# PowerShell's '#' comment-line detection - the parser then tries to execute
# the comment text itself as commands. (setup\setup-windows-docker.ps1 and
# setup\exakit.ps1 are the opposite case: always read from disk via -File,
# where a BOM is the correct fix for a different, real encoding bug - do not
# "fix" those to match this file.)
#
# What it does, in order:
#   1. detects your hardware and container runtime
#   2. downloads the starter kit to ~\.exasol-starter-kit\kit (so you can
#      read every script before or after it runs)
#   3. shows the installation plan
#   4. hands off to setup\setup-windows-docker.ps1, which installs the
#      Exasol Nano database container, exapump (data loading CLI), and the
#      MCP server - the same components the macOS/Linux/WSL path installs
#
# Options (environment variables):
#   $env:EXAKIT_DRY_RUN = "1"   show the plan, install nothing
#   $env:EXAKIT_REPO    = "..." override the source repo (owner/name)
#   $env:EXAKIT_REF     = "..." override the git ref to install from

$ErrorActionPreference = "Stop"
# Silence the progress stream: it hides the noisy download/extract progress
# banners, and on Windows PowerShell 5.1 it makes Invoke-WebRequest below far
# faster (a visible progress bar throttles it by an order of magnitude).
$ProgressPreference = "SilentlyContinue"

$ExakitHome = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME ".exasol-starter-kit" }
$Repo       = if ($env:EXAKIT_REPO) { $env:EXAKIT_REPO } else { "Sheetaldharshan200/exasol-personal-local-starter-kit" }
$Ref        = if ($env:EXAKIT_REF)  { $env:EXAKIT_REF }  else { "main" }
$KitDir     = Join-Path $ExakitHome "kit"

Write-Host ""
Write-Host "  Exasol Personal Local Starter Kit" -ForegroundColor Cyan
Write-Host "  Local database + AI agent bridge, one command."
Write-Host ""

# --- 1. preflight ------------------------------------------------------------
if ($env:OS -notlike "*Windows*") {
    throw "This installer is for Windows. On macOS/Linux/WSL use install.sh."
}

# --- 2. fetch the kit ----------------------------------------------------------
Write-Host "==> Downloading the starter kit ($Repo@$Ref)" -ForegroundColor Blue
$tmpZip = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-src-$([System.Guid]::NewGuid().ToString('N')).zip"
$urls = @(
    "https://github.com/$Repo/archive/refs/heads/$Ref.zip",
    "https://github.com/$Repo/archive/refs/tags/$Ref.zip"
)
$fetched = $false
foreach ($url in $urls) {
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing
        $fetched = $true
        break
    } catch { }
}
if (-not $fetched) { throw "Could not download the kit from github.com/$Repo ($Ref)." }

if (Test-Path $KitDir) { Remove-Item -Recurse -Force $KitDir }
New-Item -ItemType Directory -Force -Path $KitDir | Out-Null
$tmpExtract = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-src-$([System.Guid]::NewGuid().ToString('N'))"
Expand-Archive -Path $tmpZip -DestinationPath $tmpExtract
$inner = Get-ChildItem $tmpExtract | Select-Object -First 1
Get-ChildItem $inner.FullName | Move-Item -Destination $KitDir
Remove-Item -Recurse -Force $tmpZip, $tmpExtract

# --- 3. show the plan -----------------------------------------------------------
$ramGb = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
Write-Host ""
Write-Host "  Installation plan"
Write-Host "  -----------------"
Write-Host "   Platform:   windows ($env:PROCESSOR_ARCHITECTURE, $ramGb GB RAM)"
Write-Host "   Database:   Exasol Nano (container via Docker Desktop)"
Write-Host "   Components: local database, exapump (data loading CLI), MCP server (AI agent bridge)"
Write-Host "   Kit copy:   $KitDir (read the scripts any time)"
Write-Host "   State/logs: $ExakitHome"
Write-Host ""

if ($env:EXAKIT_DRY_RUN -eq "1") {
    Write-Host "==> Dry run requested (EXAKIT_DRY_RUN=1) - nothing was installed." -ForegroundColor Blue
    Write-Host "    Inspect the scripts under $KitDir, then run:"
    Write-Host "      powershell -File `"$KitDir\setup\setup-windows-docker.ps1`""
    Write-Host ""
    return
}

# --- 4. hand off -----------------------------------------------------------------
Write-Host "==> Starting setup: setup\setup-windows-docker.ps1" -ForegroundColor Blue
Write-Host ""
& powershell -ExecutionPolicy Bypass -File (Join-Path $KitDir "setup\setup-windows-docker.ps1")
$setupExitCode = $LASTEXITCODE
if ($setupExitCode -ne 0) {
    throw "Setup failed with exit code $setupExitCode."
}
