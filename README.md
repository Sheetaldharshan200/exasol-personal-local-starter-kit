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
[![Quickstart](https://img.shields.io/badge/first%20AI%20query-under%202%20min-orange)](QUICKSTART.md)

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | sh
```

**Prefer to let your AI do it?** Paste this into Claude Code, Codex, or any coding agent:

```text
Install this and set it up completely so my AI tools can query the local
database, then verify it works: https://github.com/ranjanm-chn/exasol-personal-local-starter-kit
```

</div>

---

## What is this?

You already use AI. The hard part is trusting it with your data. This kit gives you a complete, private AI-ready analytics setup that runs **entirely on your machine** — so you can let an AI assistant query real data, **see every SQL statement before it runs**, verify every answer yourself, and rerun the whole thing tomorrow.

**One command installs four things and connects them:**

| | Component | What it does for you |
|---|---|---|
| 🗄️ | **Exasol database** | A full in-memory analytics database, running locally |
| ⚡ | **exapump** | Load CSV/Parquet files and run SQL from your terminal |
| 🤖 | **MCP server** | Lets Claude, Cursor, or other supported MCP clients query your database with a dedicated read-only login |
| 🐍 | **pyexasol** | The official Exasol Python driver, ready in its own environment — script against your database from Python |

At the end you get your connection details on screen, a managed runtime state under `~/.exasol-starter-kit/`, and guided MCP setup for supported clients. Time to first AI-assisted query: **under 2 minutes**.

---

## 🚀 Local Agent-Ready Starter

*The default first experience: install, connect an AI assistant, ask your first question.*

### Will it run on my machine?

| Your machine | You need | That's all |
|---|---|---|
| 🍎 **macOS** | 8 GB+ RAM, ~20 GB disk | The database runs natively |
| 🐧 **Linux / WSL** | Docker *or* Podman (running), 4 GB+ RAM | Container runtime required |
| 🪟 **Windows** | Docker Desktop (running), 4 GB+ RAM | Native Windows uses the PowerShell installer |

Not sure? This checks everything and installs **nothing**:

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

Every ✗ tells you exactly what to fix.

### Install

**macOS / Linux / WSL**
```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | sh
```

**Windows (PowerShell)**
```powershell
irm https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.ps1 | iex
```

The installer detects your OS and hardware, shows you the plan, then does the rest — database, exapump, MCP server, and pyexasol. It works the same on native Windows PowerShell as on macOS/Linux/WSL, and on every platform the database is usually up in **under 2 minutes**. *(One exception: Windows-on-ARM gets the database container only — exapump ships x86_64 Windows builds; see the [Windows quickstart](quickstarts/windows-docker.md).)*

> **Prefer to read before you run?** Add `EXAKIT_DRY_RUN=1` before `sh` — the kit downloads to `~/.exasol-starter-kit/kit` and nothing installs until you run the setup yourself.

> **Installing unattended (agent-driven or scripted)?** With no terminal to prompt, the install takes safe defaults: it loads **every bundled dataset** and connects **every AI client found on the machine that isn't connected yet** over MCP. To answer its choices up front, set these before `sh` (macOS/Linux/WSL) — use **names, not menu numbers** (numbers change between releases):
>
> | Variable | What it controls |
> |---|---|
> | `EXAKIT_MCP_CLIENTS=claude,cursor` | Which MCP clients to configure: `claude` (= desktop app + Claude Code CLI), `claude_desktop`, `claude_code`, `codex`, `cursor`, `copilot`, `gemini`, `opencode`, `continue`, `all`, `skip` |
> | `EXAKIT_SKIP_MCP=1` | Skip MCP setup entirely |
> | `EXAKIT_DATASETS=tpch,weather` | Which bundled datasets to load, by id (wins over `EXAKIT_LOAD_SAMPLE`) |
> | `EXAKIT_LOAD_SAMPLE=0\|1` | Skip / load the bundled sample |
> | `EXAKIT_REUSE_DB=0\|1` | Fresh deploy / reuse a running database (macOS) |
>
> Example: `curl -fsSL …/install.sh | EXAKIT_MCP_CLIENTS=claude EXAKIT_DATASETS=tpch sh`.

### 🤖 For AI agents

Asked to install this repo? **Read [AGENTS.md](AGENTS.md)** — the agent runbook. The short version: the install command above runs **fully unattended** (no TTY → safe defaults, never hangs); answer its choices with the env vars in the blockquote above (**names, not numbers**); the macOS database deploy usually finishes in under 2 minutes — run it in the background and poll `exakit status` (a timed-out shell call is not a failure; re-running the installer resumes).

### Connect your AI assistant

Run:

```bash
exakit mcp-setup
```

A checkbox menu (↑/↓ to move, **Space** to select, **Enter** to continue) lets you pick from the supported clients — **Claude**, **Codex**, **Cursor**, **Gemini CLI**, **GitHub Copilot (VS Code)**, **OpenCode**, **Continue** — or **Skip for now** (Skip touches nothing). The setup backs up each selected client's config file before editing it, validates the MCP connection, prints where each config lives, and hands you a first prompt to try — copied to your clipboard when a clipboard tool is available.

Good to know:

- **The menu is dynamic** — clients already connected, or not installed on this machine, are simply not offered. When everything found is already connected, the command says so and exits.
- **Selecting Claude configures both Claude surfaces at once**: the desktop app (`claude_desktop_config.json`) and the Claude Code CLI (`~/.claude.json`, user scope — available in every project). If one is already connected, only the remaining one is offered.
- **Configs are written with the resolved launcher path** — the kit writes the exact local MCP launcher path instead of assuming `uvx` is on every desktop app's PATH, so the same setup works reliably across macOS, Linux, and Windows clients.
- The installer runs this step for you; `exakit mcp-setup` re-runs it any time.

### Let an AI assistant drive the kit (the skill)

The kit ships an **AI skill** — a `SKILL.md` recipe that teaches an agent (Claude Code, Codex, Cursor, or any tool that reads the open skill standard) to run this whole flow for you: check status, connect MCP, load data, and hold the inspect-before-run query loop. The installer offers to install it; you can also (re)install any time:

```bash
exakit skills-install
```

This copies the skill into each agent's discovery folder (`~/.claude/skills/`, `~/.agents/skills/`). Then, in a **fresh** agent session, just say **"setup starter kit"** and it takes over. See [`skills/README.md`](skills/README.md) for how it works, and [`skills/reducing-agent-prompts.md`](skills/reducing-agent-prompts.md) if the agent asks for approval too often.

### The workflow this kit teaches

```text
ASK -> INSPECT -> RUN -> VALIDATE -> RERUN
```

Ask your assistant: *"Which product category generated the most revenue? Show me the SQL before you run it."* Then check the result yourself with `exapump`. That is the point of the kit: AI speed, **your** verification.

### Sample data included

So you're not staring at an empty database, the kit ships **three bundled datasets**, each in its **own schema** so your AI client sees them grouped and self-describing:

| Dataset | What it is | Schema |
|---|---|---|
| **TPC-H retail** | Standard wholesale/retail benchmark — customers, orders, line items, parts, suppliers (~175k rows) | `TPCH` |
| **Energy** | Smart-meter energy readings, time series (~108k rows) — [data/datasets/energy](data/datasets/energy) | `ENERGY` |
| **Weather** | Daily city weather history (~11k rows) — [data/datasets/weather](data/datasets/weather) | `WEATHER` |

The read-only MCP user has database-wide read (`USE ANY SCHEMA` + `SELECT ANY TABLE`), so it can query every schema and table — bundled, uploaded, or created later — with no per-schema grant, while remaining unable to write.

**Loading data** — `exakit data-load` opens the same checkbox menu as the installer (↑/↓, Space, Enter):

- It lists every bundled dataset **not loaded yet** (checked against the actual database, not just a flag), plus a **local CSV or Parquet file**, plus Cancel. Once all bundled datasets are in, only the local-file and Cancel options remain.
- `exakit data-load --force` reloads the TPC-H sample directly.
- A local file prompts for its target `SCHEMA.TABLE` (default `STARTER_KIT`) and the kit creates the schema if needed. One-liner alternative: `exapump upload yourfile.csv --table STARTER_KIT.MYTABLE -p starter-kit`.

Dig into the data itself:

- **[data/README.md](data/README.md)** — what's included and how to regenerate it at a different size
- **[data/data-dictionary.md](data/data-dictionary.md)** — every table and column, with types, keys, and the revenue formula
- **[data/example-questions.md](data/example-questions.md)** — 14 ready-to-ask questions (revenue, customers, orders, suppliers), each with validated reference SQL to inspect before you run

### Day-to-day

```bash
exakit status          # is everything running?
exakit info            # connection details panel
exakit start           # start the database
exakit stop            # stop it (data persists)
exakit data-load       # load bundled datasets or your own file
exakit mcp-setup       # connect AI clients over MCP
exakit mcp-status      # which clients are connected
exakit mcp-doctor      # MCP health check
exakit guide           # query without an AI client (SQL clients, pyexasol)
exakit update-check    # component updates available?
exakit skills-install  # (re)install the AI agent skill
exakit help            # every command (also: exakit catalog)
```

Every command above is verified against the CLI — anything else `exakit` can do is listed by `exakit help`.

Something failed mid-install? Re-run the install command. Finished steps are skipped, and failed steps are retried.

---

## Safety and operations

- **Dedicated read-only MCP login** — the kit provisions and validates a database user with database-wide read (`USE ANY SCHEMA` + `SELECT ANY TABLE`) but no write privilege, and asserts that read-only posture before managed MCP flows proceed.
- **Local TLS handled for MCP clients** — the generated MCP client configs set `EXA_SSL_CERT_VALIDATION=no` only for the local self-signed `127.0.0.1` runtime; use trusted CA validation for real remote databases.
- **No preinstalled Python required** — the setup uses `python3` when present, otherwise it bootstraps a managed runtime through `uv`.
- **Repo stays pure source** — runtime state, logs, credentials, backups, and generated configs live under `~/.exasol-starter-kit/`.
- **Everything is inspectable** — install scripts, MCP configs, backups, and logs remain available on disk.
- **Version-aware updates** — installs resolve the latest component versions by default, record what was installed, and expose `exakit update-check` plus targeted updates: `exakit update mcp`, `exakit update exapump`, `exakit update runtime`, `exakit update all`.
  - Exasol Personal major-version changes use an explicit safe path: `exakit update personal --plan` → `--backup` → `--apply`.
  - Nano runtime updates keep the data volume, snapshot pre-update runtime metadata, and try to restore the previous container image if the new one fails to start.
- **Reversible lifecycle** — `exakit` manages the kit end to end: `status`, `start`/`stop`, `data-load`, MCP setup and maintenance (`mcp-setup`, `mcp-status`, `mcp-validate`, `mcp-doctor`, `mcp-repair`, `mcp-remove`, `mcp-restore`), `logs`, and a guarded `uninstall`. Run `exakit help` (or `exakit catalog`) to see every command.

## Repository layout

- `install.sh` and `install.ps1`: one-command entrypoints for Unix-like systems and Windows.
- `setup/`: setup orchestration, shared libraries, and the `exakit` helper.
- `mcp/`: MCP runtime export, client setup, validation, diagnostics, and tests.
- `quickstarts/` and `demo/`: user-facing onboarding and first workflow guidance.
- `sql/`, `data/`, and `upgrade/`: schema/bootstrap assets, sample data hooks, and upgrade scripts.
- `tests/`: shell smoke checks and dry-run coverage.

## Quick answers

| Question | Answer |
|---|---|
| Do I need Rust / Python / Homebrew / git? | **No.** The installer brings everything it needs |
| Does it cost anything? | No — Exasol Personal is free for personal use |
| What sample data is included? | Three bundled datasets — TPC-H retail (~21 MB), smart-meter energy, and daily weather — each in its own schema (`TPCH`, `ENERGY`, `WEATHER`); see the [data dictionary](data/data-dictionary.md) |
| "Docker is installed but not running"? | Start Docker Desktop, run the install command again |
| Docker Desktop runs on Windows but WSL can't see it? | Docker Desktop → Settings → Resources → **WSL integration** → enable your distro, Apply & restart (the installer detects and says this too) |
| `exakit` not recognized after a Windows install? | Re-run the install command — it now adds `~\.local\bin` to your user PATH and repairs the command automatically |
| Port 8563 already taken? | `EXAKIT_DB_PORT=8564` before the install command *(Linux/Windows container path)* |
| Behind a corporate proxy? | `export HTTPS_PROXY=...` and re-run |
| Where's the deep-dive for my OS? | [macOS](quickstarts/macos.md) · [Windows + WSL](quickstarts/windows-wsl.md) · [Windows + Docker](quickstarts/windows-docker.md) |
| Step-by-step to the first AI query? | [QUICKSTART](QUICKSTART.md) → [First workflow](demo/first-revenue-analysis.md) |
| How do I remove everything? | `exakit uninstall` (removes the database, kit home, and CLI binaries) |

---

<div align="center">

**Start locally. Connect AI safely. Inspect the SQL. Validate the output. Rerun the workflow.**

*Questions or issues → open an issue in this repository.*

<sub>Part of the [Exasol](https://www.exasol.com) ecosystem · [Exasol Personal](https://github.com/exasol/exasol-personal) · [exapump](https://github.com/exasol-labs/exapump) · [MCP server](https://github.com/exasol/mcp-server) · [pyexasol](https://github.com/exasol/pyexasol)</sub>

</div>
