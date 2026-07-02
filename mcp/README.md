# MCP Subsystem

This directory contains the MCP access and client configuration subsystem for the Exasol Personal Local Starter Kit.

## Intended Internal Structure

```text
mcp/
├── AGENT.md
├── QUICKSTART.md
├── docs/
├── core/
├── adapters/
├── security/
├── validator/
├── runtime/
├── templates/
├── diagnostics/
├── tests/
└── README.md
```

## Phase Status

- Architecture, design, and API contracts are documented in `docs/`
- The Python implementation now lives under `core/`, `runtime/`, `adapters/`, `security/`, `validator/`, and `diagnostics/`
- End-to-end lifecycle coverage is implemented in `tests/test_service.py`

## Current Implementation Scope

- Public orchestration entry point: [service.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/service.py)
- Verified live client adapters: [claude_desktop.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/adapters/claude_desktop.py), [cursor.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/adapters/cursor.py), [codex.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/adapters/codex.py)
- Runtime manifest and snapshots: [manifest.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/runtime/manifest.py), [snapshots.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/runtime/snapshots.py)
- Installed-runtime MCP bundle export: [exakit.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/runtime/exakit.py), [exporter.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/runtime/exporter.py), [cli.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/cli.py)

## Exported Client Bundle

When the starter kit runtime is already installed and its manifest contains the MCP connection details, the MCP package can export ready-made client config files under `~/.exasol-starter-kit/mcp/` for:

- Claude Desktop
- Cursor
- Codex

## Remaining Gaps

- Native Windows PowerShell installer parity still needs the same no-preinstalled-Python treatment as the shell flow

See [architecture.md](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/docs/architecture.md) for the governing component boundaries.
