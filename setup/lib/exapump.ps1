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
        try {
            & $existing --version *> $null
            $existingWorks = ($LASTEXITCODE -eq 0)
        } catch { }
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
    for ($tries = 0; $tries -lt 6; $tries++) {
        $code = Invoke-ExakitLogged (Get-ExapumpCli) "sql" "-p" $script:ExapumpProfile "SELECT 1"
        if ($code -eq 0) {
            Ok "Connection works"
            Set-ExakitManifestValue "components.exapump.validated" $true
            return
        }
        Start-Sleep -Seconds 5
    }
    Fail "SELECT 1 failed through profile '$($script:ExapumpProfile)'. Try: exapump sql -p $($script:ExapumpProfile) 'SELECT 1'"
}

# Invoke-ExapumpSqlFile <file> [description] - execute a SQL file, logged.
# Returns $true/$false instead of dying so callers (Invoke-ExakitSampleDataLoad)
# can decide whether a missing/empty file is fatal.
function Invoke-ExapumpSqlFile {
    param([Parameter(Mandatory)][string]$Path, [string]$Description = "")
    if (-not $Description) { $Description = Split-Path $Path -Leaf }
    if (-not (Test-Path $Path) -or (Get-Item $Path).Length -eq 0) {
        Warn2 "SQL file missing or empty: $Path"
        return $false
    }
    Info "Running $Description"
    $exitCode = 1
    try {
        $sqlOut = Get-Content $Path -Raw | & (Get-ExapumpCli) sql -p $script:ExapumpProfile 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        $sqlOut = "$_"
    }
    if ($script:LogFile) { $sqlOut | Add-Content -Path $script:LogFile }
    if ($exitCode -ne 0) { Fail "SQL file failed: $Path (see log)" }
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
    $code = Invoke-ExakitLogged (Get-ExapumpCli) "upload" $Path "--table" $Target "-p" $script:ExapumpProfile
    if ($code -ne 0) { Fail "Upload failed: $Path -> $Target (see log)" }
    Ok "$(Split-Path $Path -Leaf) loaded"
    return $true
}

# Get-ExapumpRowCount <schema.table> - row count, or $null if it could not be read.
function Get-ExapumpRowCount {
    param([Parameter(Mandatory)][string]$Target)
    try {
        $out = & (Get-ExapumpCli) sql -p $script:ExapumpProfile "SELECT COUNT(*) FROM $Target" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
    } catch {
        return $null
    }
    $lastLine = ($out | Select-Object -Last 1)
    $digits = ($lastLine -replace '[^0-9]', '')
    if (-not $digits) { return $null }
    return $digits
}

function Get-ExakitTableName {
    param([Parameter(Mandatory)][string]$Path)
    $base = (Split-Path $Path -Leaf) -replace '\?.*$', ''
    $base = [System.IO.Path]::GetFileNameWithoutExtension($base)
    $table = ($base.ToUpperInvariant() -replace '[^A-Z0-9_]', '_')
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
    return ($Target -split '\.', 2)[0].ToUpperInvariant()
}

function Get-ExakitUpperTableTarget {
    param([Parameter(Mandatory)][string]$Target)
    $parts = $Target -split '\.', 2
    return "$($parts[0].ToUpperInvariant()).$($parts[1].ToUpperInvariant())"
}

