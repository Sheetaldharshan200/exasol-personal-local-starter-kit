# Quickstart — Windows with Docker Desktop

Gets you from Windows to a local Exasol database, staying entirely in **PowerShell** — no WSL terminal needed. The kit runs **Exasol Nano** as a container via Docker Desktop. (More comfortable in a Linux shell? Use the [WSL quickstart](windows-wsl.md).)

## What you need

- Windows 10/11
- **Docker Desktop, installed and running** ([get it here](https://docs.docker.com/desktop/setup/install/windows-install/) — it uses WSL 2 under the hood, its installer sets that up)
- 4 GB+ RAM, ~10 GB free disk

## Install (regular PowerShell, no admin needed)

```powershell
irm https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.ps1 | iex
```

What happens, in order:

1. Your hardware is detected and the plan is shown; the kit is downloaded to `~\.exasol-starter-kit\kit` so you can read every script
2. Docker (or Podman) is verified — if Docker Desktop isn't running you get told exactly that, and re-run after starting it
3. The pinned `exasol/nano` image is pulled; the container starts with a persistent volume, a generated password, and the SQL port on `127.0.0.1:8563` only
4. exapump (the data-loading CLI) is installed and connected with its own profile
5. You're offered the bundled sample datasets — accept them and MCP gets set up against real tables, not an empty schema
6. The MCP server is installed, a dedicated read-only database user is provisioned and posture-checked, and you're offered live client setup
7. The `exakit` command is installed to `~\.local\bin` — works the same from PowerShell or `cmd.exe`
8. You get the connection panel: DSN `127.0.0.1:8563`, admin user, dedicated MCP user, and password file locations

Want to look before it runs? `$env:EXAKIT_DRY_RUN = "1"` first — it downloads and plans, installs nothing.

## Verify

```powershell
exakit status                                       # runtime: running
exapump sql -p starter-kit 'SELECT CURRENT_TIMESTAMP'
docker ps --filter name=exasol-nano                 # container up?
```

Any SQL client (DBeaver etc.) connects with: host `127.0.0.1`, port `8563`, admin user `sys`, password from `~\.exasol-starter-kit\credentials\nano_sys_password`, certificate validation off (local self-signed).

## Connect your AI assistant

The installer offers to permanently set this up for you. Run it again any time with:

```powershell
exakit mcp-setup
```

The setup edits the selected client config files, backing up any existing config first. The managed config points at the dedicated read-only `mcp_readonly` database user, not the admin user.

Restart your AI client, then continue with the [first workflow](../demo/first-revenue-analysis.md).

**Using Claude Code or Codex CLI?** Run `exakit skills-install`, then say **"setup starter kit"** in a fresh session — the kit's AI skill drives setup and the first query for you. See [`skills/README.md`](../skills/README.md).

## Load or manage sample data

```powershell
exakit data-load            # guided menu: bundled sample data or a local CSV/Parquet file
exakit data-load -Force     # reload the bundled TPC-H sample directly
```

## Windows-specific notes

| Issue | Fix |
|---|---|
| "Docker is installed but not running" | Start Docker Desktop, wait for the whale icon to settle, re-run |
| "Port 8563 is already in use" | Stop the other application, or set `$env:EXAKIT_DB_PORT = "8564"` and re-run |
| Script execution policy complaints | The installer runs setup with `-ExecutionPolicy Bypass` scoped to that one script; nothing system-wide is changed |
| Corporate proxy | Set `$env:HTTPS_PROXY` before running |
| Laptop reboot | The container has a restart policy of none by default: `exakit start` (or `docker start exasol-nano`) brings it back with all data intact |
| exapump has no Windows ARM64 build | Only x86_64 Windows is supported for exapump today; the database container itself works on both |

Remove everything: `exakit uninstall`, or manually with `docker rm -f exasol-nano; docker volume rm exasol-nano-data`, then delete `~\.exasol-starter-kit`.
