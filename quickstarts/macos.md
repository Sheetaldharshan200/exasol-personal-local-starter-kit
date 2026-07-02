# Quickstart — macOS

Gets you from a bare Mac to a local Exasol database with an AI assistant connected. On macOS the kit installs **Exasol Personal** as a native local deployment — no Docker needed.

## What you need

- macOS on Apple Silicon or Intel
- 8 GB+ RAM, ~20 GB free disk
- 15–25 minutes (the first database deployment takes 10–20 of them, unattended)

Check before you start (installs nothing):

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

If `python3` shows ✗, run `xcode-select --install` first (one-time, standard on any dev Mac).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | sh
```

What happens, in order:

1. Your Mac is detected (OS, chip, memory) and the plan is shown
2. The Exasol launcher is downloaded (pinned version, checksum-verified) into `~/.local/bin`
3. `exasol install local` deploys the database — **this is the 10–20 minute step**; output streams so you can watch it work
4. exapump (data loading CLI) is installed and a connection profile is created for you
5. The MCP server (AI agent bridge) is set up and validated
6. You get a connection panel: DSN, user, where the password is stored, config paths

Safe to interrupt and re-run at any point — completed steps are skipped.

## Verify

```bash
exakit status
exapump sql -p starter-kit 'SELECT CURRENT_TIMESTAMP'
```

A timestamp back means the full chain works.

## Connect your AI assistant

Your ready-made config is at `~/.exasol-starter-kit/mcp/claude-config.json` (Cursor and generic variants sit next to it).

For Claude Desktop: **Settings → Developer → Edit Config**, merge the file's contents into `claude_desktop_config.json` (on macOS that file lives at `~/Library/Application Support/Claude/claude_desktop_config.json`), restart the app.

Then continue with the [first workflow](../demo/first-revenue-analysis.md).

## macOS-specific notes

| Issue | Fix |
|---|---|
| "This machine does not meet the requirements" | Exasol Personal needs 8 GB RAM — the installer stops rather than half-installing |
| `python3` triggers a developer-tools popup | Accept it (installs Command Line Tools), then re-run |
| `~/.local/bin` not on PATH warning | Add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` |
| Company-managed Mac blocks virtualization | Exasol Personal runs a local VM; if MDM policy blocks it, use a machine you control |
| Where did everything go? | Binaries: `~/.local/bin` · state/logs/credentials: `~/.exasol-starter-kit` · database: `~/.exasol/personal` |

Remove everything: `exakit teardown --data`, then `rm -rf ~/.exasol-starter-kit`.
