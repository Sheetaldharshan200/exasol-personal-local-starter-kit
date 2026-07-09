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

- Public orchestration entry point: [service.py](service.py)
- Client adapters (six shipped): [claude_desktop.py](adapters/claude_desktop.py), [claude_code.py](adapters/claude_code.py), [cursor.py](adapters/cursor.py), [codex.py](adapters/codex.py), [vscode_copilot.py](adapters/vscode_copilot.py), [gemini_cli.py](adapters/gemini_cli.py)
- Runtime manifest and snapshots: [manifest.py](runtime/manifest.py), [snapshots.py](runtime/snapshots.py)
- Installed-runtime permanent client setup: [exakit.py](runtime/exakit.py), [cli.py](cli.py)

## Runtime Client Setup

When the starter kit runtime is already installed and its manifest contains the MCP connection details, the MCP package can configure any of the six supported clients:

- Claude Desktop
- Claude Code (CLI)
- Cursor
- Codex
- VS Code (GitHub Copilot)
- Gemini CLI

The setup menu is dynamic: it offers only the clients found on the machine that are not already connected, and pre-selects every one it offers.

## Remaining Gaps

- Native Windows PowerShell installer parity still needs the same no-preinstalled-Python treatment as the shell flow

See [architecture.md](docs/architecture.md) for the governing component boundaries.
