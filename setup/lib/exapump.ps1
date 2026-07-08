# exapump.ps1 - exapump installation, connection, and guided data-loading
# module (Windows / PowerShell path).
#
# Dot-sourced by setup-windows-docker.ps1 and setup/exakit.ps1 after
# exakit-common.ps1. Mirrors setup/lib/exapump.sh function-for-function.
#
# exapump facts:
#   - release assets: exapump-<ver>-{macos,linux}-{aarch64,x86_64},
#     exapump-<ver>-windows-x86_64.exe (no Windows ARM64 build published)
#   - profiles: %USERPROFILE%\.exapump\config.toml (TOML, one section/profile)
#   - SQL from a file: exapump sql -p <profile> < file.sql
#   - CSV/Parquet load: exapump upload <file> --table <schema.table>

$script:ExapumpProfile = if ($env:EXAKIT_EXAPUMP_PROFILE) { $env:EXAKIT_EXAPUMP_PROFILE } else { "starter-kit" }
$script:ExapumpBinPath = Join-Path $script:BinDir "exapump.exe"
$script:ExapumpConfigPath = Join-Path $HOME ".exapump\config.toml"

# Test-ExapumpSucceeded - decide whether an exapump invocation succeeded.
#
# The Windows exapump.exe build can return a NON-ZERO exit code even when the
# statement executed successfully (observed: `SELECT 1` returns "[1/1]
# SELECT 1 1 rows" and exits non-zero), so exit code alone is not a reliable
# success signal on Windows. macOS/Linux exapump exits 0 on success, so exit
# code 0 is still trusted as the fast path; a non-zero exit is only treated
# as failure when the *output* actually looks like an error. This keeps
# behavior identical where exit codes are reliable and recovers correctly
# where they are not, while still catching genuine failures (auth, refused
# connection, syntax errors) which always print error text.
function Test-ExapumpSucceeded {
    param([int]$ExitCode, [AllowEmptyString()][string]$Output)
    $text = "$Output"
    # exapump prints an authoritative per-run summary: "<n> statement(s)
    # executed, <m> failed". Trust it FIRST - the exit code is unreliable on
    # Windows (non-zero even on success), and that summary line itself contains
    # the word "failed" ("0 failed"), which the generic error scan below would
    # otherwise treat as a failure. m == 0 means every statement succeeded.
    if ($text -match '(?im)(\d+)\s+statements?\s+executed,\s*(\d+)\s+failed') {
        return ([int]$Matches[2] -eq 0)
    }
    if ($ExitCode -eq 0) { return $true }
    if ($text -match '(?im)\b(error|exception|failed|failure|denied|refused|unable|cannot|could not|not found|no such|timeout|timed out|syntax error|invalid|unauthorized|authentication)\b') {
        return $false
    }
    if ($text -match '\[\d+/\d+\]' -or $text -match '(?im)\b\d+\s+rows?\b') {
        return $true
    }
    return $false
}

# Write-ExapumpOutput - print captured exapump output indented under a header,
# skipping empty output. Centralizes the "yellow header + indented lines" block
# that several loaders used to inline so the presentation stays consistent.
function Write-ExapumpOutput {
    param([AllowEmptyString()][string]$Output, [string]$Header = "exapump output:")
    if (-not "$Output".Trim()) { return }
    Write-Host "  $Header" -ForegroundColor Yellow
    "$Output".Trim() -split "`n" | ForEach-Object { Write-Host "    $_" }
}

# Invoke-Exapump - run one exapump invocation, capturing combined output and
# the (unreliable-on-Windows) exit code, and return a structured result whose
# .Success is computed by Test-ExapumpSucceeded. Every exapump call site goes
# through this so success detection is consistent and the exit-code quirk is
# handled in exactly one place.
#
# Arguments are passed as an explicit array (NOT ValueFromRemainingArguments):
# exapump's own flags include "-p", which PowerShell's parameter binder would
# otherwise try to resolve against this function's common parameters
# (-ProgressAction / -PipelineVariable) and fail with an "ambiguous parameter"
# error before the args ever reach exapump.
function Invoke-Exapump {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = ""
    $code = 1
    try {
        $out = & (Get-ExapumpCli) @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } catch {
        $out = "$_"
    }
    if ($script:LogFile) { "exapump $($Arguments -join ' ')" | Add-Content -Path $script:LogFile; $out | Add-Content -Path $script:LogFile }
    return @{ Output = $out; ExitCode = $code; Success = (Test-ExapumpSucceeded -ExitCode $code -Output $out) }
}

