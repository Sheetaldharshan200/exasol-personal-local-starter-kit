# mcp.ps1 - Exasol MCP server module: install/validate, dedicated read-only
# database user provisioning, and client config generation (Windows /
# PowerShell path).
#
# Dot-sourced by setup-windows-docker.ps1 and setup/exakit.ps1 after
# exakit-common.ps1 and exapump.ps1. Mirrors setup/lib/mcp.sh plus the
# MCP-specific functions from setup/lib/common.sh function-for-function.
#
# Guardrail layering (same as bash):
#   1. server is read-only by design
#   2. dedicated read-only database user, provisioned and posture-checked by
#      Set-McpReadonlyAccess
#   3. client configs (generated via the Python mcp package, OS-agnostic)
#      point at that user, never the admin user

$script:McpHttpPort = if ($env:EXAKIT_MCP_HTTP_PORT) { $env:EXAKIT_MCP_HTTP_PORT } else { "8123" }

# Get-UvxPath - resolve the uvx launcher to a full path. uv installs uvx into
# ~/.local/bin (or $BinDir), which is NOT on the current process's PATH right
# after install, so a bare "uvx" invocation fails during setup even though uv
# is present. Always prefer the resolved path.
function Get-UvxPath {
    $cmd = Get-Command uvx -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($dir in @($script:BinDir, (Join-Path $HOME ".local\bin"))) {
        $candidate = Join-Path $dir "uvx.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    return "uvx"
}

function Get-McpCommandPath {
    $manifestCommand = Get-ExakitManifestValue "components.mcp_server.command"
    if ($manifestCommand) { return $manifestCommand }
    return (Get-UvxPath)
}

function Get-McpSslCertValidation {
    $tls = Get-ExakitManifestValue "runtime.tls"
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    if ($tls -in @("self-signed", "self_signed", "selfsigned")) { return "no" }
    if ($dsn -match '^(127\.0\.0\.1|localhost|\[::1\]):') { return "no" }
    return "yes"
}

function Install-Mcp {
    Install-ExakitUv | Out-Null
    Info "Priming $($script:McpPackage)@$($script:McpVersion) (downloads on first use)"
    # Use the resolved uvx path, not a bare "uvx" - uv was just installed to
    # a dir that isn't on this process's PATH yet.
    $code = Invoke-ExakitLogged (Get-UvxPath) "$($script:McpPackage)@$($script:McpVersion)" "--help"
    if ($code -ne 0) { Warn2 "Could not prime the MCP server package (it will download on first client start)" }
    $uvBin = Get-ExakitUvBin
    if ($uvBin) { Set-ExakitManifestValue "components.mcp_server.uv_path" $uvBin }
    Set-ExakitManifestValue "components.mcp_server.command" (Get-McpCommandPath)
    Set-ExakitManifestValue "components.mcp_server.package" $script:McpPackage
    Set-ExakitManifestValue "components.mcp_server.version" $script:McpVersion
    Ok "MCP server ready to run via uvx"
}

# Get-McpCredentials - "user, password_file" for the client configs. Prefers
# the validated dedicated read-only user; falls back to the runtime admin
# user if MCP read-only provisioning has not run.
function Get-McpCredentials {
    $connectionUser = Get-ExakitManifestValue "components.mcp_server.connection.user"
    $connectionPwFile = Get-ExakitManifestValue "components.mcp_server.connection.password_file"
    if ($connectionUser -and $connectionPwFile) { return @{ User = $connectionUser; PasswordFile = $connectionPwFile } }
    return @{ User = (Get-ExakitManifestValue "runtime.user"); PasswordFile = (Get-ExakitManifestValue "runtime.password_file") }
}

function Resolve-McpCredentials {
    $creds = Get-McpCredentials
    $password = ""
    if ($creds.PasswordFile -and (Test-Path $creds.PasswordFile)) {
        $password = (Get-Content $creds.PasswordFile -Raw).TrimEnd("`r", "`n")
    }
    return @{ User = $creds.User; Password = $password }
}

# Test-McpServer - start the server over stdio and check it answers an MCP
# initialize handshake. Uses the same env the client configs use.
function Test-McpServer {
    Info "Validating the MCP server (stdio handshake)"
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $creds = Resolve-McpCredentials
    $command = Get-McpCommandPath
    $sslCertValidation = Get-McpSslCertValidation

    $handshakeScript = @'
import json, subprocess, sys

command, pkg, ver = sys.argv[1], sys.argv[2], sys.argv[3]
proc = subprocess.Popen(
    [command, f"{pkg}@{ver}"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True,
)
request = json.dumps({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "starter-kit-validator", "version": "1.0"},
    },
}) + "\n"
try:
    out, err = proc.communicate(request, timeout=120)
except subprocess.TimeoutExpired:
    proc.kill()
    print("handshake timed out")
    sys.exit(1)
print(err)
for line in out.splitlines():
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue
    if msg.get("id") == 1 and "result" in msg:
        info = msg["result"].get("serverInfo", {})
        print(f"handshake ok: {info.get('name')} {info.get('version')}")
        sys.exit(0)
print("no initialize result in server output")
sys.exit(1)
'@

    $handshakeOk = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $env:EXA_DSN = $dsn
        $env:EXA_USER = $creds.User
        $env:EXA_PASSWORD = $creds.Password
        $env:EXA_SSL_CERT_VALIDATION = $sslCertValidation
        try {
            $out = Invoke-ExakitPython $handshakeScript $command $script:McpPackage $script:McpVersion
            $handshakeOk = $true
            if ($script:LogFile) { $out | Add-Content -Path $script:LogFile }
            break
        } catch {
            if ($script:LogFile) { "$_" | Add-Content -Path $script:LogFile }
            if ($attempt -lt 2) { Warn2 "Handshake attempt $attempt failed - retrying"; Start-Sleep -Seconds 5 }
        } finally {
            Remove-Item Env:\EXA_DSN, Env:\EXA_USER, Env:\EXA_PASSWORD, Env:\EXA_SSL_CERT_VALIDATION -ErrorAction SilentlyContinue
        }
    }
    if ($handshakeOk) {
        Ok "MCP server answers over stdio"
        Set-ExakitManifestValue "components.mcp_server.mode" "stdio"
        Set-ExakitManifestValue "components.mcp_server.validated" $true
    } else {
        Warn2 "MCP stdio validation failed (see log). The configs are still in place; clients may show more detail."
        Set-ExakitManifestValue "components.mcp_server.validated" $false
    }
}

