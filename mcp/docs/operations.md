# Operations

Status: Phase 3 baseline, aligned to the detailed design draft.

## Runtime Ownership

Owned mutable state belongs under:

- `~/.exasol-starter-kit/manifest.json`
- `~/.exasol-starter-kit/logs/`
- `~/.exasol-starter-kit/generated/`
- `~/.exasol-starter-kit/backups/`
- `~/.exasol-starter-kit/clients/`
- `~/.exasol-starter-kit/runtime/`
- `~/.exasol-starter-kit/cache/`

## Operational Expectations

- Re-running configuration should be safe.
- Repair should prefer non-destructive correction before replacement.
- Backup should run before restore, repair, uninstall, or upgrade-driven rewrites.
- Uninstall should remove only subsystem-owned artifacts.
- Doctor mode should separate environment checks from mutating actions.

## Open Questions For Later Phases

- Backup naming and retention policy
- Log format and verbosity model
- Manifest schema versioning strategy
- Recovery behavior after partially failed operations