function Get-ExapumpAssetName {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { return "exapump-$($script:ExapumpVersion)-windows-x86_64.exe" }
        default { return $null }  # no Windows ARM64 build published
    }
}

# Digest of the pinned release (published by the release API). When the
# version is overridden the digest is fetched from the API instead.
function Get-ExapumpPinnedSha256 {
    param([Parameter(Mandatory)][string]$AssetName)
    switch ($AssetName) {
        "exapump-0.11.2-windows-x86_64.exe" { return "8a2e8199a94f1b21782e4c68179948bfa43217c82c9b9b2a25eaec4532305237" }
        default { return $null }
    }
}

function Get-ExapumpDigestFromApi {
    param([Parameter(Mandatory)][string]$AssetName)
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:ExapumpRepo)/releases/tags/v$($script:ExapumpVersion)" -UseBasicParsing
    } catch {
        return $null
    }
    $asset = $release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if (-not $asset -or -not $asset.digest) { return $null }
    if ($asset.digest -notlike "sha256:*") { return $null }
    return $asset.digest.Substring(7)
}

function Get-ExapumpCli {
    $cmd = Get-Command exapump -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $script:ExapumpBinPath
}

function Install-Exapump {
    $asset = Get-ExapumpAssetName
    if (-not $asset) {
        Fail "Unsupported CPU architecture: $($env:PROCESSOR_ARCHITECTURE). exapump publishes a Windows build for x86_64 only."
    }

    $existing = Get-ExapumpCli
    if (Test-Path $existing) {
        # Trust the existing binary only if it actually runs - an interrupted
        # earlier download can leave a broken file at the same path. Wrapped:
        # a broken binary's stderr write must mean "reinstall", not an
        # uncaught exception under $ErrorActionPreference = 'Stop'.
        $existingWorks = $false
        $previousEAP = $ErrorActionPreference
        try {
            # Continue (not the global Stop) so a working binary that writes an
            # incidental line to stderr isn't turned into a terminating error on
            # Windows PowerShell 5.1 and needlessly reinstalled - the exit code
            # is the real signal. Same fix as Get-NanoEngine / Invoke-ExakitLogged.
            $ErrorActionPreference = "Continue"
            & $existing --version *> $null
            $existingWorks = ($LASTEXITCODE -eq 0)
        } catch { } finally {
            $ErrorActionPreference = $previousEAP
        }
        if ($existingWorks) {
            Ok "exapump already installed: $existing"
            Set-ExapumpManifest
            return
        }
        Warn2 "Existing exapump binary does not run (interrupted download?) - reinstalling"
        Remove-Item -Force $existing -ErrorAction SilentlyContinue
    }

    $url = "https://github.com/$($script:ExapumpRepo)/releases/download/v$($script:ExapumpVersion)/$asset"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-exapump-$([guid]::NewGuid().ToString('N')).exe"

    Info "Downloading exapump v$($script:ExapumpVersion) ($asset)"
    Get-ExakitFile -Url $url -Dest $tmp

    $expected = Get-ExapumpPinnedSha256 $asset
    if (-not $expected) { $expected = Get-ExapumpDigestFromApi $asset }
    if ($expected) {
        Test-ExakitSha256 -Path $tmp -Expected $expected
    } else {
        Warn2 "No digest available for $asset - continuing without checksum verification"
    }

    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    Move-Item -Force $tmp $script:ExapumpBinPath
    Confirm-ExakitOnPath $script:BinDir
    Ok "exapump installed: $script:ExapumpBinPath"
    Set-ExapumpManifest
}

function Set-ExapumpManifest {
    Set-ExakitManifestValue "components.exapump.version" $script:ExapumpVersion
    Set-ExakitManifestValue "components.exapump.path" (Get-ExapumpCli)
}