# ---------------------------------------------------------------------------
# Dedicated read-only database user (mirrors the MCP-specific functions in
# setup/lib/common.sh)
# ---------------------------------------------------------------------------
# Get-ExakitExapumpBin - prefers the manifest-recorded exact path (in case
# PATH has more than one exapump installed), then falls back like Get-ExapumpCli.
function Get-ExakitExapumpBin {
    $manifestPath = Get-ExakitManifestValue "components.exapump.path"
    if ($manifestPath -and (Test-Path $manifestPath)) { return $manifestPath }
    $cmd = Get-Command exapump -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if (Test-Path $script:ExapumpBinPath) { return $script:ExapumpBinPath }
    return $null
}

function ConvertTo-SqlLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return $Value.Replace("'", "''")
}

function ConvertTo-McpRedactedText {
    param([AllowEmptyString()][string]$Text, [string[]]$Secrets = @())
    $redacted = "$Text"
    foreach ($secret in $Secrets) {
        if (-not [string]::IsNullOrEmpty($secret)) {
            $redacted = $redacted -replace [regex]::Escape($secret), "<redacted>"
        }
    }
    $redacted = $redacted -replace '(?i)(IDENTIFIED\s+BY\s+)(''[^'']*''|[A-Z][A-Z0-9]*(?:\.\.\.)?)', '$1<redacted>'
    return $redacted
}

function Get-RuntimeHost {
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    if (-not $dsn) { return "" }
    return ($dsn -split ":", 2)[0]
}

function Get-RuntimePort {
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    if (-not $dsn) { return "" }
    return ($dsn -split ":", 2)[1]
}

function Get-FirstSchema {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Schemas)
    $tokens = @($Schemas -split '[,\s]+' | Where-Object { $_ })
    if ($tokens.Count -eq 0) { return "STARTER_KIT" }
    return $tokens[0]
}

# Invoke-ExapumpAdminSql - run one SQL statement through a specific exapump
# profile against a specific (usually temporary) config file, without
# touching the user's real %USERPROFILE%\.exapump\config.toml.
function Invoke-ExapumpAdminSql {
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$Profile, [Parameter(Mandatory)][string]$Sql)
    $bin = Get-ExakitExapumpBin
    if (-not $bin) { Fail "exapump is required for MCP read-only setup but was not found." }
    $previous = $env:EXAPUMP_CONFIG
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $env:EXAPUMP_CONFIG = $ConfigPath
        # Native exapump can write successful query summaries to stderr on
        # Windows. Do not let PowerShell convert that into a terminating
        # exception before Test-ExapumpSucceeded can evaluate the output.
        $ErrorActionPreference = "Continue"
        $out = @(& $bin sql -p $Profile $Sql 2>&1) -join "`n"
        $code = $LASTEXITCODE
        return @{ Output = $out; ExitCode = $code; Success = (Test-ExapumpSucceeded -ExitCode $code -Output $out) }
    } catch {
        # A native command's stderr write can surface here as an exception
        # instead of a non-zero exit code; every caller expects this shape
        # back regardless, and checks .Success / .ExitCode itself.
        $out = "$_"
        return @{ Output = $out; ExitCode = 1; Success = (Test-ExapumpSucceeded -ExitCode 1 -Output $out) }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($null -ne $previous) { $env:EXAPUMP_CONFIG = $previous } else { Remove-Item Env:\EXAPUMP_CONFIG -ErrorAction SilentlyContinue }
    }
}

# Assert-ExapumpResult - log an exapump admin-SQL result and abort (Fail) if it
# did not succeed. Collapses the repeated "log ERROR_DETAIL + red Write-Host +
# Fail" block that followed every admin SQL step. Pass -Secrets to redact
# credentials from the output before it is logged or printed.
function Assert-ExapumpResult {
    param(
        [Parameter(Mandatory)][hashtable]$Result,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FailMessage,
        [string[]]$Secrets = @()
    )
    $text = if ($Secrets.Count) { ConvertTo-McpRedactedText -Text $Result.Output -Secrets $Secrets } else { $Result.Output }
    if ($script:LogFile) { $text | Add-Content -Path $script:LogFile }
    if (-not $Result.Success) {
        Write-ExakitLog "ERROR_DETAIL" "$Label failed with exit code $($Result.ExitCode): $text"
        Write-Host "  ! $Label error details:" -ForegroundColor Red
        Write-Host "$text" -ForegroundColor Red
        Fail $FailMessage
    }
}

