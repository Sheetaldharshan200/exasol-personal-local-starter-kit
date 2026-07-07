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
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | sh
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
| 🤖 | **MCP server** | Lets Claude Desktop, Cursor, or other supported MCP clients query your database with a dedicated read-only login |
| 🐍 | **pyexasol** | The official Exasol Python driver, ready in its own environment — script against your database from Python |

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

The installer detects your OS and hardware, shows you the plan, then does the rest — database, exapump, MCP server, and pyexasol, the same on native Windows PowerShell as on macOS/Linux/WSL. *(One exception: Windows-on-ARM gets the database container only — exapump ships x86_64 Windows builds; see the [Windows quickstart](quickstarts/windows-docker.md).)* On macOS the first database deployment takes 10–20 minutes. Container platforms are usually ready in a few minutes.

> **Prefer to read before you run?** Add `EXAKIT_DRY_RUN=1` before `sh` — the kit downloads to `~/.exasol-starter-kit/kit` and nothing installs until you run the setup yourself.

### Connect your AI assistant

Run:

```bash
exakit mcp-setup
```

The setup backs up and edits the selected supported client config files for Claude Desktop, Cursor, or Codex. The flow supports multi-select, validates the MCP connection, prints where the MCP config lives, and gives you a first prompt to use with the assistant.

When the kit can detect the local MCP launcher path, it writes that exact path into the client configs instead of assuming `uvx` is on every desktop app's PATH. That keeps the same setup working more reliably across macOS, Linux, and Windows clients.

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

So you're not staring at an empty database, the kit ships with a small sample dataset in [`data/`](data/) — standard **TPC-H** (a wholesale/retail model: customers, orders, line items, parts, suppliers) at ~21 MB. `setup/load-data.sh` loads it into the `STARTER_KIT` schema.

- **[data/README.md](data/README.md)** — what's included and how to regenerate it at a different size
- **[data/data-dictionary.md](data/data-dictionary.md)** — every table and column, with types, keys, and the revenue formula

Prefer your own data? Run `exakit data-load` — a focused guided menu that loads the bundled sample or a **local CSV, text, or Parquet file**. One-liner alternative: `exapump upload yourfile.csv --table STARTER_KIT.MYTABLE -p starter-kit`.

### Day-to-day

```bash
exakit status
exakit info
exakit stop
exakit start
exakit data-load
exakit skills-install
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
- **Local TLS handled for MCP clients** — generated Claude, Cursor, and Codex configs set `EXA_SSL_CERT_VALIDATION=no` only for the local self-signed `127.0.0.1` runtime; use trusted CA validation for real remote databases.
- **No preinstalled Python required** — the setup uses `python3` when present, otherwise it bootstraps a managed runtime through `uv`.
- **Repo stays pure source** — runtime state, logs, credentials, backups, and generated configs live under `~/.exasol-starter-kit/`.
- **Everything is inspectable** — install scripts, MCP configs, backups, and logs remain available on disk.
- **Version-aware updates** — installs resolve the latest component versions by default on Unix and Windows, record what was installed, and expose `exakit update-check` plus targeted updates such as `exakit update mcp`, `exakit update exapump`, `exakit update runtime`, and `exakit update all`. Exasol Personal major-version changes use an explicit safe path: `exakit update personal --plan`, `exakit update personal --backup`, then `exakit update personal --apply`. Nano runtime updates keep the data volume, create pre-update runtime snapshot metadata, and try to restore the previous container image if the new one fails to start.
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
| Do I need Rust / Python / Homebrew / git? | **No.** The installer brings everything it needs |
| Does it cost anything? | No — Exasol Personal is free for personal use |
| What sample data is included? | A ~21 MB TPC-H dataset in [`data/`](data/) — see the [data dictionary](data/data-dictionary.md) |
| "Docker is installed but not running"? | Start Docker Desktop, run the install command again |
| Docker Desktop runs on Windows but WSL can't see it? | Docker Desktop → Settings → Resources → **WSL integration** → enable your distro, Apply & restart (the installer detects and says this too) |
| `exakit` not recognized after a Windows install? | Re-run the install command — it now adds `~\.local\bin` to your user PATH and repairs the command automatically |
| Port 8563 already taken? | `EXAKIT_DB_PORT=8564` before the install command *(Linux/Windows container path)* |
| Behind a corporate proxy? | `export HTTPS_PROXY=...` and re-run |
| Where's the deep-dive for my OS? | [macOS](quickstarts/macos.md) · [Windows + WSL](quickstarts/windows-wsl.md) · [Windows + Docker](quickstarts/windows-docker.md) |
| Step-by-step to the first AI query? | [QUICKSTART](QUICKSTART.md) → [First workflow](demo/first-revenue-analysis.md) |
| How do I remove everything? | `exakit teardown --data`, then `rm -rf ~/.exasol-starter-kit` |

---

<div align="center">

**Start locally. Connect AI safely. Inspect the SQL. Validate the output. Rerun the workflow.**

*Questions or issues → open an issue in this repository.*

<sub>Part of the [Exasol](https://www.exasol.com) ecosystem · [Exasol Personal](https://github.com/exasol/exasol-personal) · [exapump](https://github.com/exasol-labs/exapump) · [MCP server](https://github.com/exasol/mcp-server) · [pyexasol](https://github.com/exasol/pyexasol)</sub>

</div>
