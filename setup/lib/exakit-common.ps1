# exakit-common.ps1 - shared helpers for the Exasol Personal Local Starter Kit
# (Windows / PowerShell path).
#
# Dot-sourced by setup-windows-docker.ps1 and setup/exakit.ps1. Not meant to
# be executed directly. Targets Windows PowerShell 5.1 (built into every
# Windows 10/11 machine) as well as PowerShell 7+ - no version-7-only syntax
# (no ternary, no null-coalescing, no -AsHashtable on ConvertFrom-Json).
#
# Mirrors setup/lib/common.sh function-for-function so the two platforms
# cannot drift apart in behavior. Where bash shells out to a Python one-liner
# for JSON, this file uses native PowerShell JSON handling instead.

$ErrorActionPreference = "Stop"

# Suppress the progress stream for the whole kit. Two reasons: (1) it removes
# the "TCP connect to ..."-style progress banners that cmdlets like
# Test-NetConnection / Invoke-WebRequest pin to the top of the console, which
# users found noisy; (2) on Windows PowerShell 5.1 a visible progress bar makes
# Invoke-WebRequest an order of magnitude slower, so silencing it speeds up
# every download step. Callers that genuinely want progress can override.
$ProgressPreference = "SilentlyContinue"

# ---------------------------------------------------------------------------
# State locations
# ---------------------------------------------------------------------------
$script:ExakitHome   = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME ".exasol-starter-kit" }
$script:LogDir       = Join-Path $script:ExakitHome "logs"
$script:CredsDir     = Join-Path $script:ExakitHome "credentials"
$script:ManifestPath = Join-Path $script:ExakitHome "manifest.json"
$script:McpDir       = Join-Path $script:ExakitHome "mcp"
$script:BinDir       = if ($env:EXAKIT_BIN_DIR) { $env:EXAKIT_BIN_DIR } else { Join-Path $HOME ".local\bin" }
$script:ManagedPythonVersion = if ($env:EXAKIT_MANAGED_PYTHON_VERSION) { $env:EXAKIT_MANAGED_PYTHON_VERSION } else { "3.12" }
$script:McpReadonlyUser    = if ($env:EXAKIT_MCP_READONLY_USER) { $env:EXAKIT_MCP_READONLY_USER } else { "mcp_readonly" }
$script:McpReadonlySchemas = if ($env:EXAKIT_MCP_READONLY_SCHEMAS) { $env:EXAKIT_MCP_READONLY_SCHEMAS } else { "STARTER_KIT" }

# ---------------------------------------------------------------------------
# Component version policy
# ---------------------------------------------------------------------------
$script:VersionPolicy = if ($env:EXAKIT_VERSION_POLICY) { $env:EXAKIT_VERSION_POLICY } else { "latest" }
$script:NanoImage       = "exasol/nano"
$script:NanoTagFallback = if ($env:EXAKIT_NANO_TAG_FALLBACK) { $env:EXAKIT_NANO_TAG_FALLBACK } else { "2026.2.0-nano.2" }
$script:ExapumpVersionFallback = if ($env:EXAKIT_EXAPUMP_VERSION_FALLBACK) { $env:EXAKIT_EXAPUMP_VERSION_FALLBACK } else { "0.11.2" }
$script:McpVersionFallback = if ($env:EXAKIT_MCP_VERSION_FALLBACK) { $env:EXAKIT_MCP_VERSION_FALLBACK } else { "1.10.1" }
$script:NanoTag         = if ($env:EXAKIT_NANO_TAG) { $env:EXAKIT_NANO_TAG } else { "" }
$script:ExapumpVersion  = if ($env:EXAKIT_EXAPUMP_VERSION) { $env:EXAKIT_EXAPUMP_VERSION } else { "" }
$script:ExapumpRepo     = "exasol-labs/exapump"
$script:McpPackage      = if ($env:EXAKIT_MCP_PACKAGE) { $env:EXAKIT_MCP_PACKAGE } else { "exasol-mcp-server" }
$script:McpVersion      = if ($env:EXAKIT_MCP_VERSION) { $env:EXAKIT_MCP_VERSION } else { "" }
$script:DbPort          = if ($env:EXAKIT_DB_PORT) { $env:EXAKIT_DB_PORT } else { "8563" }

