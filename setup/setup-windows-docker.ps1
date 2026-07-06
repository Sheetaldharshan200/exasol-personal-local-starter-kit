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

    # exapump publishes Windows binaries for x86_64 only. On other
    # architectures (e.g. Windows-on-ARM) the exapump/data/MCP steps are
    # skipped gracefully instead of aborting an install whose database
    # container is already up and fully usable.
    $exapumpSupported = ($env:PROCESSOR_ARCHITECTURE -eq "AMD64")
    if (-not $exapumpSupported) {
        Warn2 "exapump publishes Windows builds for x86_64 only (detected: $($env:PROCESSOR_ARCHITECTURE))."
        Info "Skipping exapump, sample-data loading and MCP client setup - the database container itself is fully supported. Details: quickstarts/windows-docker.md"
    }

    # --- step 3: exapump (data loading CLI) ------------------------------------
    if ($exapumpSupported -and (Begin-ExakitStep "exapump" "Step 2/5  exapump (data loading CLI)")) {
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
    if ($exapumpSupported) {
        try {
            Request-ExakitDataLoadOffer -KitRoot $KitRoot
        } catch [ExakitFailException] {
            Warn2 "Sample data load did not finish cleanly. Retry any time with: exakit data-load"
        }
    }

    # --- step 4: MCP server (AI agent bridge) ----------------------------------
    if ($exapumpSupported -and (Begin-ExakitStep "mcp" "Step 3/5  MCP server (AI agent bridge)")) {
        Install-Mcp
        if (Update-ExakitMcpConfigs) {
            Test-McpServer
            Set-ExakitStepDone "mcp"
        } else {
            Warn2 "MCP client config generation failed - re-run 'exakit mcp-configs' once the issue above is fixed."
        }
    }

    # --- step 5: exakit helper command ------------------------------------------
    # The step flag alone is not trusted: if the shim was removed (cleanup,
    # testing, older builds), a re-run must reinstall it rather than skip —
    # and the PATH check must run either way, since the PATH entry can be
    # missing even when the step is marked done.
    $helperNeeded = Begin-ExakitStep "exakit_helper" "Step 4/5  exakit helper command"
    if (-not $helperNeeded -and -not (Test-Path (Join-Path $script:BinDir "exakit.cmd"))) {
        Info "exakit command is missing - reinstalling it"
        $helperNeeded = $true
    }
    if (-not $helperNeeded) {
        Confirm-ExakitOnPath $script:BinDir
    }
    if ($helperNeeded) {
        New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null

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

        # The bare `exakit` command must be ONLY the .cmd shim. The .ps1 is
        # deliberately NOT placed in the bin dir: when both sit on PATH,
        # PowerShell resolves the .ps1 ahead of the .cmd, which routes
        # `exakit` around the shim's -ExecutionPolicy Bypass and fails on
        # default-policy systems with "running scripts is disabled". The
        # shim targets the kit's copy by absolute path instead.
        # (Remove-Item also self-heals installs made before this fix.)
        Remove-Item -Force (Join-Path $script:BinDir "exakit.ps1") -ErrorAction SilentlyContinue
        $psTarget = Join-Path $kitSetupDir "exakit.ps1"
        $shimPath = Join-Path $script:BinDir "exakit.cmd"
        $shimContent = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$psTarget`" %*`r`n"
        Set-Content -Path $shimPath -Value $shimContent -NoNewline

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