function Confirm-ExakitSchemaExists {
    param([Parameter(Mandatory)][string]$Schema)
    $schemaUc = $Schema.ToUpperInvariant()
    if (-not $schemaUc) { return $false }
    $sql = "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '$schemaUc') THEN 'EXAKIT_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHEMA_MISSING' END AS STATUS"
    $out = ""
    try {
        $out = & (Get-ExapumpCli) sql -p $script:ExapumpProfile $sql 2>>$script:LogFile
    } catch {
        if ($script:LogFile) { "schema check failed: $_" | Add-Content -Path $script:LogFile }
    }
    if (($out -join "`n") -match "EXAKIT_SCHEMA_PRESENT") { return $true }
    Info "Creating schema $schemaUc"
    $code = Invoke-ExakitLogged (Get-ExapumpCli) "sql" "-p" $script:ExapumpProfile "CREATE SCHEMA $schemaUc"
    if ($code -ne 0) { Fail "Could not create schema $schemaUc" }
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
    $rawPath = Read-ExakitPrompt "Local CSV/text file path" ""
    $path = Get-ExakitNormalizedPath $rawPath
    if (-not (Test-Path $path) -or (Get-Item $path).Length -eq 0) { Fail "File not found or empty: $path" }
    $schema = if ($env:EXAKIT_SCHEMA) { $env:EXAKIT_SCHEMA } else { "STARTER_KIT" }
    $defaultTable = "$schema.$(Get-ExakitTableName $path)"
    $target = Read-ExakitPrompt "Target table (SCHEMA.TABLE)" $defaultTable
    if (-not (Test-ExakitTableTarget $target)) {
        Fail "Target table must look like SCHEMA.TABLE and use letters, numbers, or underscores."
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
    if (-not (Get-ExakitManifestValue "components.exapump.profile")) {
        Fail "No exapump connection profile is recorded - re-run the installer, then retry."
    }

    Info "Choose a data loading option"
    Write-Host "    1. Local CSV/Text File"
    Write-Host "    2. Remote CSV/Text File"
    Write-Host "    3. Import from Another Database"
    Write-Host "    4. Import from Another Exasol"
    Write-Host "    5. Exapump"
    Write-Host "    6. SQL Script"
    Write-Host "    7. Default: load bundled data/ folder (TPC-H sample)"
    Write-Host "    8. Skip for now"
    $defaultChoice = "7"
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { $defaultChoice = "8" }
    $choice = Read-ExakitPrompt "Choose data option" $defaultChoice
    switch ($choice) {
        "1" { Import-ExakitLocalFile }
        "2" { Import-ExakitRemoteFile }
        "3" { Show-ExakitDatabaseImportGuidance "Import from Another Database" }
        "4" { Show-ExakitDatabaseImportGuidance "Import from Another Exasol" }
        "5" { Show-ExakitExapumpGuidance }
        "6" { Invoke-ExakitSqlScript }
        "7" {
            $kitRoot = Get-ExakitRepoRoot
            if (-not $kitRoot) { Fail "Could not find the kit's sql/ and data/ files to load." }
            Invoke-ExakitSampleDataLoad -KitRoot $kitRoot
        }
        { $_ -eq "8" -or $_ -eq "" } { Info "Skipping data load. Run it any time with: exakit data-load" }
        default { Fail "Unknown data loading option: $choice" }
    }
}

# Invoke-ExakitSampleDataLoad <kit_root> [-Force] - the full sample-data
# pipeline: create the schema, bulk-load every data/*.csv, run any transform,
# verify, then record the result in the manifest. One implementation, shared
# by the installer's interactive offer, `exakit load-data`, and the guided
# data-load menu's option 7, so the entry points cannot drift apart.
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
        $table = ([System.IO.Path]::GetFileNameWithoutExtension($csv.Name)).ToUpperInvariant()
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
        $verifyStatus = 1
        try {
            $verifyOut = Get-Content $verifySql -Raw | & (Get-ExapumpCli) sql -p $script:ExapumpProfile 2>&1
            $verifyStatus = $LASTEXITCODE
        } catch {
            $verifyOut = "$_"
        }
        $verifyOut | ForEach-Object { Write-Host $_ }
        if ($script:LogFile) { $verifyOut | Add-Content -Path $script:LogFile }
        if ($verifyStatus -ne 0 -or (($verifyOut -join "`n") -match "(?i)FAIL")) {
            Fail "Verification failed (query error or a FAIL row) - see $script:LogFile. Data is loaded but not marked ready; fix the underlying issue and re-run with -Force."
        }
    }

    # 5. row-count summary + manifest flags
    Info "Row counts:"
    foreach ($csv in $csvFiles) {
        $table = ([System.IO.Path]::GetFileNameWithoutExtension($csv.Name)).ToUpperInvariant()
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
        Info "Data loading is ready. Open the guided menu any time with: exakit data-load"
        return
    }
    Info "The database is ready for data. Loading data now lets MCP validate against real tables."
    if (-not (Confirm-ExakitPrompt "Load or verify data before MCP setup?" $true)) {
        Info "Skipping data loading. Run it any time with: exakit data-load"
        return
    }
    Show-ExakitDataLoadMenu
}