New-Item -ItemType Directory -Force -Path $script:ExakitHome, $script:LogDir, $script:CredsDir, $script:BinDir | Out-Null

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# One log file per process by default (mirrors bash's exakit_init_logging);
# callers that want a distinct log (load-data, exakit CLI) set $script:LogFile
# themselves before calling Initialize-ExakitLogging.
function Initialize-ExakitLogging {
    if (-not $script:LogFile) {
        $script:LogFile = Join-Path $script:LogDir ("install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    }
    New-Item -ItemType File -Force -Path $script:LogFile | Out-Null
    try { Protect-ExakitFile $script:LogFile } catch { }
}

function Write-ExakitLog([string]$Level, [string]$Msg) {
    if (-not $script:LogFile) { return }
    "{0} {1,-5} {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Msg | Add-Content -Path $script:LogFile
}
function Info([string]$Msg)  { Write-Host "==> $Msg" -ForegroundColor Blue;   Write-ExakitLog "INFO" $Msg }
function Ok([string]$Msg)    { Write-Host "  + $Msg" -ForegroundColor Green;  Write-ExakitLog "OK" $Msg }
function Warn2([string]$Msg) { Write-Host "  ! $Msg" -ForegroundColor Yellow; Write-ExakitLog "WARN" $Msg }
# ExakitFailException - a distinct exception type so callers can tell a
# deliberate Fail() apart from an unexpected error. Bash's die() only halts
# the current subshell (kit_shared_steps runs risky steps in one so a
# failure there cannot abort the whole install); PowerShell's `exit` has no
# such boundary within a single process, so Fail() throws instead. Top-level
# entry points (setup-windows-docker.ps1, exakit.ps1) catch it there and
# exit 1; interactive offers catch it locally and continue with a warning,
# matching bash's `|| true` pattern around exakit_maybe_offer_*.
class ExakitFailException : System.Exception {
    ExakitFailException([string]$Msg) : base($Msg) {}
}

function Fail([string]$Msg) {
    Write-Host "  x $Msg" -ForegroundColor Red
    Write-ExakitLog "ERROR" $Msg
    if ($script:LogFile) { Write-Host "Full log: $script:LogFile" }
    throw [ExakitFailException]::new($Msg)
}

# Run a command, sending its output to the log file only. $Cmd is invoked via
# the call operator; args come from $Args (positional after $Cmd).
#
# A native command that writes to stderr can, under $ErrorActionPreference =
# 'Stop' (set globally by every entry point), surface as an uncaught
# terminating exception instead of just a non-zero exit code - this is a
# real, well-documented PowerShell quirk (worse on Windows PowerShell 5.1
# than on 7+) and is exactly what happened when Docker Desktop wasn't
# running: the friendly "Docker is installed but not running" message never
# ran because the underlying `docker info` call threw past it. Every caller
# of this function already checks the *returned exit code* and calls Fail()
# itself with a proper message, so any exception here is converted to a
# synthetic non-zero code instead of being allowed to escape - Fail() still
# happens, just from the caller, with the message it was meant to show.
function Invoke-ExakitLogged {
    param([Parameter(Mandatory)][string]$Cmd, [Parameter(ValueFromRemainingArguments)]$CmdArgs)
    Write-ExakitLog "CMD" "$Cmd $($CmdArgs -join ' ')"
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Native tools such as uvx and Docker can write progress/status to
        # stderr while still succeeding. With ErrorActionPreference = Stop,
        # Windows PowerShell can turn that stderr into a terminating error
        # before we can inspect the real process exit code.
        $ErrorActionPreference = "Continue"
        if ($script:LogFile) {
            & $Cmd @CmdArgs *>> $script:LogFile
        } else {
            & $Cmd @CmdArgs | Out-Null
        }
        return $LASTEXITCODE
    } catch {
        Write-ExakitLog "ERROR" "$Cmd threw instead of returning an exit code: $_"
        return 1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}
# Confirm-ExakitPrompt "Question?" [DefaultYes] - non-interactive runs
# (no console input available, e.g. piped install) take the default.
function Confirm-ExakitPrompt {
    param([string]$Question, [bool]$DefaultYes = $true)
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        return $DefaultYes
    }
    $hint = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    Write-Host "  ? $Question $hint " -ForegroundColor Cyan -NoNewline
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return $answer -match '^(y|yes)$'
}

# Read-ExakitPrompt "Question" ["default"] - non-interactive runs return the
# default immediately (mirrors bash's prompt_text over /dev/tty).
function Read-ExakitPrompt {
    param([string]$Question, [string]$Default = "")
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        return $Default
    }
    if ($Default) {
        Write-Host "  ? $Question [$Default] " -ForegroundColor Cyan -NoNewline
    } else {
        Write-Host "  ? $Question " -ForegroundColor Cyan -NoNewline
    }
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

# Test-ExakitPortInUse <port> [host] - fast, quiet "is this TCP port already
# accepting connections?" check. Replaces Test-NetConnection, which is slow
# (it also does ICMP/traceroute work) and pins a "TCP connect to ..." progress
# banner to the top of the console. A raw TcpClient with a short timeout is
# sub-second and silent. Returns $true only if something is listening.
function Test-ExakitPortInUse {
    param([Parameter(Mandatory)][int]$Port, [string]$ComputerName = "127.0.0.1", [int]$TimeoutMs = 700)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# ---------------------------------------------------------------------------
# Python / uv (mirrors require_python3 / run_python: prefer a system python,
# fall back to a uv-managed one so the kit never hard-requires a system
# Python install)
# ---------------------------------------------------------------------------
function Test-ExakitSystemPython {
    if ($env:EXAKIT_DISABLE_SYSTEM_PYTHON -eq "1") { return $false }
    return [bool](Get-Command python -ErrorAction SilentlyContinue)
}

function Get-ExakitUvBin {
    if ($script:UvBin -and (Test-Path $script:UvBin)) { return $script:UvBin }
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($cmd) { $script:UvBin = $cmd.Source; return $script:UvBin }
    $candidate = Join-Path $script:BinDir "uv.exe"
    if (Test-Path $candidate) { $script:UvBin = $candidate; return $script:UvBin }
    $candidate = Join-Path $HOME ".local\bin\uv.exe"
    if (Test-Path $candidate) { $script:UvBin = $candidate; return $script:UvBin }
    return $null
}

function Install-ExakitUv {
    $existing = Get-ExakitUvBin
    if ($existing) { return $existing }
    Info "Installing the managed Python bootstrapper (uv)"
    try {
        $env:UV_NO_MODIFY_PATH = "1"
        $env:INSTALLER_NO_MODIFY_PATH = "1"
        Invoke-Expression (Invoke-RestMethod -Uri "https://astral.sh/uv/install.ps1") *>> $script:LogFile
    } catch {
        Fail "uv installation failed (see log): $_"
    }
    $bin = Get-ExakitUvBin
    if (-not $bin) {
        $candidate = Join-Path $HOME ".local\bin\uv.exe"
        if (Test-Path $candidate) { $bin = $candidate; $script:UvBin = $bin }
    }
    if (-not $bin) { Fail "uv installed but its binary was not found in $HOME\.local\bin." }
    Ok "uv installed at $bin"
    return $bin
}

function Assert-ExakitPython {
    if (Test-ExakitSystemPython) { return }
    if (-not (Install-ExakitUv)) { Fail "A Python runtime is required, and the automatic uv bootstrap failed." }
}

# Invoke-ExakitPython <script-text> <args...> - runs Python via the system
# interpreter if present, otherwise via a uv-managed one. Returns stdout as a
# single string; throws on a non-zero exit so callers can Fail() with context.
function Invoke-ExakitPython {
    param([Parameter(Mandatory)][string]$Script, [Parameter(ValueFromRemainingArguments)]$PyArgs)
    $tmp = [System.IO.Path]::GetTempFileName() + ".py"
    try {
        Set-Content -Path $tmp -Value $Script -Encoding UTF8
        if (Test-ExakitSystemPython) {
            $out = & python $tmp @PyArgs 2>&1
        } else {
            $uv = Install-ExakitUv
            $out = & $uv run --python $script:ManagedPythonVersion --no-project python $tmp @PyArgs 2>&1
        }
        $code = $LASTEXITCODE
        if ($code -ne 0) { throw "Python exited with code ${code}: $out" }
        return ($out -join "`n")
    } finally {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Manifest (native PowerShell JSON, no Python dependency for read/write)
# ---------------------------------------------------------------------------
function Initialize-ExakitManifest {
    if (Test-Path $script:ManifestPath) {
        try {
            Get-Content $script:ManifestPath -Raw | ConvertFrom-Json | Out-Null
            return
        } catch {
            Warn2 "The install manifest is corrupted (interrupted run?) - rebuilding it; existing components will be re-detected"
            Move-Item -Force $script:ManifestPath "$script:ManifestPath.corrupt-$(Get-Date -Format 'yyyyMMddHHmmss')"
        }
    }
    $doc = [pscustomobject]@{
        manifest_version = 1
        kit_level        = 1
        installed_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        os               = "windows"
        arch             = $env:PROCESSOR_ARCHITECTURE
        runtime          = [pscustomobject]@{}
        components       = [pscustomobject]@{}
        data             = [pscustomobject]@{ loaded = $false }
        steps_completed  = @()
        log_dir          = $script:LogDir
    }
    Save-ExakitManifest $doc
}

function Read-ExakitManifest {
    if (-not (Test-Path $script:ManifestPath)) { return $null }
    return (Get-Content $script:ManifestPath -Raw | ConvertFrom-Json)
}

# Atomic write: an interrupted run must never leave a truncated manifest.
function Save-ExakitManifest($Manifest) {
    $tmp = "$script:ManifestPath.tmp"
    $Manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $tmp
    Move-Item -Force $tmp $script:ManifestPath
    try { Protect-ExakitFile $script:ManifestPath } catch { }
}

function Get-ManifestValue {
    param($Manifest, [Parameter(Mandatory)][string]$Path)
    $node = $Manifest
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $node) { return $null }
        $prop = $node.PSObject.Properties[$part]
        if ($null -eq $prop) { return $null }
        $node = $prop.Value
    }
    return $node
}

function Set-ManifestValue {
    param($Manifest, [Parameter(Mandatory)][string]$Path, $Value)
    $parts = $Path -split '\.'
    $node = $Manifest
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $part = $parts[$i]
        $prop = $node.PSObject.Properties[$part]
        if ($null -eq $prop -or $null -eq $prop.Value) {
            $child = [pscustomobject]@{}
            $node | Add-Member -NotePropertyName $part -NotePropertyValue $child -Force
            $node = $child
        } else {
            $node = $prop.Value
        }
    }
    $node | Add-Member -NotePropertyName $parts[-1] -NotePropertyValue $Value -Force
}

# manifest_get equivalent: reads from disk fresh every call, like bash.
function Get-ExakitManifestValue {
    param([Parameter(Mandatory)][string]$Path)
    $doc = Read-ExakitManifest
    if ($null -eq $doc) { return $null }
    return (Get-ManifestValue -Manifest $doc -Path $Path)
}

# manifest_set equivalent: reads, mutates, writes atomically, every call.
function Set-ExakitManifestValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $doc = Read-ExakitManifest
    if ($null -eq $doc) { Fail "Failed to update manifest ($Path): no manifest at $script:ManifestPath" }
    Set-ManifestValue -Manifest $doc -Path $Path -Value $Value
    Save-ExakitManifest $doc
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

function Set-ExakitDesiredVersions {
    Set-ExakitManifestValue "version_policy" $script:VersionPolicy
    Set-ExakitManifestValue "desired.runtime.nano" $script:NanoTag
    Set-ExakitManifestValue "desired.exapump" $script:ExapumpVersion
    Set-ExakitManifestValue "desired.mcp" $script:McpVersion
}

function Resolve-ExakitInstallVersions {
    if ($script:VersionPolicy -ne "latest") {
        if (-not $script:NanoTag) { $script:NanoTag = $script:NanoTagFallback }
        if (-not $script:ExapumpVersion) { $script:ExapumpVersion = $script:ExapumpVersionFallback }
        if (-not $script:McpVersion) { $script:McpVersion = $script:McpVersionFallback }
        Set-ExakitDesiredVersions
        return
    }

    if (-not $script:NanoTag) {
        $script:NanoTag = Get-ExakitLatestDockerTag
        if (-not $script:NanoTag) { $script:NanoTag = $script:NanoTagFallback }
    }
    if (-not $script:ExapumpVersion) {
        $script:ExapumpVersion = Get-ExakitLatestGithubRelease $script:ExapumpRepo
        if (-not $script:ExapumpVersion) { $script:ExapumpVersion = $script:ExapumpVersionFallback }
    }
    if (-not $script:McpVersion) {
        $script:McpVersion = Get-ExakitLatestPypiVersion $script:McpPackage
        if (-not $script:McpVersion) { $script:McpVersion = $script:McpVersionFallback }
    }
    Set-ExakitDesiredVersions
}

function Test-ExakitStepDone {
    param([Parameter(Mandatory)][string]$Step)
    $doc = Read-ExakitManifest
    if ($null -eq $doc) { return $false }
    $steps = Get-ManifestValue -Manifest $doc -Path "steps_completed"
    if ($null -eq $steps) { return $false }
    return ([array]$steps) -contains $Step
}

# mark_step equivalent (idempotent; does not touch a rollback stack - Windows
# path has no equivalent to bash's rollback registration).
function Set-ExakitStepDone {
    param([Parameter(Mandatory)][string]$Step)
    $doc = Read-ExakitManifest
    if ($null -eq $doc) { Fail "Failed to record step ${Step}: no manifest at $script:ManifestPath" }
    $steps = Get-ManifestValue -Manifest $doc -Path "steps_completed"
    $steps = [array]$steps
    if ($steps -notcontains $Step) { $steps += $Step }
    Set-ManifestValue -Manifest $doc -Path "steps_completed" -Value $steps
    Save-ExakitManifest $doc
    Write-ExakitLog "STEP" "completed: $Step"
}

# Begin-ExakitStep <name> <description> - announces a step, returns $false
# (caller should skip) if already done.
function Begin-ExakitStep {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Description)
    if (Test-ExakitStepDone $Name) {
        Ok "$Description - already done, skipping"
        return $false
    }
    Info $Description
    return $true
}

