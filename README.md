# Exasol Personal Local Starter Kit

**Local-first, AI-assisted data workflows you can inspect, validate, and rerun.**

One command installs a local Exasol database, [exapump](https://github.com/exasol-labs/exapump) for data loading, and the [Exasol MCP server](https://github.com/exasol/mcp-server) as the AI agent bridge — connects them, and prints your connection details. No cloud account, no admin rights, no license key.

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | sh
```

In a few minutes you can point Claude Desktop, Cursor, or any MCP client at your own local database and ask it questions — with every query inspectable and every step rerunnable.

---

## Requirements

The list is short by design — no Rust, no Python packages, no Homebrew, no git, no sudo, no Exasol account:

| Platform | You need | The installer brings |
|---|---|---|
| **macOS** | 8 GB+ RAM, ~20 GB free disk | Exasol Personal (local), exapump, uv, MCP server |
| **Linux / WSL** | Docker or Podman — installed *and running* — 4 GB+ RAM | Exasol Nano container, exapump, uv, MCP server |
| **Windows** | Docker Desktop (running), 4 GB+ RAM | Exasol Nano container |

Not sure your machine qualifies? Check everything without installing anything:

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | EXAKIT_PREFLIGHT=1 sh
```

Each failed check is reported with its remedy. The same check is available after installation as `exakit preflight`.

## Install

**macOS, Linux, WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.sh | sh
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/ranjanm-chn/exasol-personal-local-starter-kit/main/install.ps1 | iex
```

The installer detects your OS and hardware and routes to the right database:

- **macOS** → Exasol Personal, deployed locally (first deploy takes 10–20 minutes — one-time)
- **Linux / WSL / Windows** → Exasol Nano container — Docker preferred, Podman fallback

It then installs exapump and the MCP server on every path, wires them to the database, and finishes with a connection-details panel.

### Trust properties

Built for people who read installers before running them:

- **Inspect before (or after) you run** — the kit is copied to `~/.exasol-starter-kit/kit`; every script that executes is on your disk in plain text. `EXAKIT_DRY_RUN=1` fetches, shows the plan, and stops.
- **Verified artifacts** — release binaries are pinned to known-good versions and SHA-256 checked before use.
- **Safe to re-run, always** — completed steps skip, failed steps retry, nothing is ever half-reinstalled. A failed run tells you which step failed, where the full log is, and offers to undo its changes.
- **No surprises in scope** — everything lands in `~/.local/bin` and `~/.exasol-starter-kit`; no sudo, no shell-profile edits, no system files touched. Credentials are stored `0600`, never logged, never echoed.
- **Local only** — the database listens on `127.0.0.1`, TLS enabled, and the MCP bridge is read-only by design.

## After the install

```bash
exakit status        # what is installed, and is it healthy
exakit info          # connection details panel (DSN, user, config paths)
exakit preflight     # re-check machine requirements any time
exakit start         # start the local database
exakit stop          # stop it (state is kept)
exakit teardown      # remove the runtime; --data also deletes database content
exakit logs          # path of the latest setup log
```

**Connect an AI assistant** — ready-made configs are generated under `~/.exasol-starter-kit/mcp/`:

- `claude-config.json` — Claude Desktop (Settings → Developer → Edit Config)
- `cursor-config.json` — Cursor
- `generic-config.json` — any other MCP client

**Load the sample dataset** (activates once the kit's SQL and data files are delivered):

```bash
bash ~/.exasol-starter-kit/kit/setup/load-data.sh          # fully logged, rerunnable
```

See [QUICKSTART.md](QUICKSTART.md) for the end-to-end walkthrough to a first AI-assisted query.

## Kit 2: Trusted AI Workflow Add-on

Builds on Kit 1 **additively** — no reinstall of the database, exapump, MCP, or data. Adds the trust layer: semantic model, audit/run log, saved workflow examples.

```bash
bash ~/.exasol-starter-kit/kit/upgrade/upgrade-kit2.sh     # detects Kit 1 via the manifest, adds only what's missing
bash ~/.exasol-starter-kit/kit/upgrade/rollback-kit2.sh    # removes exactly what the upgrade added — Kit 1 untouched
```

## Configuration

Component versions are pinned to known-good releases; everything is overridable via environment variables (flags don't travel through a pipe):

| Variable | Default | Purpose |
|---|---|---|
| `EXAKIT_PERSONAL_VERSION` | `2.0.0-rc4` | Exasol Personal release (macOS) |
| `EXAKIT_NANO_TAG` | `2026.2.0-nano.2` | Exasol Nano image tag |
| `EXAKIT_EXAPUMP_VERSION` | `0.11.2` | exapump release |
| `EXAKIT_MCP_VERSION` | `1.10.1` | MCP server package version |
| `EXAKIT_DB_PORT` | `8563` | local SQL port |
| `EXAKIT_HOME` | `~/.exasol-starter-kit` | state, logs, credentials, kit copy |
| `EXAKIT_DRY_RUN` | — | `1` = fetch + show plan, install nothing |
| `EXAKIT_PREFLIGHT` | — | `1` = requirements report, install nothing |
| `EXAKIT_LOCAL_KIT` | — | install from a local checkout (development) |
| `EXAKIT_FORCE` | — | `1` = override disk/RAM soft gates |

## Troubleshooting

Every failure ends in one of three states: a **clear requirement message** ("install Docker, then re-run"), a **hard stop with the reason and numbers** ("8 GB RAM required, 4 detected"), or a **safe retry** (re-run resumes from the failed step). The most common cases:

| Symptom | Fix |
|---|---|
| "Docker is installed but not running" | Start Docker Desktop (or `podman machine start`), re-run the installer |
| "Port 8563 is already in use" | Stop the other application, or `EXAKIT_DB_PORT=8564` and re-run |
| "python3 is required" | macOS: `xcode-select --install` · Linux: `sudo apt install python3` |
| Download failures behind a proxy | `export HTTPS_PROXY=...` (curl honors it), re-run |
| Setup failed mid-way | Just re-run the same command — completed steps skip, the failed one retries. Full log: `exakit logs` |
| Wipe and start over | `exakit teardown --data`, then `rm -rf ~/.exasol-starter-kit`, then install again |

## Development

```bash
bash tests/dry-run-matrix.sh     # detection/routing logic across simulated environments (no installs)
bash tests/smoke-test.sh         # pipe-entry dry run; EXAKIT_SMOKE_FULL=1 for a real end-to-end install
```

**Layering:** `install.sh` / `install.ps1` (thin pipe entries) → `setup/setup-<os>` (orchestrators) → `setup/lib/` (modules: detection, runtimes, exapump, MCP, shared plumbing). Each layer runs standalone.

**State:** everything generated at runtime — install manifest, logs, credentials, MCP configs — lives in `~/.exasol-starter-kit/`, never in the repo. The manifest (`manifest.json`) records every component, version, and the kit level; it is the contract that makes re-runs idempotent, the Kit 2 upgrade additive, and the teardown precise.

**Team assets:** files under `sql/`, `data/`, `mcp/`, `demo/`, `skills/`, and `advanced/` are delivered by their owners. Setup scripts consume them by path and report missing ones as *pending*, never as errors — so the kit installs cleanly at every stage of the project.
