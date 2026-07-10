# Quickstart — macOS

Gets you from a bare Mac to a local Exasol database with an AI assistant connected. On macOS the kit installs **Exasol Personal** as a native local deployment — no Docker needed.

## What you need

- macOS on Apple Silicon or Intel
- 8 GB+ RAM, ~20 GB free disk
- usually under 2 minutes end to end (unattended)

Check before you start (installs nothing):

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

If `python3` is missing, that's fine: the installer can bootstrap its own managed Python runtime automatically.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | sh
```

What happens, in order:

1. Your Mac is detected (OS, chip, memory) and the plan is shown
2. The Exasol launcher is downloaded (pinned version, checksum-verified) into `~/.local/bin`
3. `exasol install local` deploys the database — **usually under 2 minutes**; output streams so you can watch it work
4. exapump (data loading CLI) is installed and a connection profile is created for you
5. The MCP server (AI agent bridge) is set up, a dedicated `mcp_readonly` database user is created and validated, and the selected AI client configs are backed up and updated
6. You get a connection panel: DSN, admin user, MCP user, where the passwords are stored, config paths

Safe to interrupt and re-run at any point — completed steps are skipped.

## Verify

```bash
exakit status
exapump sql -p starter-kit 'SELECT CURRENT_TIMESTAMP'
```

A timestamp back means the full chain works.

## Load Data

The installer offers a guided data loading menu after exapump is ready. Open it again any time:

```bash
exakit data-load
```

Use `exakit data-load --force` when you only want to reload the bundled sample dataset directly.

## Connect your AI assistant

Run `exakit mcp-setup` to permanently configure Claude, Cursor, or Codex. The setup backs up the selected client config files before updating them.

For Claude: after setup, restart the app and look for an MCP server named `exasol`.

**Using Claude Code or Codex CLI?** Run `exakit skills-install`, then say **"setup starter kit"** in a fresh session — the kit's AI skill drives setup and the first query for you. See [`skills/README.md`](../skills/README.md).

Then continue with the [first workflow](../demo/first-revenue-analysis.md).

## macOS-specific notes

| Issue | Fix |
|---|---|
| "This machine does not meet the requirements" | Exasol Personal needs 8 GB RAM — the installer stops rather than half-installing |
| `python3` triggers a developer-tools popup | Accept it (installs Command Line Tools), then re-run |
| `~/.local/bin` not on PATH warning | Add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` |
| Company-managed Mac blocks virtualization | Exasol Personal runs a local VM; if MDM policy blocks it, use a machine you control |
| Where did everything go? | Binaries: `~/.local/bin` · state/logs/credentials: `~/.exasol-starter-kit` · database: `~/.exasol/personal` |

Remove everything: `exakit uninstall` (removes the database, kit home, and CLI binaries).
