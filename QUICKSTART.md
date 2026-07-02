# Quickstart — zero to your first AI-assisted query

Goal: a local Exasol database on your machine, an AI assistant connected to it, and your first question answered — with the SQL visible and rerunnable.

## 1. Check your machine (optional, 10 seconds)

```bash
curl -fsSL https://raw.githubusercontent.com/Sheetaldharshan200/exasol-personal-local-starter-kit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

All ✓? Continue. Any ✗ tells you exactly what to fix.

## 2. Install everything (one command)

**macOS / Linux / WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/Sheetaldharshan200/exasol-personal-local-starter-kit/main/install.sh | sh
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/Sheetaldharshan200/exasol-personal-local-starter-kit/main/install.ps1 | iex
```

> **Native Windows note:** the PowerShell path currently installs the database container only — the `exakit`/`exapump` commands below and the generated MCP configs come with the macOS/Linux/WSL path. On Windows, follow the [Windows Docker quickstart](quickstarts/windows-docker.md) for verification and MCP setup, or run the install inside WSL for the full experience.

What you'll see: a detection summary, the installation plan, then numbered steps — database, exapump, MCP server — ending in a **connection details panel**. On macOS the first database deployment takes 10–20 minutes (one-time); container platforms are up in a few minutes.

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

Choose `temporary` for copy/paste instructions only: files are generated in `~/.exasol-starter-kit/mcp/`, and no AI client config is changed until you copy or merge them yourself. Choose `permanent` when you want the kit to back up and edit the supported client config files for Claude Desktop, Cursor, or Codex.

When the kit can resolve the local MCP launcher path, it writes that exact path into the generated config instead of assuming `uvx` is available on every desktop app's PATH. That makes the same bundle more portable across macOS, Linux, and Windows clients.

After temporary setup, copy or merge the generated config, then restart the client. After permanent setup, just restart the selected client and look for an MCP server named `exasol`. The server is started by the AI client on demand over stdio; it is not a separate background service.

## 5. Ask your first question

The installer offers a guided data loading menu after exapump is ready and before MCP setup. Open it any time for local files, remote files, database imports, Exapump help, or SQL scripts; the default option loads and verifies the bundled `data/` folder:

```bash
exakit data-load
```

If you only want the bundled sample dataset, this command is safe to run any time and idempotent:

```bash
exakit load-data           # or: exakit load-data --force to reload
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
exakit teardown --data     # remove everything database-related
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

## Next: Kit 2 — the trust layer

When you're ready for semantic grounding, an audit/run log, and saved workflows:

```bash
bash ~/.exasol-starter-kit/kit/upgrade/upgrade-kit2.sh
```

No reinstall — it detects your Kit 1 setup and adds only what's missing.