# ---------------------------------------------------------------------------
# Downloads and verification
# ---------------------------------------------------------------------------
function Get-ExakitFile {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Dest)
    New-Item -ItemType Directory -Force -Path (Split-Path $Dest -Parent) | Out-Null
    Write-ExakitLog "GET" "$Url -> $Dest"
    # Retry transient failures, mirroring the bash side's curl --retry 3
    # --connect-timeout policy: one network blip must not abort the install.
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120
            break
        } catch {
            Remove-Item -Force $Dest -ErrorAction SilentlyContinue
            if ($attempt -ge 3) {
                Fail "Download failed after $attempt attempts: $Url ($_)"
            }
            Warn2 "Download attempt $attempt failed - retrying in $(5 * $attempt)s"
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

function Get-ExakitSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-UpperInvariantString {
    param([Parameter(Mandatory)]$Value)
    return ([string]$Value).ToUpperInvariant()
}

function Test-ExakitSha256 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Expected)
    $actual = Get-ExakitSha256 $Path
    if ($actual -ne $Expected.ToLowerInvariant()) {
        Write-Host "  x Checksum mismatch for $(Split-Path $Path -Leaf)" -ForegroundColor Red
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $actual"
        Fail "Refusing to continue with an unverified artifact"
    }
    Ok "Checksum verified: $(Split-Path $Path -Leaf)"
}

