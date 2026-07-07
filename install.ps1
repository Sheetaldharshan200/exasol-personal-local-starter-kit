# install.ps1 - Exasol Personal Local Starter Kit, one-command installer (Windows).
#
#   irm https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.ps1 | iex
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
$Repo       = if ($env:EXAKIT_REPO) { $env:EXAKIT_REPO } else { "ranjanm-chn/exasol-personal-local-starter-kit" }
$Ref        = if ($env:EXAKIT_REF)  { $env:EXAKIT_REF }  else { "main" }
$KitDir     = Join-Path $ExakitHome "kit"

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
# Banner + plan via the kit's shared visual layer (setup\lib\ui.ps1) so the
# EXASOL wordmark and palette match the rest of the install exactly. Available
# now that the kit is downloaded; plain fallback if the lib is missing.
$uiLib = Join-Path $KitDir "setup\lib\ui.ps1"
$uiLoaded = $false
if (Test-Path $uiLib) {
    # Load the visual layer WITHOUT dot-sourcing the file. A .ps1 file is
    # subject to the execution policy (Restricted - the Windows default -
    # blocks it), but a scriptblock built from the file's text is not: the
    # same exemption install.ps1 itself runs under via `irm | iex`. Guarded so
    # any failure just falls back to the plain plan below.
    try {
        . ([scriptblock]::Create((Get-Content -Raw -Path $uiLib)))
        $uiLoaded = $true
    } catch { $uiLoaded = $false }
}
if ($uiLoaded) {
    Write-ExakitInstallPlan `
        -Platform "windows ($env:PROCESSOR_ARCHITECTURE, $ramGb GB RAM)" `
        -Database "Exasol Nano (container via Docker Desktop)" `
        -KitDir $KitDir -StateDir $ExakitHome
} else {
    Write-Host ""
    Write-Host "  Personal Local Starter Kit"
    Write-Host "  Local database + exapump + MCP server + pyexasol"
    Write-Host ""
    Write-Host "  Installation plan"
    Write-Host "  -----------------"
    Write-Host "   Platform:   windows ($env:PROCESSOR_ARCHITECTURE, $ramGb GB RAM)"
    Write-Host "   Database:   Exasol Nano (container via Docker Desktop)"
    Write-Host "   Components: local database, exapump, MCP server, pyexasol"
    Write-Host "   Kit copy:   $KitDir (read the scripts any time)"
    Write-Host "   State/logs: $ExakitHome"
    Write-Host ""
}

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
# We already showed the banner above; tell the setup script to skip its own so
# the wordmark appears exactly once through the installer. A direct
# `-File setup\setup-windows-docker.ps1` run (no installer) still shows it.
$env:EXAKIT_BANNER_SHOWN = "1"
& powershell -ExecutionPolicy Bypass -File (Join-Path $KitDir "setup\setup-windows-docker.ps1")
$setupExitCode = $LASTEXITCODE
if ($setupExitCode -ne 0) {
    throw "Setup failed with exit code $setupExitCode."
}