# New-ExapumpProfile - write the kit's connection profile from the manifest.
# Managed section, safe to re-run; other profiles in the same file untouched.
function New-ExapumpProfile {
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    if (-not $dsn) { Fail "No runtime DSN in the manifest - install the database first." }
    $host_, $port = $dsn -split ":", 2
    $user = Get-ExakitManifestValue "runtime.user"
    if (-not $user) { $user = "sys" }

    $pwFile = Get-ExakitManifestValue "runtime.password_file"
    $password = ""
    if ($pwFile -and (Test-Path $pwFile)) {
        $password = (Get-Content $pwFile -Raw).TrimEnd("`r", "`n")
    }
    if (-not $password) {
        $password = Read-ExakitPrompt "Database password for user $user (leave blank to skip profile creation)" ""
    }
    if (-not $password) {
        Warn2 "No database password available - create the profile manually with: exapump profile init $($script:ExapumpProfile)"
        return
    }

    # If the runtime password wasn't already on file (mirrors exapump.sh: an
    # adopted deployment with unreadable secrets, so the password came from the
    # prompt above), remember it so Test-ExapumpConnection can persist it AFTER
    # confirming it works. The MCP step needs runtime.password_file, but saving
    # a mistyped password before validation would make the next run reuse it
    # instead of re-prompting.
    if (-not $pwFile -or -not (Test-Path $pwFile)) {
        $script:PendingRuntimePassword = $password
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $script:ExapumpConfigPath -Parent) | Out-Null
    Set-ExapumpTomlSection -ConfigPath $script:ExapumpConfigPath -Profile $script:ExapumpProfile -Host_ $host_ -Port $port -User $user -Password $password
    Protect-ExakitFile $script:ExapumpConfigPath
    Set-ExakitManifestValue "components.exapump.profile" $script:ExapumpProfile
    Ok "Connection profile written: [$($script:ExapumpProfile)] in $script:ExapumpConfigPath"
}

function Format-TomlString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = $Value.Replace("\", "\\").Replace('"', '\"')
    return "`"$escaped`""
}

# Set-ExapumpTomlSection - replace/append a [profile] section in a TOML file,
# preserving every other section. Atomic write (temp file + rename) so an
# interrupted run never truncates a config that may hold other profiles.
function Set-ExapumpTomlSection {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$Host_,
        [Parameter(Mandatory)][string]$Port,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Password,
        [string]$Schema = ""
    )
    $content = ""
    if (Test-Path $ConfigPath) { $content = Get-Content $ConfigPath -Raw }
    if (-not $content) { $content = "" }

    $lines = @(
        "[$Profile]",
        "host = $(Format-TomlString $Host_)",
        "port = $Port",
        "user = $(Format-TomlString $User)",
        "password = $(Format-TomlString $Password)"
    )
    if ($Schema) { $lines += "schema = $(Format-TomlString $Schema)" }
    $lines += "tls = true"
    $lines += "validate_certificate = false"
    $section = ($lines -join "`n") + "`n"

    $escapedProfile = [regex]::Escape($Profile)
    $pattern = "(?s)\[$escapedProfile\][^\[]*"
    if ($content -match $pattern) {
        $content = [regex]::Replace($content, $pattern, ($section + "`n"))
        $content = $content.TrimEnd("`n") + "`n"
    } else {
        if ($content -and -not $content.EndsWith("`n`n")) {
            $content = $content.TrimEnd("`n") + "`n`n"
        }
        $content += $section
    }

    $tmp = "$ConfigPath.tmp"
    Set-Content -Path $tmp -Value $content -NoNewline
    Move-Item -Force $tmp $ConfigPath
}

# Test-ExapumpConnection - SELECT 1 through the new profile.
function Test-ExapumpConnection {
    if (-not (Get-ExakitManifestValue "components.exapump.profile")) {
        Fail "No connection profile exists (no database password was available to write one). Create it manually with 'exapump profile init $($script:ExapumpProfile)', then re-run this script."
    }
    Info "Validating the database connection (SELECT 1)"
    $lastOutput = ""
    for ($tries = 0; $tries -lt 6; $tries++) {
        $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "SELECT 1")
        $lastOutput = $result.Output
        if ($result.Success) {
            Ok "Connection works"
            Set-ExakitManifestValue "components.exapump.validated" $true
            # Now that the password is proven to work, persist it as the runtime
            # password if the runtime step could not (adopted deployment with
            # unreadable secrets) - the MCP step needs runtime.password_file.
            if ($script:PendingRuntimePassword) {
                Set-ExakitCredential "runtime_sys_password" $script:PendingRuntimePassword
                Set-ExakitManifestValue "runtime.password_file" (Join-Path $script:CredsDir "runtime_sys_password")
                $script:PendingRuntimePassword = $null
            }
            return
        }
        Start-Sleep -Seconds 5
    }
    # Surface the actual error inline instead of only in the log file - the
    # exapump/database error text (auth failure vs. connection refused vs.
    # TLS handshake error) is exactly what's needed to diagnose this, and
    # making someone go dig through a log file for it is not production-grade.
    Write-ExapumpOutput -Output $lastOutput -Header "Last attempt's output:"
    Fail "SELECT 1 failed via profile '$($script:ExapumpProfile)' after 6 attempts. Try: exapump sql -p $($script:ExapumpProfile) 'SELECT 1'"
}