function Test-ExapumpSqlHasToken {
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$Profile, [Parameter(Mandatory)][string]$Sql, [Parameter(Mandatory)][string]$Token)
    $result = Invoke-ExapumpAdminSql -ConfigPath $ConfigPath -Profile $Profile -Sql $Sql
    if ($script:LogFile) { $result.Output | Add-Content -Path $script:LogFile }
    # These are sentinel-token status queries: the token's presence in the
    # output IS the ground-truth success signal, so match on it directly
    # rather than gating on exapump's (Windows-unreliable) exit code. A real
    # failure would print an error and never contain the sentinel.
    return $result.Output -match [regex]::Escape($Token)
}

function Test-ExakitIdentifier {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return $Value -match '^[A-Za-z0-9_]+$'
}

function Test-ExakitSqlPasswordToken {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return $Value -cmatch '^[A-Z][A-Z0-9]{23}$'
}

function New-ExakitSqlPasswordToken {
    # Generate alphanumeric password (A-Z, 0-9 only, no underscores) for maximum SQL compatibility
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".ToCharArray()
    $bytes = New-Object byte[] 23
    # See the comment on New-ExakitPassword in exakit-common.ps1: Fill() is
    # .NET 6+/Core-only, Windows PowerShell 5.1 needs Create()+GetBytes().
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return "A" + (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
}

# Assert-McpReadonlyPosture <config> <user> <comma-or-space-separated schemas>
# Verifies CREATE SESSION only, SELECT on every configured schema, and no
# object privileges outside those schemas - across the whole schema list, not
# just the first one, so posture checks cannot miss drift on additional
# schemas (or false-positive on their legitimate SELECT grants).
function Assert-McpReadonlyPosture {
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][string]$ReadonlyUser, [Parameter(Mandatory)][string]$Schemas)
    $identifierUser = ConvertTo-UpperInvariantString $ReadonlyUser
    $identifierLit = ConvertTo-SqlLiteral $identifierUser

    if (-not (Test-ExapumpSqlHasToken $ConfigPath "admin" "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$identifierLit' AND PRIVILEGE = 'CREATE SESSION') THEN 'EXAKIT_CREATE_SESSION_OK' ELSE 'EXAKIT_CREATE_SESSION_MISSING' END AS STATUS" "EXAKIT_CREATE_SESSION_OK")) {
        Fail "The MCP read-only user is missing CREATE SESSION."
    }
    if (-not (Test-ExapumpSqlHasToken $ConfigPath "admin" "SELECT CASE WHEN COUNT(*) = 0 THEN 'EXAKIT_SYS_PRIV_SCOPE_OK' ELSE 'EXAKIT_SYS_PRIV_SCOPE_TOO_WIDE' END AS STATUS FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$identifierLit' AND PRIVILEGE <> 'CREATE SESSION'" "EXAKIT_SYS_PRIV_SCOPE_OK")) {
        Fail "The MCP read-only user has system privileges beyond CREATE SESSION."
    }

    $schemaTokens = @($Schemas -split '[,\s]+' | Where-Object { $_ })
    $scopeClauses = @()
    foreach ($schema in $schemaTokens) {
        $schemaUc = ConvertTo-UpperInvariantString $schema
        $schemaLit = ConvertTo-SqlLiteral $schemaUc
        if (-not (Test-ExapumpSqlHasToken $ConfigPath "admin" "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_OBJ_PRIVS WHERE GRANTEE = '$identifierLit' AND PRIVILEGE = 'SELECT' AND ((OBJECT_SCHEMA = '$schemaLit') OR (OBJECT_TYPE = 'SCHEMA' AND OBJECT_NAME = '$schemaLit'))) THEN 'EXAKIT_SCHEMA_SELECT_OK' ELSE 'EXAKIT_SCHEMA_SELECT_MISSING' END AS STATUS" "EXAKIT_SCHEMA_SELECT_OK")) {
            Fail "The MCP read-only user is missing SELECT on schema $schemaUc."
        }
        $scopeClauses += "(OBJECT_SCHEMA = '$schemaLit') OR (OBJECT_TYPE = 'SCHEMA' AND OBJECT_NAME = '$schemaLit')"
    }
    if ($scopeClauses.Count -eq 0) { Fail "No MCP read-only schemas were configured to assert posture against." }
    $scopeClause = $scopeClauses -join " OR "

    if (-not (Test-ExapumpSqlHasToken $ConfigPath "admin" "SELECT CASE WHEN COUNT(*) = 0 THEN 'EXAKIT_SCHEMA_PRIV_SCOPE_OK' ELSE 'EXAKIT_SCHEMA_PRIV_SCOPE_TOO_WIDE' END AS STATUS FROM EXA_DBA_OBJ_PRIVS WHERE GRANTEE = '$identifierLit' AND NOT (PRIVILEGE = 'SELECT' AND ($scopeClause))" "EXAKIT_SCHEMA_PRIV_SCOPE_OK")) {
        Fail "The MCP read-only user has object privileges beyond SELECT on the configured schemas ($Schemas)."
    }

    foreach ($schema in $schemaTokens) {
        $schemaUc = ConvertTo-UpperInvariantString $schema
        $probe = Invoke-ExapumpAdminSql -ConfigPath $ConfigPath -Profile "mcp_readonly" -Sql "CREATE TABLE $schemaUc.EXAKIT_MCP_PERMISSION_PROBE (ID DECIMAL)"
        if ($script:LogFile) { $probe.Output | Add-Content -Path $script:LogFile }
        # This write MUST fail for a correctly-scoped read-only user. .Success
        # (exit-code-quirk-aware) rather than raw ExitCode: if the CREATE
        # actually went through, that is a real least-privilege violation and
        # we must catch it regardless of exapump's exit-code behavior.
        if ($probe.Success) {
            $cleanup = Invoke-ExapumpAdminSql -ConfigPath $ConfigPath -Profile "admin" -Sql "DROP TABLE $schemaUc.EXAKIT_MCP_PERMISSION_PROBE"
            if ($script:LogFile) { $cleanup.Output | Add-Content -Path $script:LogFile }
            Fail "Security check failed: the MCP read-only user was able to write to schema $schemaUc, but it must be read-only. Setup stopped to protect your database."
        }
    }
}

