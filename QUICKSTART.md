# Quickstart — zero to your first AI-assisted query

Goal: a local Exasol database on your machine, an AI assistant connected to it, and your first question answered — with the SQL visible and rerunnable.

## 1. Check your machine (optional, 10 seconds)

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

All ✓? Continue. Any ✗ tells you exactly what to fix.

## 2. Install everything (one command)

**macOS / Linux / WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | sh
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.ps1 | iex
```

What you'll see: a detection summary, the installation plan, then numbered steps — database, exapump, MCP server — ending in a **connection details panel**. On every platform the first database deployment usually finishes in under 2 minutes. The `exakit`/`exapump` commands below work the same way on native Windows PowerShell as on macOS/Linux/WSL — except Windows-on-ARM, which gets the database container only (see the [Windows Docker quickstart](quickstarts/windows-docker.md) for Windows-specific notes).

> Prefer to read the scripts first? Add `EXAKIT_DRY_RUN=1` before `sh` — the kit is downloaded to `~/.exasol-starter-kit/kit` and nothing installs until you run the setup script yourself.

## 3. Verify it's alive

```bash
exakit status     # runtime: running
exakit info       # the connection panel, any time you need it
```

Run a query straight from your terminal:

```bash
exapump sql -p starter-kit 'SELECT CURRENT_TIMESTAMP'
```

If that returns a timestamp, your local database works end to end.

## 4. Connect your AI assistant

Run the guided MCP setup:

```bash
exakit mcp-setup
```

A checkbox menu lets you pick from the supported clients — Claude, Codex, Cursor, Gemini CLI, GitHub Copilot (VS Code), OpenCode, Continue. The setup backs up each selected client's config file before editing it.

When the kit can resolve the local MCP launcher path, it writes that exact path into the client config instead of assuming `uvx` is available on every desktop app's PATH. That keeps setup portable across macOS, Linux, and Windows clients.

For the local Exasol Personal runtime, the managed MCP config also sets `EXA_SSL_CERT_VALIDATION=no`. This matches the local `127.0.0.1` self-signed certificate setup; use a trusted CA instead for a real remote or shared production database.

After setup, restart the selected client and look for an MCP server named `exasol`. The server is started by the AI client on demand over stdio; it is not a separate background service.

### Optional — let your AI agent run the kit for you

The kit includes an **AI skill** that teaches Claude Code, Codex, or Cursor to drive these steps themselves. The installer offers to install it; you can also run it any time:

```bash
exakit skills-install
```

Then, in a **fresh** agent session, say **"setup starter kit"** — it checks state, connects MCP, loads data, and runs the first query with SQL shown before execution. Details: [`skills/README.md`](skills/README.md).

## 5. Ask your first question

The installer offers a data loading menu after exapump is ready and before MCP setup. Open it again any time to load the bundled sample datasets or a local CSV/Parquet file — each load is verified after it runs:

```bash
exakit data-load
```

To reload the bundled TPC-H sample directly, without the menu:

```bash
exakit data-load --force
```

Then ask your assistant something like:

> *"Use the exasol MCP server connected to my local Exasol database. List the available schemas and tables first. Then answer my questions with read-only SQL only, show me the SQL before you run it, and do not create, update, or delete anything."*
> *"Show me total revenue by product category — and show me the SQL before you run it."*

The MCP server is **read-only by design**: the assistant can discover schema and run SELECT queries, nothing else. Ask it to show the SQL first — inspect, then approve. That's the workflow this kit exists to prove.

## Everyday commands

```bash
exakit status              # health at a glance
exakit info                # connection details
exakit stop                # stop the database (keeps all state)
exakit start               # bring it back
exakit logs                # latest setup log path
exakit uninstall           # remove everything the kit installed
```

Re-running the installer is always safe — it skips what's done and repairs what isn't.

## If something goes wrong

| Symptom | Fix |
|---|---|
| "Docker is installed but not running" | Start Docker Desktop / `podman machine start`, then re-run |
| "Port 8563 is already in use" | Stop the other app; on Linux/Windows containers you can instead re-run with `EXAKIT_DB_PORT=8564` (the macOS deployment needs 8563 itself) |
| Setup failed mid-way | Re-run the same install command — it resumes from the failed step |
| Assistant can't see the database | `exakit status` (is the runtime running?), then restart the MCP client after config changes |
| Anything else | `exakit logs` has the full story; every error message names its remedy |