# Invoke-ExapumpSqlFile <file> [description] - execute a SQL file, logged.
# Returns $true/$false instead of dying so callers (Invoke-ExakitSampleDataLoad)
# can decide whether a missing/empty file is fatal.
# Invoke-ExapumpSqlFileCapture <file> - pipe a SQL file to exapump and return a
# structured result ({ Output; ExitCode; Success }) matching Invoke-Exapump's
# shape, logging the invocation. Shared by Invoke-ExapumpSqlFile (needs only
# pass/fail) and the sample-data verification step (also scans output for FAIL
# rows), so the stdin-pipe + quirk-aware success detection lives in one place.
function Invoke-ExapumpSqlFileCapture {
    param([Parameter(Mandatory)][string]$Path)
    $out = ""
    $code = 1
    try {
        $out = Get-Content $Path -Raw | & (Get-ExapumpCli) sql -p $script:ExapumpProfile 2>&1 | Out-String
        $code = $LASTEXITCODE
    } catch {
        $out = "$_"
    }
    if ($script:LogFile) { "exapump sql -p $($script:ExapumpProfile) < $Path" | Add-Content -Path $script:LogFile; $out | Add-Content -Path $script:LogFile }
    return @{ Output = $out; ExitCode = $code; Success = (Test-ExapumpSucceeded -ExitCode $code -Output $out) }
}

function Invoke-ExapumpSqlFile {
    param([Parameter(Mandatory)][string]$Path, [string]$Description = "")
    if (-not $Description) { $Description = Split-Path $Path -Leaf }
    if (-not (Test-Path $Path) -or (Get-Item $Path).Length -eq 0) {
        Warn2 "SQL file missing or empty: $Path"
        return $false
    }
    Info "Running $Description"
    $result = Invoke-ExapumpSqlFileCapture $Path
    if (-not $result.Success) {
        Write-ExapumpOutput -Output $result.Output
        Fail "SQL file failed: $Path (see log)"
    }
    Ok "$Description done"
    return $true
}

# Invoke-ExapumpUpload <file> <schema.table> - load a CSV/Parquet file, logged.
function Invoke-ExapumpUpload {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Target)
    if (-not (Test-Path $Path) -or (Get-Item $Path).Length -eq 0) {
        Warn2 "Data file missing or empty: $Path"
        return $false
    }
    Info "Loading $(Split-Path $Path -Leaf) into $Target"
    $result = Invoke-Exapump @("upload", $Path, "--table", $Target, "-p", $script:ExapumpProfile)
    if (-not $result.Success) {
        Write-ExapumpOutput -Output $result.Output
        Fail "Upload failed: $Path -> $Target (see log)"
    }
    Ok "$(Split-Path $Path -Leaf) loaded"
    return $true
}

# Get-ExapumpRowCount <schema.table> - row count, or $null if it could not be
# read. Best-effort only: the row-count summary it feeds is cosmetic (shows
# "?" on failure) and the real load validation is 03_verify_setup.sql.
# Get-ExapumpProfilePassword <profile> - the password stored in an exapump
# profile ($script:ExapumpConfigPath), or $null. Symmetric with the writer in
# Set-ExapumpTomlSection. Lets the MCP step recover the admin password when the
# runtime step could not record runtime.password_file.
function Get-ExapumpProfilePassword {
    param([Parameter(Mandatory)][string]$Profile)
    if (-not (Test-Path $script:ExapumpConfigPath)) { return $null }
    $content = Get-Content $script:ExapumpConfigPath -Raw
    $section = [regex]::Match($content, "(?s)\[$([regex]::Escape($Profile))\](.*?)(?:\n\[|\z)")
    if (-not $section.Success) { return $null }
    $pw = [regex]::Match($section.Groups[1].Value, '(?m)^\s*password\s*=\s*"(.*)"\s*$')
    if (-not $pw.Success) { return $null }
    return $pw.Groups[1].Value
}

