# Exasol Personal Local Starter Kit

Local-first, AI-assisted data workflows you can inspect, validate, and rerun.

**Kit 1 — Local Agent-Ready Starter:** one command installs a local Exasol runtime, exapump, and the Exasol MCP server, connects them, and prints your connection details.

**Kit 2 — Trusted AI Workflow Add-on:** additive upgrade with semantic model, audit/run log, and saved workflows. No reinstall.

## Repository structure

```
exasol-personal-local-starter-kit/
├── install.sh                        # one-command pipe installer (macOS/Linux/WSL)
├── install.ps1                       # one-command installer (Windows PowerShell)
├── README.md
├── QUICKSTART.md                     # shortest path to first query
│
├── quickstarts/                      # OS-specific onboarding guides
│   ├── macos.md
│   ├── windows-wsl.md
│   └── windows-docker.md
│
├── setup/                            # setup orchestration
│   ├── setup-macos.sh                #   Exasol Personal local
│   ├── setup-wsl.sh                  #   Exasol Nano container (Docker → Podman)
│   ├── setup-windows-docker.ps1      #   Exasol Nano via Docker Desktop
│   ├── exakit                        #   lifecycle helper: status/start/stop/info/teardown
│   └── lib/                          #   shared modules (logging, detection, manifest,
│                                     #   runtime/exapump/MCP install steps)
│
├── sql/                              # schema, load, verify
│   ├── 01_create_schema.sql
│   ├── 02_load_data.sql
│   ├── 03_verify_setup.sql
│   └── mcp_readonly_user.sql         #   read-only user for safe MCP access
│
├── data/                             # sample dataset
│   ├── customers.csv
│   ├── products.csv
│   ├── orders.csv
│   ├── returns.csv
│   └── data-dictionary.md
│
├── mcp/                              # MCP client config templates
│   ├── claude-config.json
│   ├── cursor-config.json
│   └── generic-config.json
│
├── demo/                             # first guided workflow
│   ├── first-revenue-analysis.md
│   └── first-revenue-analysis.workflow.json
│
├── advanced/                         # Kit 2 assets (semantic/trust layer)
│   ├── README.md
│   ├── semantic/sales_semantic_model.yml
│   ├── audit_log_schema.sql
│   └── saved_workflow_example.json
│
├── upgrade/                          # Kit 1 → Kit 2 upgrade path
│   ├── upgrade-kit2.sh               #   additive, no reinstall
│   └── rollback-kit2.sh
│
├── skills/                           # AI assistant skills
│   ├── local-agent-ready-starter/SKILL.md
│   └── trusted-ai-workflow/SKILL.md
│
├── workshop/                         # workshop enablement kit (later phase)
│
└── tests/
    ├── smoke-test.sh                 # clean-machine e2e + re-run safety
    └── dry-run-matrix.sh             # OS/runtime detection test matrix
```

## Principles

1. **One command installs everything** — `install.sh` detects OS and hardware, routes to the right runtime (Exasol Personal on macOS; Exasol Nano container on Windows/Linux/WSL, Docker first with Podman fallback), installs exapump and the MCP server, connects all components, and prints the connection strings.
2. **Repo stays pure source** — all runtime state (install manifest, logs, credentials, generated configs) lives in `~/.exasol-starter-kit/` on the user's machine; nothing generated is committed.
3. **The install manifest is the Kit 1 → Kit 2 contract** — it records what is installed at which kit level, so the Kit 2 upgrade is purely additive and can roll back cleanly.
4. **Parallel-friendly ownership** — setup scripts consume `sql/`, `data/`, and `mcp/` files by path as external inputs; missing files are reported as pending, not errors.
5. **Layered and inspectable** — `install.sh` → `setup-<os>.sh` → `setup/lib/` modules; every layer can be downloaded, read, and run manually.
6. **Pinned versions** — component versions are pinned to known-good releases and overridable via environment variables.
