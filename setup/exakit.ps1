# exakit.ps1 - lifecycle helper for the Exasol Personal Local Starter Kit
# (Windows / PowerShell path). Mirrors setup/exakit function-for-function.
#
# usage: exakit <command> [args]
#
#   preflight            check this machine's requirements, install nothing
#   status                show what is installed and whether it is healthy
#   version               kit source, install date, component versions
#   info                  print the connection details panel
#   start                 start the local database
#   stop                  stop the local database
#   load-data [-Force]    load the sample dataset (schema + CSVs + verify)
#   data-load             open guided data loading options
#   mcp-configs           regenerate the ready-made temporary MCP config bundle
#   mcp-setup             choose temporary or permanent MCP client setup
#   mcp-status [clients]  show managed MCP state
#   mcp-validate [clients] validate managed MCP configs and connectivity
#   mcp-repair [clients]  repair managed MCP config drift
#   mcp-doctor [clients]  run MCP diagnostics
#   mcp-remove [clients]  remove managed MCP config from the supported clients
#   mcp-restore [snapshot] restore the latest (or a chosen) MCP snapshot
#   teardown [-Data]      remove the runtime; -Data also deletes database
#                         content (Nano volume)
#   logs                  print the path of the latest setup log
#   catalog [search]      browse/search every exakit, exapump & exasol command
#   help                  this text
#
# Installed to %USERPROFILE%\.local\bin by setup-windows-docker.ps1; also
# runs straight from a repo checkout (setup\exakit.ps1).

param(
    [Parameter(Position = 0)][string]$Command = "help",
    [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$RestArgs = @()
)

$ErrorActionPreference = "Stop"

# --- locate the kit's lib directory -----------------------------------------
$scriptDir = Split-Path -Parent $PSCommandPath
if (Test-Path (Join-Path $scriptDir "lib\exakit-common.ps1")) {
    $libDir = Join-Path $scriptDir "lib"
} else {
    $fallbackHome = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME ".exasol-starter-kit" }
    $fallbackLib = Join-Path $fallbackHome "kit\setup\lib"
    if (Test-Path (Join-Path $fallbackLib "exakit-common.ps1")) {
        $libDir = $fallbackLib
    } else {
        Write-Host "exakit: cannot find the kit library (looked in $scriptDir\lib and $fallbackHome\kit)" -ForegroundColor Red
        exit 1
    }
}

. (Join-Path $libDir "exakit-common.ps1")
. (Join-Path $libDir "nano.ps1")
. (Join-Path $libDir "exapump.ps1")
. (Join-Path $libDir "mcp.ps1")

function Get-RuntimeType { return (Get-ExakitManifestValue "runtime.type") }

function Assert-ExakitInstalled {
    if (-not (Test-Path $script:ManifestPath)) { Fail "No installation found. Run the installer first." }
    if (-not (Get-RuntimeType)) { Fail "No runtime recorded in the manifest yet." }
}

function Invoke-CmdStatus {
    if (-not (Test-Path $script:ManifestPath)) {
        Write-Host "Not installed (no manifest at $script:ManifestPath)"
        return
    }
    $type = Get-RuntimeType
    Write-Host "Kit level:  $(Get-ExakitManifestValue 'kit_level')"
    Write-Host "Runtime:    $(if ($type) { $type } else { 'none' })"
    $status = switch ($type) { "nano" { Get-NanoStatus } default { "unknown" } }
    Write-Host "Status:     $status"
    $steps = @(Get-ExakitManifestValue "steps_completed")
    Write-Host "Steps done: $($steps -join ', ')"
    Write-Host "Manifest:   $script:ManifestPath"
}

function Invoke-CmdStart {
    Assert-ExakitInstalled
    switch (Get-RuntimeType) { "nano" { Start-Nano } }
}

function Invoke-CmdStop {
    Assert-ExakitInstalled
    switch (Get-RuntimeType) { "nano" { Stop-Nano } }
}

function Invoke-CmdTeardown {
    param([switch]$Data)
    Assert-ExakitInstalled
    $type = Get-RuntimeType
    Warn2 "This removes the local Exasol runtime ($type)."
    if ($Data) { Warn2 "It will ALSO delete all database content." }
    if (-not (Confirm-ExakitPrompt "Continue with teardown?" $false)) { Info "Teardown cancelled"; return }
    switch ($type) { "nano" { Remove-Nano -Data:$Data } }
    Ok "Teardown finished. Credentials, logs and the manifest remain in $script:ExakitHome"
    Info "Remove them with: Remove-Item -Recurse -Force $script:ExakitHome"
}