# Set-McpReadonlyAccess - create (or refresh) the dedicated read-only
# database user, grant SELECT on every configured schema, validate its
# login, and assert least-privilege posture. Safe to re-run.
function Set-McpReadonlyAccess {
    # Ensure exapump is on PATH for this session
    $exapumpBin = Get-ExakitExapumpBin
    if ($exapumpBin) {
        $binDir = Split-Path -Parent $exapumpBin
        Ensure-ExakitOnPath $binDir
    }
    
    $runtimeUser = Get-ExakitManifestValue "runtime.user"
    if (-not $runtimeUser) { Fail "runtime.user is missing; cannot prepare the MCP read-only database user." }
    $runtimePwFile = Get-ExakitManifestValue "runtime.password_file"
    $adminPassword = ""
    if ($runtimePwFile -and (Test-Path $runtimePwFile)) {
        $adminPassword = (Get-Content $runtimePwFile -Raw).TrimEnd("`r", "`n")
    }
    # Fallback (mirrors common.sh): recover the admin password from the exapump
    # profile the data step already validated. Covers adopted deployments whose
    # secrets couldn't be read, including re-runs where the exapump step is
    # skipped as "already done". Persist it forward so later runs find it.
    if (-not $adminPassword) {
        $adminPassword = Get-ExapumpProfilePassword $script:ExapumpProfile
        if ($adminPassword) {
            Set-ExakitCredential "runtime_sys_password" $adminPassword
            Set-ExakitManifestValue "runtime.password_file" (Join-Path $script:CredsDir "runtime_sys_password")
        }
    }
    if (-not $adminPassword) { Fail "No runtime database password is available (runtime.password_file is missing and the exapump '$($script:ExapumpProfile)' profile has none). Set it with 'exapump profile init $($script:ExapumpProfile)', then re-run." }
    $dbHost = Get-RuntimeHost
    $dbPort = Get-RuntimePort
    if (-not $dbHost) { Fail "runtime.dsn is missing a host; cannot prepare the MCP read-only database user." }
    if (-not $dbPort) { Fail "runtime.dsn is missing a port; cannot prepare the MCP read-only database user." }

    $readonlyUser = $script:McpReadonlyUser
    $readonlySchemas = $script:McpReadonlySchemas
    $defaultSchema = Get-FirstSchema $readonlySchemas
    $readonlyPassword = Get-ExakitCredential "mcp_readonly_password"
    if (-not (Test-ExakitSqlPasswordToken $readonlyPassword)) {
        $readonlyPassword = New-ExakitSqlPasswordToken
        Set-ExakitCredential "mcp_readonly_password" $readonlyPassword
    }

    $identifierUser = ConvertTo-UpperInvariantString $readonlyUser
    $defaultSchemaUc = ConvertTo-UpperInvariantString $defaultSchema
    if (-not (Test-ExakitIdentifier $identifierUser)) { Fail "Invalid EXAKIT_MCP_READONLY_USER: $readonlyUser" }

    $tempConfig = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-exapump-$([guid]::NewGuid().ToString('N')).toml"
    # try/finally guarantees the credential-bearing temp TOML is deleted on
    # every exit path - success, a thrown Fail, or any other exception - so no
    # individual step has to remember to clean it up.
    try {
        Set-ExapumpTomlSection -ConfigPath $tempConfig -Profile "admin" -Host_ $dbHost -Port $dbPort -User $runtimeUser -Password $adminPassword
        Set-ExapumpTomlSection -ConfigPath $tempConfig -Profile "mcp_readonly" -Host_ $dbHost -Port $dbPort -User $readonlyUser -Password $readonlyPassword -Schema $defaultSchemaUc

        # Verify the TOML config was created and is readable
        if (-not (Test-Path $tempConfig)) {
            Fail "Failed to create temporary exapump configuration file: $tempConfig"
        }
        Write-ExakitLog "DEBUG" "TOML config created at: $tempConfig"
        if ($script:LogFile) {
            Write-ExakitLog "DEBUG" "TOML config contents (passwords redacted):"
            $redactedConfig = (Get-Content $tempConfig -Raw) -replace '(?m)^(password\s*=\s*").*(")\s*$', '$1<redacted>$2'
            $redactedConfig | Add-Content -Path $script:LogFile
        }

        # Test basic connectivity before attempting user creation
        Info "Testing database connectivity with admin user"
        $connTestResult = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "SELECT 1 AS connection_test"
        Assert-ExapumpResult -Result $connTestResult -Label "Database connection test" -FailMessage "Cannot connect to database with admin credentials. Check database status and credentials."
        Ok "Database connection successful"

        $identifierLit = ConvertTo-SqlLiteral $identifierUser
        if (-not (Test-ExapumpSqlHasToken $tempConfig "admin" "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_USERS WHERE USER_NAME = '$identifierLit') THEN 'EXAKIT_MCP_USER_PRESENT' ELSE 'EXAKIT_MCP_USER_MISSING' END AS STATUS" "EXAKIT_MCP_USER_PRESENT")) {
            Info "Creating the dedicated MCP read-only database user ($readonlyUser)"
            Write-ExakitLog "SQL" "CREATE USER $identifierUser IDENTIFIED BY <redacted>"
            $r = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "CREATE USER $identifierUser IDENTIFIED BY $readonlyPassword"
            Assert-ExapumpResult -Result $r -Label "CREATE USER" -FailMessage "Could not create the MCP read-only database user." -Secrets @($readonlyPassword, $adminPassword)
        }

        Write-ExakitLog "SQL" "ALTER USER $identifierUser IDENTIFIED BY <redacted>"
        $r = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "ALTER USER $identifierUser IDENTIFIED BY $readonlyPassword"
        Assert-ExapumpResult -Result $r -Label "ALTER USER" -FailMessage "Could not refresh the MCP read-only database password." -Secrets @($readonlyPassword, $adminPassword)

        $r = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "GRANT CREATE SESSION TO $identifierUser"
        Assert-ExapumpResult -Result $r -Label "GRANT CREATE SESSION" -FailMessage "Could not grant CREATE SESSION to the MCP read-only database user."

        $schemaTokens = @($readonlySchemas -split '[,\s]+' | Where-Object { $_ })
        foreach ($schema in $schemaTokens) {
            $schemaUc = ConvertTo-UpperInvariantString $schema
            if (-not (Test-ExakitIdentifier $schemaUc)) { Fail "Invalid MCP schema name: $schema" }
            $schemaLit = ConvertTo-SqlLiteral $schemaUc
            if (-not (Test-ExapumpSqlHasToken $tempConfig "admin" "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '$schemaLit') THEN 'EXAKIT_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHEMA_MISSING' END AS STATUS" "EXAKIT_SCHEMA_PRESENT")) {
                Info "Creating starter schema $schemaUc for MCP-safe querying"
                Write-ExakitLog "SQL" "CREATE SCHEMA $schemaUc"
                $r = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "CREATE SCHEMA $schemaUc"
                Assert-ExapumpResult -Result $r -Label "CREATE SCHEMA $schemaUc" -FailMessage "Could not create schema $schemaUc for MCP access."
            }
            Write-ExakitLog "SQL" "GRANT SELECT ON SCHEMA $schemaUc TO $identifierUser"
            $r = Invoke-ExapumpAdminSql -ConfigPath $tempConfig -Profile "admin" -Sql "GRANT SELECT ON SCHEMA $schemaUc TO $identifierUser"
            Assert-ExapumpResult -Result $r -Label "GRANT SELECT ON SCHEMA $schemaUc" -FailMessage "Could not grant read-only access on schema $schemaUc."
        }

        Info "Validating dedicated MCP read-only login"
        if (-not (Test-ExapumpSqlHasToken $tempConfig "mcp_readonly" "SELECT CURRENT_USER AS EXAKIT_CURRENT_USER" $identifierUser)) {
            Fail "The MCP read-only user could not log in with the generated credentials."
        }
        if (-not (Test-ExapumpSqlHasToken $tempConfig "mcp_readonly" "SELECT 'EXAKIT_MCP_READONLY_OK' AS STATUS" "EXAKIT_MCP_READONLY_OK")) {
            Fail "The MCP read-only user did not pass the validation query."
        }
        Assert-McpReadonlyPosture -ConfigPath $tempConfig -ReadonlyUser $readonlyUser -Schemas $readonlySchemas

        Set-ExakitManifestValue "components.mcp_server.connection.user" $readonlyUser
        Set-ExakitManifestValue "components.mcp_server.connection.password_file" (Join-Path $script:CredsDir "mcp_readonly_password")
        Set-ExakitManifestValue "components.mcp_server.connection.schemas" $schemaTokens
        Set-ExakitManifestValue "components.mcp_server.connection.validated" $true
    } finally {
        Remove-Item -Force $tempConfig -ErrorAction SilentlyContinue
    }
    Ok "Dedicated MCP read-only access is configured and validated"
}