# ---------------------------------------------------------------------------
# Credentials (NTFS ACL is the Windows equivalent of chmod 600: strip
# inherited permissions and grant only the current user).
# ---------------------------------------------------------------------------
function Protect-ExakitFile {
    param([Parameter(Mandatory)][string]$Path)
    # ACL APIs are Windows-only; this script only ships for the Windows path,
    # but the guard keeps it from throwing under cross-platform PowerShell 7
    # (e.g. running this file's tests on macOS/Linux during development).
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { return }
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
        "FullControl", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
}

function New-ExakitPassword {
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".ToCharArray()
    $bytes = New-Object byte[] 24
    # RandomNumberGenerator's static Fill() is .NET 6+/Core-only. Windows
    # PowerShell 5.1 runs on .NET Framework, which only has the classic
    # instance-based Create()+GetBytes() API - use that instead so this
    # works on both.
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# Written atomically (temp file + rename) so an interrupted run can never
# leave a truncated secret.
function Set-ExakitCredential {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    New-Item -ItemType Directory -Force -Path $script:CredsDir | Out-Null
    $target = Join-Path $script:CredsDir $Name
    $tmp = "$target.tmp"
    [System.IO.File]::WriteAllText($tmp, $Value)
    Protect-ExakitFile $tmp
    Move-Item -Force $tmp $target
}

function Get-ExakitCredential {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $script:CredsDir $Name
    if (-not (Test-Path $path)) { return "" }
    return (Get-Content $path -Raw -ErrorAction SilentlyContinue)
}

# Copy-ExakitAsset - copy a file or directory to $Destination, but skip the
# copy entirely when the source already IS the destination. The Windows
# installer (install.ps1) downloads the kit straight into
# ~\.exasol-starter-kit\kit and runs setup from there, so the "keep a copy of
# the kit next to the state" step would otherwise try to copy a directory
# onto itself and crash ("Cannot overwrite the item ... with itself"). When
# the paths differ (a standalone checkout elsewhere), any stale destination
# is removed first so a re-run can't produce a nested lib\lib copy.
function Copy-ExakitAsset {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    if (-not (Test-Path $Source)) { return }
    $srcFull = (Resolve-Path $Source).Path.TrimEnd('\', '/')
    $dstFull = $Destination.TrimEnd('\', '/')
    if (Test-Path $Destination) { $dstFull = (Resolve-Path $Destination).Path.TrimEnd('\', '/') }
    if ([string]::Equals($srcFull, $dstFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return  # already in place (installer ran from the kit copy itself)
    }
    if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
    Copy-Item -Recurse -Force $Source $Destination
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
function Ensure-ExakitOnPath {
    param([Parameter(Mandatory)][string]$Dir)
    $path = $env:Path -split ";"
    if ($path -notcontains $Dir) {
        # Update current session
        $env:Path = "$Dir;$env:Path"
        # Update permanent user-level environment variable
        $userPath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
        if ($userPath -notlike "$Dir;*" -and $userPath -notlike "*;$Dir;*" -and $userPath -notlike "*;$Dir") {
            $newPath = "$Dir;$userPath"
            [System.Environment]::SetEnvironmentVariable("PATH", $newPath, [System.EnvironmentVariableTarget]::User)
            Ok "Added $Dir to PATH (user environment variable - permanent)"
        } else {
            Ok "Added $Dir to current session PATH"
        }
    }
}

function Confirm-ExakitOnPath {
    param([Parameter(Mandatory)][string]$Dir)
    # Unlike macOS/Linux, %USERPROFILE%\.local\bin is never on the Windows
    # PATH by default, so a hint alone leaves exakit unreachable in every
    # new terminal. Add the directory to the USER PATH (no admin needed,
    # idempotent) the way other user-scope installers (uv, cargo) do.
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $userEntries = ($userPath -split ";") | Where-Object { $_ }
    if ($userEntries -notcontains $Dir) {
        try {
            $newUserPath = if ($userPath) { "$userPath;$Dir" } else { $Dir }
            [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
            Ok "Added $Dir to your user PATH (new terminals pick it up automatically)"
        } catch {
            Warn2 "$Dir could not be added to your PATH automatically."
            Write-Host "    Add it in Settings -> System -> About -> Advanced system settings -> Environment Variables,"
            Write-Host "    or run: `$env:Path += `";$Dir`" (current session only)"
        }
    }
    # Make it work in THIS session too (the machine-wide change only
    # affects newly started processes).
    if (($env:Path -split ";") -notcontains $Dir) {
        $env:Path += ";$Dir"
    }
}

# exakit_repo_root equivalent: prefer the copy under EXAKIT_HOME/kit (survives
# the original checkout moving/disappearing), fall back to this script's own
# checkout.
function Get-ExakitRepoRoot {
    $kitCopy = Join-Path $script:ExakitHome "kit"
    if (Test-Path (Join-Path $kitCopy "mcp")) { return $kitCopy }
    $commonDir = Split-Path -Parent $PSCommandPath
    $repoRoot = (Resolve-Path (Join-Path $commonDir "..\..")).Path
    if (Test-Path (Join-Path $repoRoot "mcp")) { return $repoRoot }
    return $null
}

# Install-ExakitSkills - copy the kit's AI skills into the per-user discovery
# folders so CLI agents auto-load them. Idempotent: each run replaces the
# managed copy of every skill, so edits and deletions propagate cleanly.
# Mirrors exakit_install_skills in setup/lib/common.sh.
#   $HOME\.claude\skills\<name>\   - Claude Code
#   $HOME\.agents\skills\<name>\   - Codex, Cursor, other open-standard agents
function Install-ExakitSkills {
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { Warn2 "Could not locate the kit to find its skills\ directory."; return $false }
    $skillsSrc = Join-Path $repoRoot "skills"
    if (-not (Test-Path $skillsSrc)) { Warn2 "No skills\ directory in this kit build yet - nothing to install."; return $false }

    $installed = 0
    foreach ($skillDir in (Get-ChildItem -Path $skillsSrc -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path (Join-Path $skillDir.FullName "SKILL.md"))) { continue }
        $name = $skillDir.Name
        foreach ($destRoot in @((Join-Path $HOME ".claude\skills"), (Join-Path $HOME ".agents\skills"))) {
            $dest = Join-Path $destRoot $name
            if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Copy-Item -Recurse -Force -Path (Join-Path $skillDir.FullName "*") -Destination $dest
        }
        Ok "Installed skill: $name"
        $installed++
    }
    if ($installed -eq 0) { Warn2 "No SKILL.md files found under $skillsSrc - nothing to install."; return $false }
    Info "Skills installed for Claude Code (~\.claude\skills) and open-standard agents (~\.agents\skills)."
    Info "Restart or reload your AI client to pick them up."
    return $true
}

# Request-ExakitSkillsInstallOffer - after setup, place the skills where CLI
# agents can find them. Mirrors exakit_maybe_offer_skills_install; matches the
# MCP-offer behaviour on this path (installs by default when non-interactive).
function Request-ExakitSkillsInstallOffer {
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { return }
    $skillsSrc = Join-Path $repoRoot "skills"
    if (-not (Test-Path $skillsSrc)) { return }
    $hasSkill = Get-ChildItem -Path $skillsSrc -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "SKILL.md") }
    if (-not $hasSkill) { return }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Info "Non-interactive install - installing the kit's AI skills by default."
        [void](Install-ExakitSkills)
        return
    }
    if (-not (Confirm-ExakitPrompt "Install the kit's AI skills for your CLI agent (Claude Code / Codex)?" $true)) {
        Info "Skipping skills install for now. You can run: exakit skills-install"
        return
    }
    if (-not (Install-ExakitSkills)) {
        Warn2 "Skills install did not finish cleanly. Retry any time with: exakit skills-install"
    }
}

# connection_panel equivalent - printed at the end of setup and via `exakit info`.
function Show-ExakitConnectionPanel {
    if (-not (Test-Path $script:ManifestPath)) { Warn2 "No installation found ($script:ManifestPath missing)"; return }
    $type    = Get-ExakitManifestValue "runtime.type"
    $dsn     = Get-ExakitManifestValue "runtime.dsn"
    $user    = Get-ExakitManifestValue "runtime.user"
    $pwFile  = Get-ExakitManifestValue "runtime.password_file"
    $mcpUser = Get-ExakitManifestValue "components.mcp_server.connection.user"
    $mcpPwf  = Get-ExakitManifestValue "components.mcp_server.connection.password_file"
    $exapumpPath    = Get-ExakitManifestValue "components.exapump.path"
    $exapumpProfile = Get-ExakitManifestValue "components.exapump.profile"
    $mcpConfigs     = Get-ExakitManifestValue "components.mcp_server.configs"

    Write-Host ""
    Write-Host "  --------------------------------------------------------"
    Write-Host "   Exasol Starter Kit - connection details"
    Write-Host "  --------------------------------------------------------"
    Write-Host "   Runtime:      $(if ($type) { $type } else { 'unknown' })"
    Write-Host "   DSN:          $(if ($dsn) { $dsn } else { 'unknown' })"
    Write-Host "   Admin user:   $(if ($user) { $user } else { 'sys' })"
    if ($pwFile) { Write-Host "   Admin pass:   stored in $pwFile" }
    if ($mcpUser) { Write-Host "   MCP user:     $mcpUser" }
    if ($mcpPwf)  { Write-Host "   MCP pass:     stored in $mcpPwf" }
    Write-Host "   TLS:          enabled (self-signed certificate)"
    if ($exapumpPath) { Write-Host "   exapump:      $exapumpPath (profile: $exapumpProfile)" }
    if ($mcpConfigs) { Write-Host "   MCP configs:  $script:McpDir" }
    Write-Host "   Manifest:     $script:ManifestPath"
    Write-Host "   Logs:         $script:LogDir"
    Write-Host "  --------------------------------------------------------"
    Write-Host ""
}