function Invoke-CmdVersion {
    if (-not (Test-Path $script:ManifestPath)) { Write-Host "Not installed (no manifest at $script:ManifestPath)"; return }
    Write-Host "Kit level:      $(Get-ExakitManifestValue 'kit_level')"
    Write-Host "Kit source:     $(Get-ExakitManifestValue 'kit.source')"
    Write-Host "Installed at:   $(Get-ExakitManifestValue 'installed_at')"
    $runtimeVersion = Get-ExakitManifestValue "runtime.version"
    if (-not $runtimeVersion) { $runtimeVersion = Get-ExakitManifestValue "runtime.image" }
    Write-Host "Runtime:        $(Get-RuntimeType) $runtimeVersion"
    Write-Host "exapump:        $(Get-ExakitManifestValue 'components.exapump.version')"
    Write-Host "MCP server:     $(Get-ExakitManifestValue 'components.mcp_server.package') $(Get-ExakitManifestValue 'components.mcp_server.version')"
}

function Invoke-CmdLogs {
    $latest = Get-ChildItem -Path $script:LogDir -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { Write-Host $latest.FullName } else { Write-Host "No logs found in $script:LogDir" -ForegroundColor Red; exit 1 }
}

function Invoke-CmdLoadData {
    param([string]$ForceFlag = "")
    Assert-ExakitInstalled
    if ($ForceFlag -and $ForceFlag -ne "-Force" -and $ForceFlag -ne "--force") {
        Fail "Unknown option '$ForceFlag' for load-data (only -Force/--force is supported)."
    }
    Initialize-ExakitLogging
    $kitRoot = Get-ExakitRepoRoot
    if (-not $kitRoot) { Fail "Could not find the kit's sql/ and data/ files to load." }
    Info "Loading the sample dataset (log: $script:LogFile)"
    Invoke-ExakitSampleDataLoad -KitRoot $kitRoot -Force:([bool]$ForceFlag)
}

function Invoke-CmdDataLoadMenu {
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    Show-ExakitDataLoadMenu
}

function Invoke-CmdMcpConfigs {
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not (Update-ExakitMcpConfigs)) { Fail "Could not generate MCP client configs" }
}

function Invoke-CmdMcpSetup {
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not (Invoke-McpSetup)) { Fail "Could not complete MCP client setup" }
}

function Invoke-CmdMcpOperation {
    param([Parameter(Mandatory)][string]$Operation, [string[]]$OpArgs = @())
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not (Invoke-McpOperation -Operation $Operation -InputArgs $OpArgs)) {
        Fail "Could not complete MCP $Operation"
    }
}

function Invoke-CmdMcpRestore {
    param([string]$SnapshotId = "")
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    if (-not (Invoke-McpRestore -SnapshotId $SnapshotId)) { Fail "Could not restore managed MCP configuration" }
}

