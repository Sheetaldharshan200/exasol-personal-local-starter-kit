# exakit.ps1 - lifecycle helper for the Exasol Personal Local Starter Kit
# (Windows / PowerShell path). Mirrors setup/exakit function-for-function.
#
# usage: exakit <command> [args]
#
#   preflight            check this machine's requirements, install nothing
#   status                show what is installed and whether it is healthy
#   version               kit source, install date, component versions
#   update-check [what]   check latest versions (all, runtime, exakit, exapump, mcp)
#   update [what]         update all or one component without deleting database data
#   info                  print the connection details panel
#   start                 start the local database
#   stop                  stop the local database
#   data-load [-Force]    open focused data loading options; -Force reloads bundled sample data
#   mcp-setup             permanently configure MCP in supported AI clients
#   mcp-status [clients]  show managed MCP state
#   mcp-validate [clients] validate managed MCP configs and connectivity
#   mcp-repair [clients]  repair managed MCP config drift
#   mcp-doctor [clients]  run MCP diagnostics
#   mcp-remove [clients]  remove managed MCP config from the supported clients
#   mcp-restore [snapshot] restore the latest (or a chosen) MCP snapshot
#   skills-install        install the kit's AI skills for CLI agents
#                         (~\.claude\skills, ~\.agents\skills)
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
    Invoke-CmdUpdateCheck -Target "all"
}

function Get-ExakitUpdateTargets {
    param([string]$Target = "all")
    switch ($Target) {
        "all" { return @("exakit", "runtime", "exapump", "mcp") }
        { $_ -in @("runtime", "database", "db") } { return @("runtime") }
        { $_ -in @("nano", "personal", "exakit", "exapump", "mcp") } { return @($Target) }
        default { Fail "Unknown update target: $Target" }
    }
}

function Get-ExakitLatestGithubRelease {
    param([Parameter(Mandatory)][string]$Repo)
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 12
        return ("" + $release.tag_name).TrimStart("v")
    } catch { return "" }
}

function Get-ExakitLatestPypiVersion {
    param([Parameter(Mandatory)][string]$Package)
    try {
        $doc = Invoke-RestMethod -Uri "https://pypi.org/pypi/$Package/json" -UseBasicParsing -TimeoutSec 12
        return "" + $doc.info.version
    } catch { return "" }
}

function Get-ExakitLatestDockerTag {
    try {
        $doc = Invoke-RestMethod -Uri "https://hub.docker.com/v2/repositories/$($script:NanoImage)/tags?page_size=100&ordering=last_updated" -UseBasicParsing -TimeoutSec 12
        $candidates = @($doc.results | ForEach-Object { $_.name } | Where-Object { $_ -match '^\d+(\.\d+)+[-._A-Za-z0-9]*$' -and $_ -notmatch 'latest' })
        if ($candidates.Count -eq 0) { return "" }
        return ($candidates | Sort-Object { [regex]::Replace($_, '\d+', { param($m) $m.Value.PadLeft(12, '0') }) } | Select-Object -Last 1)
    } catch { return "" }
}

function Test-ExakitVersionNewer {
    param([string]$Latest, [string]$Current)
    if (-not $Latest -or -not $Current -or $Latest -eq $Current) { return $false }
    $lk = [regex]::Replace($Latest.TrimStart("v"), '\d+', { param($m) $m.Value.PadLeft(12, '0') })
    $ck = [regex]::Replace($Current.TrimStart("v"), '\d+', { param($m) $m.Value.PadLeft(12, '0') })
    return ([string]::CompareOrdinal($lk, $ck) -gt 0)
}

function Get-ExakitComponentCurrent {
    param([string]$Component)
    switch ($Component) {
        "exakit" {
            $src = Get-ExakitManifestValue "kit.source"
            if ($src -and $src.Contains("@")) { return ($src -split "@")[-1] }
            return "unknown"
        }
        "exapump" { return (Get-ExakitManifestValue "components.exapump.version") }
        "mcp" { return (Get-ExakitManifestValue "components.mcp_server.version") }
        "nano" {
            $image = Get-ExakitManifestValue "runtime.image"
            if ($image -and $image.Contains(":")) { return ($image -split ":")[-1] }
            return ""
        }
        "runtime" {
            if ((Get-RuntimeType) -eq "nano") { return (Get-ExakitComponentCurrent "nano") }
            if ((Get-RuntimeType) -eq "personal") { return (Get-ExakitComponentCurrent "personal") }
            return ""
        }
        "personal" {
            if ((Get-RuntimeType) -eq "personal") { return (Get-ExakitManifestValue "runtime.version") }
            return "not installed"
        }
    }
}

function Get-ExakitComponentLatest {
    param([string]$Component)
    switch ($Component) {
        "exakit" { return (Get-ExakitLatestGithubRelease $(if ($env:EXAKIT_KIT_REPO) { $env:EXAKIT_KIT_REPO } elseif ($env:EXAKIT_REPO) { $env:EXAKIT_REPO } else { "ranjanm-chn/exasol-personal-local-starter-kit" })) }
        "exapump" { return (Get-ExakitLatestGithubRelease $script:ExapumpRepo) }
        "mcp" { return (Get-ExakitLatestPypiVersion $script:McpPackage) }
        "nano" { return (Get-ExakitLatestDockerTag) }
        "personal" { return (Get-ExakitLatestGithubRelease "exasol/exasol-personal") }
        "runtime" {
            if ((Get-RuntimeType) -eq "nano") { return (Get-ExakitComponentLatest "nano") }
            if ((Get-RuntimeType) -eq "personal") { return (Get-ExakitComponentLatest "personal") }
            return ""
        }
    }
}

