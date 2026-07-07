# Quickstart

This subsystem now has a working Python implementation plus lifecycle tests.

## Current Status

- Supported verified live adapters: Claude Desktop, Cursor, and Codex
- Permanent runtime client setup: Claude Desktop, Cursor, and Codex
- Supported operations: discover, configure, validate, repair, backup, restore, doctor, uninstall, status
- Explicitly blocked operation: install
- Runtime files are generated under the request-specific runtime root, defaulting to `~/.exasol-starter-kit`

## Read In Order

1. [AGENT.md](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/AGENT.md)
2. [requirements.md](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/docs/requirements.md)
3. [architecture.md](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/docs/architecture.md)
4. [design.md](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/docs/design.md)
5. [api-design.md](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/docs/api-design.md)
6. [service.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/service.py)
7. [test_service.py](/Users/sheetaldharshan.a/Desktop/exasol-personal-local-starter-kit/mcp/tests/test_service.py)

## Test Command

```bash
python3 -m unittest discover -s mcp/tests -v
```

## Lifecycle Commands

The installed user-facing wrapper now exposes the managed MCP lifecycle directly:

```bash
exakit mcp-setup
exakit mcp-status
exakit mcp-validate
exakit mcp-repair
exakit mcp-doctor
exakit mcp-remove
exakit mcp-restore
```
