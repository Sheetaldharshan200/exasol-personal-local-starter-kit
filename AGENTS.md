# Agent guide — Exasol Personal Local Starter Kit

This repo installs a complete local analytics stack with one command: an Exasol
database running on the user's machine, the `exapump` data/SQL CLI, an MCP
server with a dedicated read-only database user, and the `pyexasol` Python
driver. If a user asks you to "install this repo", this file is your runbook.

## Install (one command)

macOS / Linux / WSL:

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.ps1 | iex
```

The installer is **fully unattended-safe**: with no TTY attached (the normal
case for an agent shell) every question silently takes a safe default — all
bundled datasets are loaded and every AI client that is installed on the
machine but not yet connected gets an MCP config. Nothing ever hangs waiting
for input.

## Answer the install's choices via environment variables

Flags don't travel through a pipe, so choices are env vars. **Always use
client/dataset names, never menu numbers** — numbers are display order and
change between releases; names are stable.

| Variable | Effect |
|---|---|
| `EXAKIT_MCP_CLIENTS=claude,cursor` | Which MCP clients to configure, by name: `claude` (= desktop app **and** Claude Code CLI), `claude_desktop`, `claude_code`, `codex`, `cursor`, `vscode_copilot` (also `copilot`), `gemini_cli` (also `gemini`), `all`, `skip` |
| `EXAKIT_SKIP_MCP=1` | Skip MCP client setup entirely (run `exakit mcp-setup` later) |
| `EXAKIT_DATASETS=tpch,weather` | Which bundled datasets to load, by id (`data/datasets/<id>/`); takes precedence over `EXAKIT_LOAD_SAMPLE` |
| `EXAKIT_LOAD_SAMPLE=0\|1` | `0` skip data loading, `1` load the bundled sample (tpch) |
| `EXAKIT_REUSE_DB=0\|1` | macOS: reuse an already-running database (`1`) or deploy fresh (`0`) |
| `EXAKIT_PREFLIGHT=1` | Check machine requirements only — installs nothing |
| `EXAKIT_DRY_RUN=1` | Download the kit for inspection — installs nothing |
| `EXAKIT_DB_PORT=8564` | Alternate DB port (Linux/Windows container path only) |

Example:

```bash
curl -fsSL .../install.sh | EXAKIT_MCP_CLIENTS=claude EXAKIT_DATASETS=tpch sh
```

## Timing — read this before you run it

- **macOS first install deploys a native Exasol database — usually a few
  minutes** (the first run can take longer while it downloads the runtime on a
  slow connection). Container platforms (Linux/WSL/Windows) are similar.
- Your shell tool will likely **time out before the macOS deploy finishes**.
  That is not a failure. Run the install in the background (or with a raised
  timeout), then poll:

```bash
exakit status        # until it reports running
```

- **Re-running the installer is always safe and resumes**: completed steps are
  skipped, failed steps retry. When in doubt, re-run rather than diagnose.

## Verify the install

```bash
exakit status                                     # runtime: running
exakit info                                       # connection panel
exapump sql -p starter-kit 'SELECT CURRENT_TIMESTAMP'   # end-to-end proof
```

A returned timestamp = the database works. MCP health: `exakit mcp-doctor`.

## Where things live

- State, credentials, logs: `~/.exasol-starter-kit/` (logs under `logs/`;
  every error message names its remedy — check there before improvising)
- Kit source copy (read any script): `~/.exasol-starter-kit/kit/`
- CLI binaries: `~/.local/bin/` (`exakit`, `exapump`, `exasol` on macOS)

## After the install

Install the agent skill so future sessions can drive the full
ask → inspect-SQL → run → validate loop:

```bash
exakit skills-install
```

Then see `skills/local-agent-ready-starter/SKILL.md` for the query-loop
discipline (read-only MCP user, show SQL before running it).

## Uninstall

```bash
exakit uninstall --yes    # database + data, MCP configs, skills, binaries
```
