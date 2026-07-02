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
4. The installer waits until the database reports ready (a few minutes)
5. You get the connection panel: DSN `127.0.0.1:8563`, admin user, dedicated MCP user, and password file locations

Want to look before it runs? `$env:EXAKIT_DRY_RUN = "1"` first — it downloads and plans, installs nothing.

## Verify

```powershell
docker ps --filter name=exasol-nano        # container up?
docker logs exasol-nano | Select-String "up and running"
```

Any SQL client (DBeaver etc.) connects with: host `127.0.0.1`, port `8563`, admin user `sys`, password from `~\.exasol-starter-kit\credentials\nano_sys_password`, certificate validation off (local self-signed).

## Connect your AI assistant

On the native Windows path, point your MCP client at the database with this server definition (Claude Desktop: **Settings → Developer → Edit Config**; config file: `%APPDATA%\Claude\claude_desktop_config.json`). Install [uv](https://docs.astral.sh/uv/getting-started/installation/) on Windows first, then:

```json
{
  "mcpServers": {
    "exasol": {
      "command": "uvx",
      "args": ["exasol-mcp-server@1.10.1"],
      "env": {
        "EXA_DSN": "127.0.0.1:8563",
        "EXA_USER": "mcp_readonly",
        "EXA_PASSWORD": "<contents of ~\\.exasol-starter-kit\\credentials\\mcp_readonly_password>"
      }
    }
  }
}
```

Restart Claude Desktop, then continue with the [first workflow](../demo/first-revenue-analysis.md).

## Windows-specific notes

| Issue | Fix |
|---|---|
| "Docker is installed but not running" | Start Docker Desktop, wait for the whale icon to settle, re-run |
| "Port 8563 is already in use" | Stop the other application, or set `$env:EXAKIT_DB_PORT = "8564"` and re-run |
| Script execution policy complaints | The installer runs setup with `-ExecutionPolicy Bypass` scoped to that one script; nothing system-wide is changed |
| Corporate proxy | Set `$env:HTTPS_PROXY` before running |
| Laptop reboot | The container has a restart policy of none by default: `docker start exasol-nano` brings it back with all data intact |

Remove everything: `docker rm -f exasol-nano; docker volume rm exasol-nano-data`, then delete `~\.exasol-starter-kit`.
