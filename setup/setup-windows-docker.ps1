# setup-windows-docker.ps1 - Exasol Personal Local Starter Kit, Windows path.
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

$ScriptDir = Split-Path -Parent $PSCommandPath
$LibDir = Join-Path $ScriptDir "lib"
$KitRoot = Split-Path -Parent $ScriptDir

. (Join-Path $LibDir "exakit-common.ps1")
. (Join-Path $LibDir "nano.ps1")
. (Join-Path $LibDir "exapump.ps1")
. (Join-Path $LibDir "mcp.ps1")

Initialize-ExakitLogging
Initialize-ExakitManifest

Write-Host ""
Write-Host "  Exasol Personal Local Starter Kit - Windows setup" -ForegroundColor Cyan
Write-Host ""

Set-ExakitManifestValue "os" "windows"
Set-ExakitManifestValue "arch" $env:PROCESSOR_ARCHITECTURE
$kitSource = if ($env:EXAKIT_KIT_SOURCE) { $env:EXAKIT_KIT_SOURCE } else { "checkout:$KitRoot" }
Set-ExakitManifestValue "kit.source" $kitSource

try {
    # --- step 1: requirements ------------------------------------------------
    Test-NanoRequirements

    # --- step 2: Nano container -----------------------------------------------
    if (Begin-ExakitStep "runtime" "Step 1/5  Exasol Nano container") {
        Install-Nano
        Set-ExakitStepDone "runtime"
    } elseif ((Get-NanoStatus) -ne "running") {
        Info "Runtime marked done but not running - starting it"
        Install-Nano
    }

    # --- step 3: exapump (data loading CLI) ------------------------------------
    if (Begin-ExakitStep "exapump" "Step 2/5  exapump (data loading CLI)") {
        Install-Exapump
        New-ExapumpProfile
        Test-ExapumpConnection
        Set-ExakitStepDone "exapump"
    }

    # Load the sample data before any MCP configuration. exapump is now up
    # (its only dependency), and doing this first means the read-only MCP
    # user is provisioned, granted, and posture-checked against a schema
    # that already holds the sample tables - and the AI client has data to
    # query the moment it connects. Wrapped so a failed/declined load never
    # aborts the rest of setup (mirrors kit_shared_steps' `|| true` in bash).
    try {
        Request-ExakitDataLoadOffer -KitRoot $KitRoot
    } catch [ExakitFailException] {
        Warn2 "Sample data load did not finish cleanly. Retry any time with: exakit data-load"
    }

    # --- step 4: MCP server (AI agent bridge) ----------------------------------
    if (Begin-ExakitStep "mcp" "Step 3/5  MCP server (AI agent bridge)") {
        Install-Mcp
        if (Update-ExakitMcpConfigs) {
            Test-McpServer
            Set-ExakitStepDone "mcp"
        } else {
            Warn2 "MCP client config generation failed - re-run 'exakit mcp-configs' once the issue above is fixed."
        }
    }

    # --- step 5: exakit helper command ------------------------------------------
    if (Begin-ExakitStep "exakit_helper" "Step 4/5  exakit helper command") {
        New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
        Copy-Item -Force (Join-Path $ScriptDir "exakit.ps1") (Join-Path $script:BinDir "exakit.ps1")
        # A .cmd shim so a bare `exakit` works from both cmd.exe and
        # PowerShell (PATHEXT resolves .cmd by default; .ps1 is not in it).
        $shimPath = Join-Path $script:BinDir "exakit.cmd"
        $shimContent = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0exakit.ps1`" %*`r`n"
        Set-Content -Path $shimPath -Value $shimContent -NoNewline

        # Keep a copy of the kit library (and the mcp/, sql/, data/ packages
        # Get-ExakitRepoRoot depends on) next to the state so exakit finds
        # them even when this checkout disappears. Copy-ExakitAsset skips any
        # copy whose source already IS the destination - which is the case
        # when install.ps1 downloaded the kit straight into
        # ~\.exasol-starter-kit\kit and ran setup from there.
        $kitSetupDir = Join-Path $script:ExakitHome "kit\setup"
        New-Item -ItemType Directory -Force -Path $kitSetupDir | Out-Null
        Copy-ExakitAsset -Source $LibDir -Destination (Join-Path $kitSetupDir "lib")
        Copy-ExakitAsset -Source (Join-Path $ScriptDir "exakit.ps1") -Destination (Join-Path $kitSetupDir "exakit.ps1")
        foreach ($dir in @("mcp", "sql", "data")) {
            Copy-ExakitAsset -Source (Join-Path $KitRoot $dir) -Destination (Join-Path $script:ExakitHome "kit\$dir")
        }
        Confirm-ExakitOnPath $script:BinDir
        Set-ExakitStepDone "exakit_helper"
        Ok "exakit installed ($(Join-Path $script:BinDir 'exakit.cmd'))"
    }

    try {
        Request-ExakitMcpSetupOffer
    } catch [ExakitFailException] {
        Warn2 "Your local runtime is installed, but MCP client setup did not finish cleanly."
        Warn2 "Retry any time with: exakit mcp-setup"
    }

    Ok "Setup complete"
    Show-ExakitConnectionPanel
    Info "Next: exakit status | exakit info | exakit help"
} catch [ExakitFailException] {
    exit 1
} catch {
    Write-Host "  x Unexpected error: $_" -ForegroundColor Red
    exit 1
}