function Get-ExapumpRowCount {
    param([Parameter(Mandatory)][string]$Target)
    # Wrap the count in a unique delimited token (EXAKIT_RC[<n>]) so it can be
    # recovered from exapump's output no matter how the value is laid out - grid
    # vs compact, interactive TTY vs the piped, non-TTY install run. Scraping the
    # bare number was unreliable: during install exapump prints only a
    # "[1/1] ... 1 rows" status line, and the old digit-stripping fallback
    # collapsed that to "111" for EVERY table (from "[1/1]" + the single row a
    # COUNT(*) always returns). The token can't collide with that status line,
    # and the echoed query literal ("EXAKIT_RC[' || ...") never forms
    # "EXAKIT_RC[<digits>]", so only the actual result value matches.
    $sql = "SELECT 'EXAKIT_RC[' || CAST(COUNT(*) AS VARCHAR(40)) || ']' AS EXAKIT_RC FROM $Target"
    $result = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, $sql)
    if (-not $result.Success) { return $null }
    $m = [regex]::Match("$($result.Output)", 'EXAKIT_RC\[(\d+)\]')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-ExakitTableName {
    param([Parameter(Mandatory)][string]$Path)
    $base = (Split-Path $Path -Leaf) -replace '\?.*$', ''
    $base = [System.IO.Path]::GetFileNameWithoutExtension($base)
    # Parentheses required: without them "-replace" binds as a parameter of
    # ConvertTo-UpperInvariantString instead of acting as the operator.
    $table = ((ConvertTo-UpperInvariantString $base) -replace '[^A-Z0-9_]', '_')
    $table = ($table -replace '^_+', '') -replace '_+$', ''
    $table = $table -replace '_{2,}', '_'
    if (-not $table) { return "MY_TABLE" }
    return $table
}

function Get-ExakitNormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -eq "~") { return $HOME }
    if ($Path.StartsWith("~/") -or $Path.StartsWith("~\")) { return Join-Path $HOME $Path.Substring(2) }
    return $Path
}

function Test-ExakitTableTarget {
    param([Parameter(Mandatory)][string]$Target)
    if ($Target -notmatch '^[A-Za-z0-9_]+\.[A-Za-z0-9_]+$') { return $false }
    return $true
}

function Get-ExakitTargetSchema {
    param([Parameter(Mandatory)][string]$Target)
    return ConvertTo-UpperInvariantString (($Target -split '\.', 2)[0])
}

function Get-ExakitUpperTableTarget {
    param([Parameter(Mandatory)][string]$Target)
    $parts = $Target -split '\.', 2
    return "$(ConvertTo-UpperInvariantString $parts[0]).$(ConvertTo-UpperInvariantString $parts[1])"
}

function Confirm-ExakitSchemaExists {
    param([Parameter(Mandatory)][string]$Schema)
    $schemaUc = ConvertTo-UpperInvariantString $Schema
    if (-not $schemaUc) { return $false }
    $sql = "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '$schemaUc') THEN 'EXAKIT_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHEMA_MISSING' END AS STATUS"
    $check = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, $sql)
    if ("$($check.Output)" -match "EXAKIT_SCHEMA_PRESENT") { return $true }
    Info "Creating schema $schemaUc"
    $create = Invoke-Exapump @("sql", "-p", $script:ExapumpProfile, "CREATE SCHEMA $schemaUc")
    if (-not $create.Success) { Fail "Could not create schema $schemaUc" }
    return $true
}

function Confirm-ExakitLoadedTable {
    param([Parameter(Mandatory)][string]$Target)
    $rows = Get-ExapumpRowCount $Target
    if ($null -eq $rows) { Fail "Could not verify row count for $Target." }
    if ($rows -eq "0") {
        Warn2 "Verified $Target, but it currently has 0 rows."
    } else {
        Ok "Verified $Target ($rows rows)"
    }
    Set-ExakitManifestValue "data.last_load.verified_table" $Target
    Set-ExakitManifestValue "data.last_load.verified_rows" $rows
}