function Invoke-CmdUpdateCheck {
    param([string]$Target = "all")
    if (-not (Test-Path $script:ManifestPath)) { Write-Host "Not installed (no manifest at $script:ManifestPath)"; return }
    $targets = Get-ExakitUpdateTargets -Target $Target
    Write-Host ""
    Write-Host "  Component update check"
    Write-Host "  ----------------------"
    "{0,-12} {1,-18} {2,-18} {3}" -f "Component", "Installed", "Latest", "Action" | Write-Host
    $updates = 0
    foreach ($component in $targets) {
        $actual = if ($component -eq "runtime" -and (Get-RuntimeType)) { Get-RuntimeType } else { $component }
        $current = Get-ExakitComponentCurrent $actual
        if (-not $current) { $current = "not installed" }
        $latest = Get-ExakitComponentLatest $actual
        if (-not $latest) { $latest = "unknown" }
        $action = "current"
        if ($latest -eq "unknown" -or $current -eq "unknown" -or $current -eq "not installed") {
            $action = "inspect"
        } elseif (Test-ExakitVersionNewer -Latest $latest -Current $current) {
            $action = "exakit update $component"
            $updates += 1
        }
        "{0,-12} {1,-18} {2,-18} {3}" -f $actual, $current, $latest, $action | Write-Host
    }
    Write-Host ""
    if ($updates -gt 1) { Info "Update everything with: exakit update all" }
}

function Invoke-CmdUpdate {
    param([string]$Target = "all")
    Assert-ExakitInstalled
    Initialize-ExakitLogging
    Invoke-CmdUpdateCheck -Target $Target
    foreach ($component in (Get-ExakitUpdateTargets -Target $Target)) {
        switch ($component) {
            "exakit" {
                Warn2 "Starter-kit self-update is not automated on the Windows PowerShell path yet. Re-run install.ps1 with the desired tag to refresh the kit scripts."
            }
            "runtime" {
                if ((Get-RuntimeType) -eq "nano") {
                    $latest = Get-ExakitComponentLatest "nano"
                    if ($latest) { Update-Nano -LatestTag $latest }
                }
            }
            "nano" {
                $latest = Get-ExakitComponentLatest "nano"
                if ($latest) { Update-Nano -LatestTag $latest }
            }
            "personal" {
                Warn2 "Exasol Personal local deployments are macOS-only in this kit. On Windows this target is reported for catalog parity but cannot be applied."
            }
            "exapump" {
                $latest = Get-ExakitComponentLatest "exapump"
                if ($latest) {
                    $script:ExapumpVersion = $latest
                    Remove-Item -Force (Get-ExapumpCli) -ErrorAction SilentlyContinue
                    Install-Exapump
                    New-ExapumpProfile
                    Set-ExakitManifestValue "desired.exapump" $script:ExapumpVersion
                }
            }
            "mcp" {
                $latest = Get-ExakitComponentLatest "mcp"
                if ($latest) {
                    New-McpUpdateSnapshot | Out-Null
                    $script:McpVersion = $latest
                    Install-Mcp
                    Test-McpServer
                    Warn2 "Run exakit mcp-setup to refresh permanent AI client configs with the new MCP version."
                    Set-ExakitManifestValue "desired.mcp" $script:McpVersion
                }
            }
        }
    }
}

function Invoke-CmdLogs {
    $latest = Get-ChildItem -Path $script:LogDir -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { Write-Host $latest.FullName } else { Write-Host "No logs found in $script:LogDir" -ForegroundColor Red; exit 1 }
}

function Invoke-CmdDataLoad {
    param([string]$ForceFlag = "")
    Assert-ExakitInstalled
    if ($ForceFlag -and $ForceFlag -ne "-Force" -and $ForceFlag -ne "--force") {
        Fail "Unknown option '$ForceFlag' for data-load (only -Force/--force is supported)."
    }
    Initialize-ExakitLogging
    if ($ForceFlag) {
        $kitRoot = Get-ExakitRepoRoot
        if (-not $kitRoot) { Fail "Could not find the kit's sql/ and data/ files to load." }
        Info "Reloading the bundled sample dataset (log: $script:LogFile)"
        Invoke-ExakitSampleDataLoad -KitRoot $kitRoot -Force
    } else {
        Show-ExakitDataLoadMenu
    }
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

function Invoke-CmdSkillsInstall {
    Initialize-ExakitLogging
    if (-not (Install-ExakitSkills)) { Fail "Could not install the kit's AI skills" }
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
        { $_ -in @("update-check", "updates", "outdated") } { Invoke-CmdUpdateCheck -Target ($RestArgs | Select-Object -First 1) }
        { $_ -in @("update", "upgrade") } { Invoke-CmdUpdate -Target ($RestArgs | Select-Object -First 1) }
        "info"         { Show-ExakitConnectionPanel }
        "start"        { Invoke-CmdStart }
        "stop"         { Invoke-CmdStop }
        "data-load"    { Invoke-CmdDataLoad -ForceFlag ($RestArgs | Select-Object -First 1) }
        "mcp-setup"    { Invoke-CmdMcpSetup }
        "mcp-status"   { Invoke-CmdMcpOperation -Operation "status" -OpArgs $RestArgs }
        "mcp-validate" { Invoke-CmdMcpOperation -Operation "validate" -OpArgs $RestArgs }
        "mcp-repair"   { Invoke-CmdMcpOperation -Operation "repair" -OpArgs $RestArgs }
        "mcp-doctor"   { Invoke-CmdMcpOperation -Operation "doctor" -OpArgs $RestArgs }
        "mcp-remove"   { Invoke-CmdMcpOperation -Operation "uninstall" -OpArgs $RestArgs }
        "mcp-restore"  { Invoke-CmdMcpRestore -SnapshotId ($RestArgs | Select-Object -First 1) }
        "skills-install" { Invoke-CmdSkillsInstall }
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
