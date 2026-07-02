<div align="center">

# Exasol Personal Local Starter Kit

### Your own analytics database. Your own machine. Your AI assistant connected to it.

**One command. No cloud account. No license key. No admin rights.**

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | sh
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
| 🤖 | **MCP server** | Lets Claude Desktop, Cursor, or any MCP client query your database — *read-only* |

At the end you get your connection details on screen and ready-made AI-client configs on disk. Time to first AI-assisted query: **about 15 minutes**.

---

## 🚀 Kit 1 — Local Agent-Ready Starter

*The default first experience: install, connect an AI assistant, ask your first question.*

### Will it run on my machine?

| Your machine | You need | That's all |
|---|---|---|
| 🍎 **macOS** | 8 GB+ RAM, ~20 GB disk | The database runs natively — nothing else to install |
| 🐧 **Linux / WSL** | Docker *or* Podman (running), 4 GB+ RAM | — |
| 🪟 **Windows** | Docker Desktop (running), 4 GB+ RAM | — |

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

The installer detects your OS and hardware, shows you the plan, then does the rest. On macOS the first database deployment takes 10–20 minutes (one-time, unattended) — grab a coffee. Containers are up in a few minutes.

> **Native Windows note:** the PowerShell path currently sets up the database container; for exapump and the AI-assistant connection follow the [Windows quickstart](quickstarts/windows-docker.md) — or run the install inside WSL to get everything in one go.

> **Prefer to read before you run?** We built this for you. Add `EXAKIT_DRY_RUN=1` before `sh` — the kit downloads to `~/.exasol-starter-kit/kit` where you can read every script, and nothing installs until you say so.

### Connect your AI assistant (2 minutes)

Your configs are generated and waiting in `~/.exasol-starter-kit/mcp/`:

- **Claude Desktop** → Settings → Developer → Edit Config → merge in `claude-config.json` → restart
- **Cursor** → add `cursor-config.json` to your MCP settings
- **Anything else** → `generic-config.json` has the server definition

### The workflow this kit teaches

```
   ASK  ──►  INSPECT  ──►  RUN  ──►  VALIDATE  ──►  RERUN
  a real     the SQL,    read-only   reproduce it   same answer,
 question   before it     access      yourself,     any day, any
            executes                 outside the AI    time
```

Ask your assistant: *"Which product category generated the most revenue? **Show me the SQL before you run it.**"* — then check its answer yourself with one terminal command. That's the whole idea: AI speed, **your** verification. The [first workflow guide](demo/first-revenue-analysis.md) walks you through it step by step.

### Day-to-day

```bash
exakit status      # is everything healthy?
exakit info        # my connection details
exakit stop        # pause the database (keeps your data)
exakit start       # bring it back
```

Something failed mid-install? **Just run the install command again** — finished steps are skipped, the failed one retries. Every error message tells you its fix.

---

## 🔐 Kit 2 — Trusted AI Workflow Add-on

*When "it works" needs to become "it's governed": add the trust layer.*

Kit 2 builds **on top of** Kit 1 — nothing is reinstalled, your data stays put. One command adds:

- **Semantic model** — "revenue" and "margin" get defined *once*, so the AI stops guessing your business logic
- **Audit / run log** — every question, its SQL, timestamp and status, recorded in the database
- **Saved workflows** — turn a good one-off analysis into an asset you rerun and share

```bash
bash ~/.exasol-starter-kit/kit/upgrade/upgrade-kit2.sh      # upgrade  (additive, minutes)
bash ~/.exasol-starter-kit/kit/upgrade/rollback-kit2.sh     # changed your mind? clean revert to Kit 1
```

---

## Is it safe?

Built for people who read installers before piping them to a shell:

- ✅ **Everything is inspectable** — all executed scripts live on your disk, before and after
- ✅ **Every download is verified** — pinned versions, SHA-256 checked
- ✅ **Local only** — the database listens on `127.0.0.1`, TLS on; the AI bridge is **read-only by design**
- ✅ **No sudo, ever** — everything lives in `~/.local/bin` and `~/.exasol-starter-kit`; credentials stored `0600`, never logged
- ✅ **Reversible** — `exakit teardown` removes it cleanly

## Quick answers

| Question | Answer |
|---|---|
| Do I need Rust / Python / Homebrew / git? | **No.** The installer brings everything it needs |
| Does it cost anything? | No — Exasol Personal is free for personal use |
| "Docker is installed but not running"? | Start Docker Desktop, run the install command again |
| Port 8563 already taken? | `EXAKIT_DB_PORT=8564` before the install command *(Linux/Windows container path)* |
| Behind a corporate proxy? | `export HTTPS_PROXY=...` and re-run |
| Where's the deep-dive for my OS? | [macOS](quickstarts/macos.md) · [Windows + WSL](quickstarts/windows-wsl.md) · [Windows + Docker](quickstarts/windows-docker.md) |
| Step-by-step to the first AI query? | [QUICKSTART](QUICKSTART.md) → [First workflow](demo/first-revenue-analysis.md) |
| How do I remove everything? | `exakit teardown --data`, then `rm -rf ~/.exasol-starter-kit` |

---

<div align="center">

**Start locally. Connect AI safely. Inspect the SQL. Validate the output. Rerun the workflow.**

*Questions or issues → open an issue in this repository.*

</div>