# Confirm-McpReadonlyPosture - re-run the grant-posture check against the
# database using the credentials already on file, without re-provisioning
# anything. Used by `exakit mcp-doctor` so privilege drift
# after install (e.g. someone widening a grant by hand) is actually caught.
function Confirm-McpReadonlyPosture {
    $runtimeUser = Get-ExakitManifestValue "runtime.user"
    $runtimePwFile = Get-ExakitManifestValue "runtime.password_file"
    $readonlyUser = Get-ExakitManifestValue "components.mcp_server.connection.user"
    $readonlyPwFile = Get-ExakitManifestValue "components.mcp_server.connection.password_file"
    $schemas = @(Get-ExakitManifestValue "components.mcp_server.connection.schemas")

    if (-not $runtimeUser -or -not $runtimePwFile -or -not $readonlyUser -or -not $readonlyPwFile -or $schemas.Count -eq 0) {
        return $true
    }
    if (-not (Test-Path $runtimePwFile)) { Warn2 "Runtime password file missing; skipping MCP grant-posture re-check."; return $false }
    if (-not (Test-Path $readonlyPwFile)) { Warn2 "MCP read-only password file missing; skipping MCP grant-posture re-check."; return $false }

    $schemasCsv = $schemas -join ","
    $adminPassword = (Get-Content $runtimePwFile -Raw).TrimEnd("`r", "`n")
    $readonlyPassword = (Get-Content $readonlyPwFile -Raw).TrimEnd("`r", "`n")
    $dbHost = Get-RuntimeHost
    $dbPort = Get-RuntimePort
    $defaultSchema = Get-FirstSchema $schemasCsv

    $tempConfig = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-exapump-$([guid]::NewGuid().ToString('N')).toml"
    Set-ExapumpTomlSection -ConfigPath $tempConfig -Profile "admin" -Host_ $dbHost -Port $dbPort -User $runtimeUser -Password $adminPassword
    Set-ExapumpTomlSection -ConfigPath $tempConfig -Profile "mcp_readonly" -Host_ $dbHost -Port $dbPort -User $readonlyUser -Password $readonlyPassword -Schema $defaultSchema

    Info "Re-checking MCP read-only grant posture against the database"
    try {
        Assert-McpReadonlyPosture -ConfigPath $tempConfig -ReadonlyUser $readonlyUser -Schemas $schemasCsv
        Ok "MCP read-only grant posture is still correct"
        return $true
    } catch {
        Warn2 "MCP read-only grant posture has drifted from least-privilege (see log). Run 'exakit mcp-repair' or review grants manually."
        return $false
    } finally {
        Remove-Item -Force $tempConfig -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Config generation / operations (shell out to the OS-agnostic Python mcp
# package - the same code macOS/Linux/WSL use, invoked the same way)
# ---------------------------------------------------------------------------
# Test-ExakitSystemPythonForMcp - the mcp package requires Python 3.11+ (it
# imports the stdlib `tomllib`, added in 3.11, at module load time via the
# Codex adapter). A system `python` that's older - or the Windows "App
# execution alias" stub that resolves as `python` but isn't a real
# interpreter - must NOT be used to run the module, or it fails on import.
function Test-ExakitSystemPythonForMcp {
    if (-not (Test-ExakitSystemPython)) { return $false }
    try {
        $v = & python -c "import sys; print(1 if sys.version_info >= (3, 11) else 0)" 2>$null
        return (("$v").Trim() -eq "1")
    } catch {
        return $false
    }
}

function Invoke-McpModule {
    param([Parameter(Mandatory)][string[]]$ModuleArgs)
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { return $null }
    Push-Location $repoRoot
    $previousPythonPath = $env:PYTHONPATH
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $env:PYTHONPATH = if ($previousPythonPath) { "$repoRoot;$previousPythonPath" } else { $repoRoot }
        # Under the module-global $ErrorActionPreference = 'Stop', 2>&1 turns
        # the module's FIRST stderr write into a terminating error that tears
        # the pipeline down - killing the CLI mid-run and reporting a bogus
        # ExitCode 1 with only that first line as Output, even when the module
        # would have succeeded (Python warnings and pip/uv notices go to
        # stderr). 'Continue' captures the full output and lets the real exit
        # code through. Same fix as Invoke-Exapump / Invoke-ExapumpAdminSql.
        $ErrorActionPreference = "Continue"
        if (Test-ExakitSystemPythonForMcp) {
            $out = & python -m mcp @ModuleArgs 2>&1 | Out-String
        } else {
            # Fall back to the managed uv Python (pinned to 3.12), which is
            # guaranteed to satisfy the 3.11+ requirement. uv is already a
            # hard dependency here (the MCP server itself runs via uvx).
            $uv = Install-ExakitUv
            $out = & $uv run --python $script:ManagedPythonVersion --no-project python -m mcp @ModuleArgs 2>&1 | Out-String
        }
        return @{ Output = $out; ExitCode = $LASTEXITCODE }
    } catch {
        return @{ Output = "$_"; ExitCode = 1 }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($null -ne $previousPythonPath) { $env:PYTHONPATH = $previousPythonPath } else { Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue }
        Pop-Location
    }
}

function Invoke-McpSetupCli {
    param([Parameter(Mandatory)][string[]]$Clients)
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { Warn2 "Could not find the MCP package source to configure MCP clients."; return $null }
    try { Set-McpReadonlyAccess } catch { return $null }
    $result = Invoke-McpModule (@("setup-runtime-clients", "--runtime-root", $script:ExakitHome, "--clients") + $Clients)
    if ($result.ExitCode -ne 0) {
        if ($script:LogFile) { $result.Output | Add-Content -Path $script:LogFile }
        Warn2 "MCP client setup failed (see log)."
        return $null
    }
    return $result.Output
}

function Invoke-McpOperationCli {
    param([Parameter(Mandatory)][string]$Operation, [Parameter(Mandatory)][string[]]$Clients, [string]$SnapshotId = "")
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { Warn2 "Could not find the MCP package source to manage MCP clients."; return $null }
    if ($Operation -in @("validate", "repair", "doctor")) {
        try { Set-McpReadonlyAccess } catch { return $null }
    }
    $args = @("run-runtime-operation", $Operation, "--runtime-root", $script:ExakitHome)
    if ($SnapshotId) { $args += @("--snapshot-id", $SnapshotId) }
    $args += "--clients"
    $args += $Clients
    $result = Invoke-McpModule $args
    if ($result.ExitCode -ne 0) {
        if ($script:LogFile) { $result.Output | Add-Content -Path $script:LogFile }
        Warn2 "MCP $Operation failed (see log)."
        return $null
    }
    return $result.Output
}

$script:McpClientLabels = @{ claude_desktop = "Claude Desktop"; cursor = "Cursor"; codex = "Codex" }

function Show-McpSetupSummary {
    param([Parameter(Mandatory)][string]$ResultJson)
    $doc = $ResultJson | ConvertFrom-Json
    $clients = @($doc.selected_clients) | ForEach-Object { if ($script:McpClientLabels.ContainsKey($_)) { $script:McpClientLabels[$_] } else { $_ } }
    Write-Host ""
    Write-Host "  MCP setup summary"
    Write-Host "  Mode:     managed"
    Write-Host "  Meaning:  Wrote managed MCP entries into the selected client config files."
    Write-Host "  Clients:  $(if ($clients) { $clients -join ', ' } else { 'none' })"
    Write-Host "  Status:   $($doc.status)"
    foreach ($artifact in @($doc.artifacts)) {
        $label = if ($script:McpClientLabels.ContainsKey($artifact.client)) { $script:McpClientLabels[$artifact.client] } else { $artifact.client }
        Write-Host "  File:     $label -> $($artifact.path)"
    }
    if (@($doc.findings).Count -gt 0) {
        Write-Host ""; Write-Host "  Notes:"
        foreach ($f in @($doc.findings)) { Write-Host "  - $($f.message)" }
    }
    if (@($doc.next_actions).Count -gt 0) {
        Write-Host ""; Write-Host "  Next:"
        foreach ($a in @($doc.next_actions)) { Write-Host "  - $($a.message)" }
    }
}

function Show-McpReadyPanel {
    param([string]$Mode = "")
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $mcpUser = Get-ExakitManifestValue "components.mcp_server.connection.user"
    $mcpPackage = Get-ExakitManifestValue "components.mcp_server.package"
    if (-not $mcpPackage) { $mcpPackage = $script:McpPackage }
    $mcpVersion = Get-ExakitManifestValue "components.mcp_server.version"
    if (-not $mcpVersion) { $mcpVersion = $script:McpVersion }
    $mcpCommand = Get-ExakitManifestValue "components.mcp_server.command"
    if (-not $mcpCommand) { $mcpCommand = "uvx" }
    $tls = Get-ExakitManifestValue "runtime.tls"

    Write-Host ""
    Write-Host "  MCP is ready"
    Write-Host "  Server name:   exasol"
    Write-Host "  How it runs:   your AI client starts it on demand over stdio"
    Write-Host "  Command:       $mcpCommand $mcpPackage@$mcpVersion"
    Write-Host "  Database:      $(if ($dsn) { $dsn } else { 'unknown' })"
    Write-Host "  DB user:       $(if ($mcpUser) { $mcpUser } else { 'mcp_readonly' }) (read-only)"
    if ($tls -eq "self-signed") { Write-Host "  TLS:           local self-signed certificate accepted for 127.0.0.1" }
    Write-Host "  Managed state: $script:McpDir"
    Write-Host ""
    Write-Host "  MCP setup updated the selected client config files."
    Write-Host "  Next step: restart the selected client now."
    Write-Host "  After setup/restart, look for an MCP server named: exasol"
    Write-Host ""
    Write-Host "  First prompt to try in your AI client:"
    Write-Host "  ""Use the exasol MCP server connected to my local Exasol database. List"
    Write-Host "  the available schemas and tables first. Then answer my questions with"
    Write-Host "  read-only SQL only, show me the SQL before you run it, and do not create,"
    Write-Host "  update, or delete anything."""
}

function Show-McpOperationSummary {
    param([Parameter(Mandatory)][string]$ResultJson)
    $doc = $ResultJson | ConvertFrom-Json
    $clients = @($doc.selected_clients) | ForEach-Object { if ($script:McpClientLabels.ContainsKey($_)) { $script:McpClientLabels[$_] } else { $_ } }
    Write-Host ""
    Write-Host "  MCP operation summary"
    Write-Host "  Operation: $($doc.operation)"
    Write-Host "  Clients:   $(if ($clients) { $clients -join ', ' } else { 'all managed clients' })"
    Write-Host "  Status:    $($doc.status)"
    Write-Host "  Summary:   $($doc.summary)"
    if ($doc.backup_reference) { Write-Host "  Snapshot:  $($doc.backup_reference)" }
    if (@($doc.changes).Count -gt 0) {
        Write-Host ""; Write-Host "  Changes:"
        foreach ($c in @($doc.changes)) { Write-Host "  - $($c.kind) $($c.path)" }
    }
    if (@($doc.findings).Count -gt 0) {
        Write-Host ""; Write-Host "  Notes:"
        foreach ($f in @($doc.findings)) { Write-Host "  - $($f.message)" }
    }
    if (@($doc.next_actions).Count -gt 0) {
        Write-Host ""; Write-Host "  Next:"
        foreach ($a in @($doc.next_actions)) { Write-Host "  - $($a.message)" }
    }
}

function ConvertTo-McpClientSelection {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Raw)
    $tokens = @(($Raw -replace '[,/]', ' ') -split '\s+' | Where-Object { $_ })
    if ($tokens.Count -eq 0) { return $null }
    if ($tokens.Count -eq 1 -and $tokens[0] -match '^(all|ALL|All)$') { return @("claude_desktop", "cursor", "codex") }
    $result = @()
    foreach ($token in $tokens) {
        $client = switch ($token) {
            { $_ -in @("1", "claude", "claude_desktop") } { "claude_desktop" }
            { $_ -in @("2", "cursor") } { "cursor" }
            { $_ -in @("3", "codex") } { "codex" }
            default { $null }
        }
        if (-not $client) { return $null }
        if ($result -notcontains $client) { $result += $client }
    }
    if ($result.Count -eq 0) { return $null }
    return $result
}

function Get-McpClientsFromArgs {
    param([string[]]$InputArgs = @())
    if ($InputArgs.Count -eq 0) { return @("claude_desktop", "cursor", "codex") }
    return ConvertTo-McpClientSelection ($InputArgs -join " ")
}

function Invoke-McpSetup {
    Info "MCP setup will edit the selected AI client config files."

    Write-Host ""
    Info "Choose one or more clients"
    Write-Host "    1. Claude Desktop"
    Write-Host "    2. Cursor"
    Write-Host "    3. Codex"
    Write-Host "    Enter numbers separated by commas, or type all."
    $clients = $null
    while (-not $clients) {
        $selection = Read-ExakitPrompt "Choose client numbers" "all"
        $clients = ConvertTo-McpClientSelection $selection
        if (-not $clients) { Warn2 "Please choose valid client numbers, for example 1,2,3 or all." }
    }

    Info "Applying MCP setup"
    $resultJson = Invoke-McpSetupCli -Clients $clients
    if ($resultJson) { Show-McpSetupSummary $resultJson }
    if (-not $resultJson) { return $false }
    Show-McpReadyPanel "permanent"
    Ok "MCP setup guidance is ready."
    return $true
}

function Invoke-McpOperation {
    param([Parameter(Mandatory)][string]$Operation, [string[]]$InputArgs = @())
    $clients = Get-McpClientsFromArgs $InputArgs
    if (-not $clients) { Warn2 "Please choose valid MCP clients: claude_desktop, cursor, codex, or all."; return $false }
    Info "Running MCP $Operation"
    $resultJson = Invoke-McpOperationCli -Operation $Operation -Clients $clients
    if ($resultJson) { Show-McpOperationSummary $resultJson }
    $ok = [bool]$resultJson
    if ($Operation -in @("doctor", "validate")) {
        if (-not (Confirm-McpReadonlyPosture)) { $ok = $false }
    }
    return $ok
}

function Invoke-McpRestore {
    param([string]$SnapshotId = "")
    Info "Running MCP restore"
    $resultJson = Invoke-McpOperationCli -Operation "restore" -Clients @("claude_desktop", "cursor", "codex") -SnapshotId $SnapshotId
    if ($resultJson) { Show-McpOperationSummary $resultJson }
    return [bool]$resultJson
}

function New-McpUpdateSnapshot {
    $resultJson = Invoke-McpOperationCli -Operation "backup" -Clients @("claude_desktop", "cursor", "codex")
    if (-not $resultJson) { Warn2 "MCP pre-update snapshot was not created; generated configs will still be refreshed."; return "" }
    Show-McpOperationSummary $resultJson
    try {
        $doc = $resultJson | ConvertFrom-Json
        if ($doc.backup_reference) {
            Set-ExakitManifestValue "backups.mcp_update.latest" $doc.backup_reference
            return $doc.backup_reference
        }
    } catch { }
    return ""
}

# Request-ExakitMcpSetupOffer - interactively offer to set up MCP in the
# user's AI client(s) during install. Non-interactive installs print the
# follow-up command and continue.
function Request-ExakitMcpSetupOffer {
    if ((Get-ExakitManifestValue "components.mcp_server.client_setup.completed") -eq $true) { return }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Info "Non-interactive install - setting up MCP in your AI client(s) by default."
        if (-not (Invoke-McpSetup)) {
            Warn2 "Your local runtime is installed, but MCP client setup did not finish cleanly."
            Warn2 "Retry any time with: exakit mcp-setup"
        }
        return
    }
    Info "The Exasol runtime and MCP server are ready."
    if (-not (Confirm-ExakitPrompt "Set up MCP in your AI client(s) now?" $true)) {
        Info "Skipping live MCP client setup for now. You can run: exakit mcp-setup"
        return
    }
    if (-not (Invoke-McpSetup)) {
        Warn2 "Your local runtime is installed, but MCP client setup did not finish cleanly."
        Warn2 "Retry any time with: exakit mcp-setup"
    }
}
