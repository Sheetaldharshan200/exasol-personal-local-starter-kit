<div align="center">

<picture>
  <source srcset="static/Exasol_Logo_2025_Bright.svg" media="(prefers-color-scheme: dark)">
  <img src="static/Exasol_Logo_2025_Dark.svg" alt="Exasol Logo" width="300">
</picture>

# Personal Local Starter Kit

### Your own analytics database. Your own machine. Your AI assistant connected to it.

**One command. No cloud account. No license key. No admin rights.**

[![Documentation](https://img.shields.io/badge/docs-exasol.com-blue)](https://docs.exasol.com/db/latest/home.htm)
[![Community](https://img.shields.io/badge/community-exasol-green)](https://community.exasol.com)
[![Quickstart](https://img.shields.io/badge/first%20AI%20query-~15%20minutes-orange)](QUICKSTART.md)

```bash
curl -fsSL https://raw.githubusercontent.com/Sheetaldharshan200/exasol-personal-local-starter-kit/main/install.sh | sh
```

</div>

---

## What is this?

You already use AI. The hard part is trusting it with your data. This kit gives you a complete, private AI-ready analytics setup that runs **entirely on your machine** — so you can let an AI assistant query real data, **see every SQL statement before it runs**, verify every answer yourself, and rerun the whole thing tomorrow.

**One command installs three things and connects them:**

| | Component | What it does for you |
|---|---|---|
| 🗄️ | **Exasol database** | A full in-memory analytics database, running locally |
| ⚡ | **exapump** | Load CSV/Parquet files and run SQL from your terminal |
| 🤖 | **MCP server** | Lets Claude Desktop, Cursor, or other supported MCP clients query your database with a dedicated read-only login |

At the end you get your connection details on screen, a managed runtime state under `~/.exasol-starter-kit/`, and guided MCP setup for supported clients. Time to first AI-assisted query: **about 15 minutes**.

---

## 🚀 Kit 1 — Local Agent-Ready Starter

*The default first experience: install, connect an AI assistant, ask your first question.*

### Will it run on my machine?

| Your machine | You need | That's all |
|---|---|---|
| 🍎 **macOS** | 8 GB+ RAM, ~20 GB disk | The database runs natively |
| 🐧 **Linux / WSL** | Docker *or* Podman (running), 4 GB+ RAM | Container runtime required |
| 🪟 **Windows** | Docker Desktop (running), 4 GB+ RAM | Native Windows uses the PowerShell installer |

Not sure? This checks everything and installs **nothing**:

```bash
curl -fsSL https://raw.githubusercontent.com/Sheetaldharshan200/exasol-personal-local-starter-kit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

Every ✗ tells you exactly what to fix.

### Install

**macOS / Linux / WSL**
```bash
curl -fsSL https://raw.githubusercontent.com/Sheetaldharshan200/exasol-personal-local-starter-kit/main/install.sh | sh
```

**Windows (PowerShell)**
```powershell
irm https://raw.githubusercontent.com/Sheetaldharshan200/exasol-personal-local-starter-kit/main/install.ps1 | iex
```

The installer detects your OS and hardware, shows you the plan, then does the rest. On macOS the first database deployment takes 10–20 minutes. Container platforms are usually ready in a few minutes.

> **Native Windows note:** the PowerShell path currently sets up the database container first; for exapump and MCP setup, follow the [Windows quickstart](quickstarts/windows-docker.md) or use WSL for the full flow.

> **Prefer to read before you run?** Add `EXAKIT_DRY_RUN=1` before `sh` — the kit downloads to `~/.exasol-starter-kit/kit` and nothing installs until you run the setup yourself.

### Connect your AI assistant

Run:

```bash
exakit mcp-setup
```

Choose `temporary` to generate ready-made config files in `~/.exasol-starter-kit/mcp/`, or `permanent` to write directly into the supported client config files for Claude Desktop, Cursor, or Codex. The flow supports multi-select, validates the MCP connection, and ends by telling the user to restart the selected client.

### The workflow this kit teaches

```text
ASK -> INSPECT -> RUN -> VALIDATE -> RERUN
```

Ask your assistant: *"Which product category generated the most revenue? Show me the SQL before you run it."* Then check the result yourself with `exapump`. That is the point of the kit: AI speed, **your** verification.

### Day-to-day

```bash
exakit status
exakit info
exakit stop
exakit start
exakit mcp-status
exakit mcp-validate
```

Something failed mid-install? Re-run the install command. Finished steps are skipped, and failed steps are retried.

---

## 🔐 Kit 2 — Trusted AI Workflow Add-on

*When "it works" needs to become "it's governed": add the trust layer.*

Kit 2 builds **on top of** Kit 1 — nothing is reinstalled, your data stays put. One command adds:

- **Semantic model** — shared business definitions for the assistant
- **Audit / run log** — question, SQL, time, and status recorded
- **Saved workflows** — repeatable assets you can rerun and share

```bash
bash ~/.exasol-starter-kit/kit/upgrade/upgrade-kit2.sh
bash ~/.exasol-starter-kit/kit/upgrade/rollback-kit2.sh
```

---

## Safety and operations

- **Dedicated read-only MCP login** — the kit provisions and validates a least-privilege database user before managed MCP flows proceed.
- **No preinstalled Python required** — the setup uses `python3` when present, otherwise it bootstraps a managed runtime through `uv`.
- **Repo stays pure source** — runtime state, logs, credentials, backups, and generated configs live under `~/.exasol-starter-kit/`.
- **Everything is inspectable** — install scripts, MCP configs, backups, and logs remain available on disk.
- **Pinned versions** — component versions are pinned and can be overridden with environment variables when needed.
- **Reversible lifecycle** — `exakit` supports status, configure, validate, repair, backup/restore, remove, doctor, and teardown flows.

## Repository layout

- `install.sh` and `install.ps1`: one-command entrypoints for Unix-like systems and Windows.
- `setup/`: setup orchestration, shared libraries, and the `exakit` helper.
- `mcp/`: MCP runtime export, client setup, validation, diagnostics, and tests.
- `quickstarts/` and `demo/`: user-facing onboarding and first workflow guidance.
- `sql/`, `data/`, and `upgrade/`: schema/bootstrap assets, sample data hooks, and Kit 2 upgrade scripts.
- `tests/`: shell smoke checks and dry-run coverage.

## Quick answers

| Question | Answer |
|---|---|
| Do I need Python preinstalled? | No. The kit uses system `python3` if available, otherwise installs and uses a managed runtime through `uv`. |
| Do I need admin rights for `uv`? | No. It installs into the user's home directory. |
| Does it cost anything? | Exasol Personal is free for personal use. |
| What if Docker is installed but not running? | Start Docker Desktop or Podman, then rerun the install command. |
| What if port `8563` is already in use? | On Linux/Windows container paths, rerun with `EXAKIT_DB_PORT=8564`. macOS local deployment needs `8563`. |
| Where is the guided MCP flow? | Run `exakit mcp-setup`, then use `exakit mcp-status`, `exakit mcp-validate`, `exakit mcp-repair`, `exakit mcp-remove`, or `exakit mcp-restore` as needed. |
| Where's the OS-specific help? | [macOS](quickstarts/macos.md) · [Windows + WSL](quickstarts/windows-wsl.md) · [Windows + Docker](quickstarts/windows-docker.md) |
| How do I remove everything? | `exakit teardown --data`, then remove `~/.exasol-starter-kit` if you also want logs and managed state gone. |

---

<div align="center">

**Start locally. Connect AI safely. Inspect the SQL. Validate the output. Rerun the workflow.**

*Questions or issues → open an issue in this repository.*

<sub>Part of the [Exasol](https://www.exasol.com) ecosystem · [Exasol Personal](https://github.com/exasol/exasol-personal) · [exapump](https://github.com/exasol-labs/exapump) · [MCP server](https://github.com/exasol/mcp-server)</sub>

</div>
