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
- Verified client adapter: [claude_desktop.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/adapters/claude_desktop.py)
- Runtime manifest and snapshots: [manifest.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/runtime/manifest.py), [snapshots.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/runtime/snapshots.py)

See [architecture.md](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/docs/architecture.md) for the governing component boundaries.