function Request-ExakitOptionalVerification {
    param([string]$Default = "")
    $target = Read-ExakitPrompt "Verify table after script/import (SCHEMA.TABLE, blank to skip)" $Default
    if (-not $target) { Info "Skipping table verification for this script/import."; return }
    if (-not (Test-ExakitTableTarget $target)) {
        Fail "Verification table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    }
    Confirm-ExakitLoadedTable (Get-ExakitUpperTableTarget $target)
}

function Import-ExakitLocalFile {
    while ($true) {
        $rawPath = Read-ExakitPrompt "Local CSV/text/Parquet file path (type back to return)" ""
        if ($rawPath -match '^(b|back)$') {
            Info "Returning to data loading options."
            return "back"
        }
        if (-not $rawPath) {
            Warn2 "Please enter a local CSV/text/Parquet file path, or type back to return."
            continue
        }
        $path = Get-ExakitNormalizedPath $rawPath
        if ((Test-Path $path) -and (Get-Item $path).Length -gt 0) { break }
        Warn2 "File not found or empty: $path"
    }
    $schema = if ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA } else { "STARTER_KIT" }
    $defaultTable = "$schema.$(Get-ExakitTableName $path)"
    while ($true) {
        $target = Read-ExakitPrompt "Target table (SCHEMA.TABLE, back to return)" $defaultTable
        if ($target -match '^(b|back)$') {
            Info "Returning to data loading options."
            return "back"
        }
        if (Test-ExakitTableTarget $target) { break }
        Warn2 "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    }
    $target = Get-ExakitUpperTableTarget $target
    Confirm-ExakitSchemaExists (Get-ExakitTargetSchema $target) | Out-Null
    Invoke-ExapumpUpload $path $target | Out-Null
    Set-ExakitManifestValue "data.last_load.type" "local_file"
    Set-ExakitManifestValue "data.last_load.target" $target
    Set-ExakitManifestValue "data.last_load.source" $path
    Confirm-ExakitLoadedTable $target
    Ok "Loaded $path into $target"
}

function Import-ExakitRemoteFile {
    $url = Read-ExakitPrompt "Remote CSV/text URL" ""
    if (-not $url) { Fail "Remote URL is required." }
    $name = Split-Path ($url -replace '\?.*$', '') -Leaf
    if (-not $name) { $name = "remote-data.csv" }
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-remote-data-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $tmpFile = Join-Path $tmpDir $name
    Info "Downloading remote data file"
    Get-ExakitFile -Url $url -Dest $tmpFile
    $schema = if ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA } else { "STARTER_KIT" }
    $defaultTable = "$schema.$(Get-ExakitTableName $name)"
    $target = Read-ExakitPrompt "Target table (SCHEMA.TABLE)" $defaultTable
    if (-not (Test-ExakitTableTarget $target)) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        Fail "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
    }
    $target = Get-ExakitUpperTableTarget $target
    Confirm-ExakitSchemaExists (Get-ExakitTargetSchema $target) | Out-Null
    Invoke-ExapumpUpload $tmpFile $target | Out-Null
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    Set-ExakitManifestValue "data.last_load.type" "remote_file"
    Set-ExakitManifestValue "data.last_load.target" $target
    Set-ExakitManifestValue "data.last_load.source" $url
    Confirm-ExakitLoadedTable $target
    Ok "Loaded $url into $target"
}

function Invoke-ExakitSqlScript {
    $rawPath = Read-ExakitPrompt "SQL script path" ""
    $path = Get-ExakitNormalizedPath $rawPath
    if (-not (Test-Path $path) -or (Get-Item $path).Length -eq 0) { Fail "SQL script not found or empty: $path" }
    Invoke-ExapumpSqlFile $path "SQL script ($(Split-Path $path -Leaf))" | Out-Null
    Set-ExakitManifestValue "data.last_load.type" "sql_script"
    Set-ExakitManifestValue "data.last_load.source" $path
    Request-ExakitOptionalVerification ""
    Ok "SQL script completed"
}

