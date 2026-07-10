# Quickstart — Windows with WSL

Gets you from Windows to a local Exasol database with an AI assistant connected, using **WSL (Windows Subsystem for Linux)**. Inside WSL the kit runs **Exasol Nano** as a container. Prefer staying in PowerShell? Use the [Windows Docker quickstart](windows-docker.md) instead.

## What you need

- Windows 10/11 with **WSL 2** and a Linux distro (Ubuntu is fine):
  ```powershell
  wsl --install        # from an admin PowerShell, if you don't have WSL yet
  ```
- **Docker available inside WSL** — easiest via Docker Desktop with WSL integration turned on (Docker Desktop → Settings → Resources → WSL integration → enable your distro). Podman inside the distro works too.
- 4 GB+ RAM, ~10 GB free disk

Check from a WSL terminal (installs nothing):

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

Every ✗ line tells you what to fix — the usual one is Docker Desktop not running or WSL integration not enabled.

## Install (inside the WSL terminal)

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | sh
```

What happens, in order:

1. WSL is detected; the Nano container route is chosen and the plan shown
2. The pinned `exasol/nano` image is pulled (with retries)
3. The container starts with a persistent volume and a generated password; the SQL port is bound to `127.0.0.1:8563` only
4. The installer waits until the database reports ready (usually under 2 minutes)
5. exapump is installed with a ready connection profile; the MCP server is set up, a dedicated `mcp_readonly` database user is created and validated, and the selected AI client configs are backed up and updated
6. You get the connection panel

## Verify

```bash
exakit status
exapump sql -p starter-kit 'SELECT CURRENT_TIMESTAMP'
```

## Load Data

Open the guided data loading menu any time:

```bash
exakit data-load
```

Use `exakit data-load --force` when you only want to reload the bundled sample dataset directly.

## Connect your AI assistant

Run `exakit mcp-setup` — a checkbox menu of the supported clients (Claude, Codex, Cursor, Gemini CLI, GitHub Copilot, OpenCode, Continue). The setup backs up each selected client's config file before updating it.

Because WSL 2 forwards localhost, **Windows apps can reach the database at `127.0.0.1:8563` directly**. If you configure a Windows desktop app from inside WSL, make sure the selected client config uses a launcher command Windows can run. The two practical options are:

- Install `uv` on Windows too and replace `command` with the output of `(Get-Command uvx).Source`
- Keep the same environment block and wrap the launch as `wsl uvx exasol-mcp-server@<version>`

**Using Claude Code or Codex CLI inside WSL?** Run `exakit skills-install`, then say **"setup starter kit"** in a fresh session — the kit's AI skill drives setup and the first query for you. See [`skills/README.md`](../skills/README.md).

Then continue with the [first workflow](../demo/first-revenue-analysis.md).

## WSL-specific notes

| Issue | Fix |
|---|---|
| "No container runtime found" inside WSL | Start Docker Desktop on Windows and enable WSL integration for your distro, then re-run |
| Docker works in PowerShell but not in WSL | Same fix — WSL integration is per-distro (Settings → Resources → WSL integration) |
| Port 8563 busy on the Windows side | Something on Windows holds it; stop it or re-run with `EXAKIT_DB_PORT=8564` |
| Database state after `wsl --shutdown` | Safe — data lives in the named Docker volume; `exakit start` brings it back |
| WSL clock drift after laptop sleep | If TLS/downloads act strange: `sudo hwclock -s` |

Remove everything: `exakit uninstall` inside WSL (removes the database, kit home, and CLI binaries).