function Invoke-CmdCatalog {
    param([string]$Search = "")
    $catalogPath = Join-Path $libDir "catalog.tsv"
    if (-not (Test-Path $catalogPath)) { Fail "Catalog data not found: $catalogPath" }

    # Let the box-drawing / bullet glyphs render on the Windows console, which
    # defaults to a non-UTF-8 code page; restore the previous encoding after.
    $prevEnc = [Console]::OutputEncoding
    try {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

        $q = $Search.ToLowerInvariant()
        $rule = "$([char]0x2501)" * 49   # heavy horizontal line

        Write-Host ""
        Write-Host "  $rule" -ForegroundColor Cyan
        Write-Host "   $([char]0x25B8) EXASOL" -ForegroundColor Cyan -NoNewline
        Write-Host "  $([char]0x00B7)  starter kit"
        if ($q) {
            Write-Host "     command catalog - results for `"$q`"" -ForegroundColor DarkGray
        } else {
            Write-Host "     command catalog $([char]0x00B7) exakit $([char]0x00B7) exapump $([char]0x00B7) exasol" -ForegroundColor DarkGray
        }
        Write-Host "  $rule" -ForegroundColor Cyan
        Write-Host ""

        $rows = Import-Csv -Path $catalogPath -Delimiter "`t"
        $labels = [ordered]@{
            exakit  = "exakit   - kit lifecycle & MCP management"
            exapump = "exapump  - data loading CLI"
            exasol  = "exasol   - database & AI (MCP) bridge"
        }
        $found = $false
        foreach ($tool in $labels.Keys) {
            $entries = @($rows | Where-Object {
                $_.tool -eq $tool -and (
                    -not $q -or "$($_.tool) $($_.command) $($_.options) $($_.description)".ToLowerInvariant().Contains($q)
                )
            })
            if ($entries.Count -eq 0) { continue }
            $found = $true
            Write-Host "  $($labels[$tool])" -ForegroundColor Green
            foreach ($e in $entries) {
                $name = if ($tool -eq "exasol") { $e.command } else { "$tool $($e.command)" }
                if ($e.options) {
                    Write-Host "    $name " -ForegroundColor White -NoNewline
                    Write-Host $e.options -ForegroundColor DarkGray
                } else {
                    Write-Host "    $name" -ForegroundColor White
                }
                Write-Host "        $($e.description)"
            }
            Write-Host ""
        }

        if (-not $found) {
            Write-Host "  No commands match `"$q`".  Try: exakit catalog mcp" -ForegroundColor DarkGray
            Write-Host ""
            return
        }
        Write-Host "  Tip: " -ForegroundColor DarkGray -NoNewline
        Write-Host "exakit catalog <search>   e.g. exakit catalog data $([char]0x00B7) exakit catalog mcp"
    } finally {
        try { [Console]::OutputEncoding = $prevEnc } catch { }
    }
}

function Show-ExakitUsage {
    # Print every leading comment line (from line 2 on) up to the first
    # non-comment line - avoids a hard-coded line count going stale whenever
    # the header comment above is edited. Uses a real `foreach` statement
    # (not ForEach-Object): `break` inside a ForEach-Object script block with
    # no enclosing loop terminates the whole calling scope, not just the loop.
    foreach ($line in (Get-Content $PSCommandPath | Select-Object -Skip 1)) {
        if (-not $line.StartsWith("#")) { break }
        Write-Host ($line -replace '^# ?', '')
    }
}

try {
    switch ($Command) {
        "preflight"    { Test-NanoRequirements }
        "status"       { Invoke-CmdStatus }
        "version"      { Invoke-CmdVersion }
        "info"         { Show-ExakitConnectionPanel }
        "start"        { Invoke-CmdStart }
        "stop"         { Invoke-CmdStop }
        "load-data"    { Invoke-CmdLoadData -ForceFlag ($RestArgs | Select-Object -First 1) }
        "data-load"    { Invoke-CmdDataLoadMenu }
        "mcp-configs"  { Invoke-CmdMcpConfigs }
        "mcp-setup"    { Invoke-CmdMcpSetup }
        "mcp-status"   { Invoke-CmdMcpOperation -Operation "status" -OpArgs $RestArgs }
        "mcp-validate" { Invoke-CmdMcpOperation -Operation "validate" -OpArgs $RestArgs }
        "mcp-repair"   { Invoke-CmdMcpOperation -Operation "repair" -OpArgs $RestArgs }
        "mcp-doctor"   { Invoke-CmdMcpOperation -Operation "doctor" -OpArgs $RestArgs }
        "mcp-remove"   { Invoke-CmdMcpOperation -Operation "uninstall" -OpArgs $RestArgs }
        "mcp-restore"  { Invoke-CmdMcpRestore -SnapshotId ($RestArgs | Select-Object -First 1) }
        "teardown"     { Invoke-CmdTeardown -Data:($RestArgs -contains "-Data" -or $RestArgs -contains "--data") }
        "logs"         { Invoke-CmdLogs }
        { $_ -in @("catalog", "catlog") } { Invoke-CmdCatalog -Search ($RestArgs | Select-Object -First 1) }
        { $_ -in @("help", "-h", "--help") } { Show-ExakitUsage }
        default {
            Write-Host "exakit: unknown command '$Command'" -ForegroundColor Red
            Show-ExakitUsage
            exit 2
        }
    }
} catch [ExakitFailException] {
    # Fail() already printed the error and the log path; just set the exit code.
    exit 1
} catch {
    Write-Host "  x Unexpected error: $_" -ForegroundColor Red
    exit 1
}