function Show-ExakitDatabaseImportGuidance {
    param([Parameter(Mandatory)][string]$Kind)
    Write-Host ""
    Write-Host "  $Kind"
    Write-Host "  Use this option when your source is another database and you already"
    Write-Host "  have an Exasol IMPORT statement or a script that creates the needed"
    Write-Host "  connection object. The kit will run that SQL through the starter-kit"
    Write-Host "  exapump profile and log the result."
    Write-Host ""
    Write-Host "  Typical flow:"
    Write-Host "  1. Put your IMPORT statements in a .sql file."
    Write-Host "  2. Run this option and provide that file path."
    Write-Host "  3. Verify the target table with exapump sql -p starter-kit."
    Write-Host ""
    Write-Host "  Self-signed certificate: if the source is an Exasol with a"
    Write-Host "  self-signed cert (the kit deploys one), the CONNECTION must pin"
    Write-Host "  its TLS fingerprint in the host string:"
    Write-Host "        TO 'HOST/FINGERPRINT:PORT'"
    Write-Host "  To get the fingerprint, run the IMPORT once without it: the"
    Write-Host "  'ETL-4211 ... self-signed certificate' error prints the exact"
    Write-Host "  HOST/FINGERPRINT:PORT to paste back. Never disable cert validation."
    Write-Host ""
    Write-Host "  Security: once CREATE CONNECTION runs, Exasol stores the password"
    Write-Host "  encrypted inside the database - do not leave a plaintext password"
    Write-Host "  in the .sql file; delete or scrub it after the connection exists."
    Write-Host ""
    if (Confirm-ExakitPrompt "Run an import SQL script now?" $true) {
        Invoke-ExakitSqlScript
    } else {
        Info "Skipping import execution. Run it any time with: exakit data-load"
    }
}

function Show-ExakitExapumpGuidance {
    Write-Host ""
    Write-Host "  Exapump is installed and connected."
    Write-Host "  Profile: starter-kit"
    Write-Host "  Binary:  $(Get-ExapumpCli)"
    Write-Host ""
    Write-Host "  Useful commands:"
    Write-Host "    exapump sql -p starter-kit 'SELECT CURRENT_TIMESTAMP'"
    Write-Host "    exapump upload .\data.csv --table STARTER_KIT.MY_TABLE -p starter-kit"
    Write-Host "    exapump sql -p starter-kit < .\script.sql"
    Write-Host ""
}

function Show-ExakitDataLoadMenu {
    param([switch]$InstallMode)
    if (-not (Get-ExakitManifestValue "components.exapump.profile")) {
        Fail "No exapump connection profile is recorded - re-run the installer, then retry."
    }

    while ($true) {
        Info "Choose a data loading option"
        Write-Host "    1. Bundled sample dataset (TPC-H)"
        Write-Host "    2. Local CSV/text/Parquet file"
        if ($InstallMode) {
            Write-Host "    3. Skip for now"
        } else {
            Write-Host "    3. Back"
            Write-Host "    4. Terminate"
        }
        $defaultChoice = "1"
        $choice = Read-ExakitPrompt "Choose data option" $defaultChoice
        switch ($choice) {
            "1" {
                $kitRoot = Get-ExakitRepoRoot
                if (-not $kitRoot) { Fail "Could not find the kit's sql/ and data/ files to load." }
                Invoke-ExakitSampleDataLoad -KitRoot $kitRoot
                return
            }
            "2" {
                $result = Import-ExakitLocalFile
                if ($result -eq "back") { continue }
                return
            }
            { $_ -match '^(3|b|back)$' } {
                if ($InstallMode) {
                    Info "Skipping data load. Run it any time with: exakit data-load"
                } else {
                    Info "Data loading terminated."
                }
                return
            }
            "4" {
                if ($InstallMode) {
                    Warn2 "Unknown data loading option: $choice"
                    continue
                }
                Info "Data loading terminated."
                return
            }
            "" {
                if ($InstallMode) {
                    Info "Skipping data load. Run it any time with: exakit data-load"
                } else {
                    Info "Data loading terminated."
                }
                return
            }
            default { Warn2 "Unknown data loading option: $choice" }
        }
    }
}

# Invoke-ExakitSampleDataLoad <kit_root> [-Force] - the full sample-data
# pipeline: create the schema, bulk-load every data/*.csv, run any transform,
# verify, then record the result in the manifest. One implementation, shared
# by the installer's interactive offer, `exakit data-load --force`, and the guided
# data-load menu's option 1, so the entry points cannot drift apart.
function Invoke-ExakitSampleDataLoad {
    param([Parameter(Mandatory)][string]$KitRoot, [switch]$Force)
    $schema = if ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA } else { "STARTER_KIT" }

    if (-not (Get-ExakitManifestValue "components.exapump.profile")) {
        Fail "No exapump connection profile is recorded - the exapump setup step has not completed. Re-run the installer, then retry."
    }

    if ((Get-ExakitManifestValue "data.loaded") -eq $true -and -not $Force) {
        Ok "Sample data already loaded (pass -Force to re-run)"
        return
    }

    Info "Loading the sample dataset into schema $schema"

    # 1. schema
    $schemaSql = Join-Path $KitRoot "sql\01_create_schema.sql"
    if ((Test-Path $schemaSql) -and (Get-Item $schemaSql).Length -gt 0) {
        Invoke-ExapumpSqlFile $schemaSql "schema creation (01_create_schema.sql)" | Out-Null
    } else {
        Info "Pending: sql\01_create_schema.sql not present - skipping schema step"
    }

    # 2. data files
    $dataDir = Join-Path $KitRoot "data"
    $csvFiles = @(Get-ChildItem -Path $dataDir -Filter "*.csv" -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 })
    foreach ($csv in $csvFiles) {
        $table = ConvertTo-UpperInvariantString ([System.IO.Path]::GetFileNameWithoutExtension($csv.Name))
        Invoke-ExapumpUpload $csv.FullName "$schema.$table" | Out-Null
    }
    if ($csvFiles.Count -eq 0) {
        Info "Pending: no data files in data\ - nothing to load"
        return
    }

    # 3. optional post-load transformations
    $loadSql = Join-Path $KitRoot "sql\02_load_data.sql"
    if ((Test-Path $loadSql) -and (Get-Item $loadSql).Length -gt 0) {
        Invoke-ExapumpSqlFile $loadSql "load statements (02_load_data.sql)" | Out-Null
    }

    # 4. verify - a FAIL row or a query error blocks marking the data ready.
    $verifySql = Join-Path $KitRoot "sql\03_verify_setup.sql"
    if ((Test-Path $verifySql) -and (Get-Item $verifySql).Length -gt 0) {
        Info "Verification (03_verify_setup.sql):"
        $verify = Invoke-ExapumpSqlFileCapture $verifySql
        "$($verify.Output)".Trim() -split "`n" | ForEach-Object { Write-Host $_ }
        # Two independent conditions: the query itself must have run (exapump
        # success, exit-code-quirk-aware), AND no verification check may have
        # emitted a STATUS = 'FAIL' row.
        if ((-not $verify.Success) -or ("$($verify.Output)" -match "(?im)\bFAIL\b")) {
            Fail "Verification failed (query error or a FAIL row) - see $script:LogFile. Data is loaded but not marked ready; fix the underlying issue and re-run with -Force."
        }
    }

    # 5. row-count summary + manifest flags
    Info "Row counts:"
    foreach ($csv in $csvFiles) {
        $table = ConvertTo-UpperInvariantString ([System.IO.Path]::GetFileNameWithoutExtension($csv.Name))
        $rows = Get-ExapumpRowCount "$schema.$table"
        $line = "   {0,-30} {1} rows" -f "$schema.$table", $(if ($rows) { $rows } else { "?" })
        Write-Host $line
        if ($script:LogFile) { $line | Add-Content -Path $script:LogFile }
    }
    Set-ExakitManifestValue "data.loaded" $true
    Set-ExakitManifestValue "data.schema" $schema
    Set-ExakitManifestValue "data.loaded_at" ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))
    Ok "Sample data loaded and verified"
}

# Request-ExakitDataLoadOffer <kit_root> - interactively offer the guided
# data loading menu during install. Non-interactive installs print the
# follow-up command and continue. Runs in a try/catch so a Fail() inside the
# loading flow (which calls exit) is still contained by the caller... note:
# unlike bash's subshell isolation, PowerShell's exit terminates the whole
# process, so callers that must survive a failed load run this in a child
# pwsh process instead (see setup-windows-docker.ps1).
function Request-ExakitDataLoadOffer {
    param([Parameter(Mandatory)][string]$KitRoot)
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Info "Non-interactive install - loading the bundled sample data by default."
        Invoke-ExakitSampleDataLoad -KitRoot $KitRoot
        return
    }
    Info "The database is ready for data. Loading data now lets MCP validate against real tables."
    if (-not (Confirm-ExakitPrompt "Load or verify data before MCP setup?" $true)) {
        Info "Skipping data loading. Run it any time with: exakit data-load"
        return
    }
    Show-ExakitDataLoadMenu -InstallMode
}
