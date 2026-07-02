# Tasks

Status: Phase 4 approved baseline for Phase 5 API design.

## Tasking Goals

- Convert the approved design into an execution-ready backlog
- Preserve strict dependency ordering
- Enable component-by-component implementation
- Keep testing and validation embedded in the work, not deferred to the end

## Rules

- Tasks must map back to approved design.
- No task may imply architecture not already documented.
- No implementation starts until Phase 5 API design is approved.
- Each implementation workstream must include validation and test tasks.

## Workstream Overview

The backlog is organized into nine workstreams:

1. foundation and repository scaffolding
2. core contracts and result model
3. runtime and manifest management
4. adapter framework
5. validation and security controls
6. operation orchestration
7. diagnostics and reporting
8. integration and cross-platform hardening
9. release-readiness and documentation finish

## Dependency Order

```text
Foundation
  -> Core contracts
    -> Runtime + Adapter framework
      -> Validation + Security
        -> Operation orchestration
          -> Diagnostics
            -> Integration hardening
              -> Release readiness
```

## Phase 4 Backlog

### WS-01 Foundation And Repository Scaffolding

Goal:

- prepare the internal `mcp/` package layout for later implementation without committing to code yet

Tasks:

- `T-001` Define the implementation package map for `mcp/core`, `mcp/adapters`, `mcp/security`, `mcp/validator`, `mcp/runtime`, `mcp/templates`, `mcp/diagnostics`, and `mcp/tests`.
- `T-002` Define shared naming conventions for domain types, repositories, services, and adapters.
- `T-003` Define the local development conventions for runtime-root isolation and test fixture placement.
- `T-004` Define how generated artifacts and sample templates will be separated from test fixtures.

Deliverables:

- agreed package map
- agreed naming map
- implementation placement notes

Dependencies:

- none

### WS-02 Core Contracts And Result Model

Goal:

- define the stable internal contracts the rest of the subsystem will depend on

Tasks:

- `T-010` Finalize the internal shape of `OperationRequest`.
- `T-011` Finalize the internal shape of `OperationPlan`.
- `T-012` Finalize the internal shape of `OperationResult`.
- `T-013` Finalize the `Finding` model, severity levels, and evidence rules.
- `T-014` Finalize artifact ownership enumerations: `managed`, `observed`, `conflicting`, `orphaned`.
- `T-015` Finalize subsystem error categories and blocking-versus-recoverable semantics.
- `T-016` Define internal repository interfaces for manifest storage, snapshot storage, environment inspection, and filesystem access.

Deliverables:

- contract definitions
- error model definitions
- interface definitions

Dependencies:

- WS-01

### WS-03 Runtime And Manifest Management

Goal:

- make runtime ownership, backup, restore, and uninstall behavior implementation-ready

Tasks:

- `T-020` Finalize manifest schema version `1` fields and invariants.
- `T-021` Define artifact hashing rules and when hashes are recomputed.
- `T-022` Define snapshot metadata schema and directory layout.
- `T-023` Define manifest update semantics for create, modify, remove, and restore operations.
- `T-024` Define orphaned-artifact handling rules.
- `T-025` Define backup retention and naming strategy.
- `T-026` Define uninstall manifest behavior: archive versus delete after final snapshot.

Test-first tasks:

- `T-027` Define manifest repository unit-test scenarios.
- `T-028` Define backup/restore integrity test scenarios.
- `T-029` Define uninstall safety test scenarios for managed versus observed artifacts.

Deliverables:

- finalized manifest contract
- snapshot contract
- lifecycle rules
- test matrix for runtime ownership

Dependencies:

- WS-02

### WS-04 Adapter Framework

Goal:

- make client support extensible and safe to implement incrementally

Tasks:

- `T-030` Finalize the conceptual `ClientAdapter` contract into an implementation-ready internal interface.
- `T-031` Define adapter registry behavior, loading order, and conflict handling.
- `T-032` Define adapter detection result shapes and confidence semantics.
- `T-033` Define adapter capability metadata and platform applicability rules.
- `T-034` Define the distinction between fully managed file generation and patch-only behavior.
- `T-035` Define adapter inspection outputs for current-state analysis.
- `T-036` Define activation guidance contract for restart and follow-up instructions.

Client rollout planning tasks:

- `T-037` Prioritize first-wave adapters for implementation.
- `T-038` Identify which target clients require verified config-location research before coding.
- `T-039` Define minimum adapter acceptance criteria.

Test-first tasks:

- `T-040` Define adapter contract tests shared by all adapters.
- `T-041` Define detection, render, and validation test expectations per adapter.

Deliverables:

- adapter contract
- adapter registry contract
- client rollout plan
- shared adapter test contract

Dependencies:

- WS-02

### WS-05 Validation And Security Controls

Goal:

- make validation and local safety rules explicit enough to code safely

Tasks:

- `T-050` Finalize config syntax validation stages and outputs.
- `T-051` Finalize environment validation rules for binaries, runtime-root accessibility, and client presence.
- `T-052` Finalize connectivity validation rules for non-destructive Exasol checks.
- `T-053` Finalize permission posture validation rules for read-only expectations.
- `T-054` Finalize manifest consistency validation rules.
- `T-055` Define deployment-mode risk checks for `stdio` versus HTTP.
- `T-056` Define local file-permission policy and platform fallback behavior.
- `T-057` Define secret-redaction rules for logs, findings, and status output.
- `T-058` Define security blockers that should prevent mutation entirely.

Test-first tasks:

- `T-059` Define validator unit-test matrix.
- `T-060` Define security policy test matrix.

Deliverables:

- validator contract set
- security policy set
- blocking rule set

Dependencies:

- WS-02
- WS-03
- WS-04

### WS-06 Operation Orchestration

Goal:

- define implementation-ready orchestration for each public operation

Tasks:

- `T-070` Break `discover` into orchestration steps and define its exact side-effect boundary.
- `T-071` Break `configure` into inspect, plan, backup, apply, validate, and record phases.
- `T-072` Break `validate` into explicit stage orchestration and result aggregation.
- `T-073` Break `repair` into detection, strategy selection, mutation, and verification phases.
- `T-074` Break `backup` into snapshot selection and creation phases.
- `T-075` Break `restore` into integrity check, rollback protection, apply, and verify phases.
- `T-076` Break `uninstall` into ownership filtering, snapshot, remove, and verify phases.
- `T-077` Break `doctor` and `status` into read-only diagnostic flows.
- `T-078` Define precondition enforcement and short-circuit rules across all operations.
- `T-079` Define dry-run behavior for all mutating operations.

Test-first tasks:

- `T-080` Define operation-level orchestration test cases.
- `T-081` Define partial-failure and rollback test cases.

Deliverables:

- orchestration specifications per operation
- dry-run behavior rules
- partial-failure handling rules

Dependencies:

- WS-03
- WS-04
- WS-05

### WS-07 Diagnostics And Reporting

Goal:

- make outputs actionable for both humans and installer orchestration

Tasks:

- `T-090` Define doctor report structure.
- `T-091` Define status report structure.
- `T-092` Define drift report structure.
- `T-093` Define upgrade-readiness report structure.
- `T-094` Define summary and finding formatting rules for non-technical consumers.
- `T-095` Define machine-readable result serialization shape for installer consumption.

Test-first tasks:

- `T-096` Define diagnostics rendering tests.
- `T-097` Define result-serialization contract tests.

Deliverables:

- diagnostics contracts
- installer-facing result contract

Dependencies:

- WS-02
- WS-05
- WS-06

### WS-08 Integration And Cross-Platform Hardening

Goal:

- reduce ambiguity at the installer boundary and platform edges before coding starts

Tasks:

- `T-100` Finalize upstream handoff assumptions into explicit API questions for the installer owner.
- `T-101` Finalize path-resolution strategy boundaries between core and adapters.
- `T-102` Define cross-platform permission fallback behavior.
- `T-103` Define runtime-root bootstrap behavior for first run.
- `T-104` Define how existing user-managed client config should be handled when managed ownership is not possible.
- `T-105` Define upgrade-compatibility metadata requirements for adapters and manifest records.

Test-first tasks:

- `T-106` Define cross-platform path test scenarios.
- `T-107` Define ownership-conflict and patch-mode test scenarios.

Deliverables:

- integration question set
- cross-platform rules
- ownership conflict policy

Dependencies:

- WS-03
- WS-04
- WS-06

### WS-09 Release-Readiness And Documentation Finish

Goal:

- ensure the implementation phase starts with clear constraints and complete supporting docs

Tasks:

- `T-110` Reconcile `requirements.md`, `architecture.md`, `design.md`, `security.md`, and `integration.md` after task breakdown approval.
- `T-111` Update `testing-strategy.md` with the task-derived test matrix.
- `T-112` Update `risk-analysis.md` with implementation-phase risks uncovered during tasking.
- `T-113` Record any final pre-implementation ADRs in `decisions.md`.
- `T-114` Prepare the API-design input list for Phase 5.

Deliverables:

- refreshed supporting docs
- API design input set

Dependencies:

- WS-01 through WS-08

## Suggested Implementation Sequence After Approval

When implementation eventually begins, use this order:

1. repository scaffolding and shared abstractions
2. core contracts and error model
3. manifest and snapshot repository
4. adapter registry and one reference adapter
5. validation and security policies
6. configure and validate orchestration
7. repair, backup, restore, and uninstall orchestration
8. diagnostics and status reporting
9. additional client adapters

## Critical Open Questions Before Implementation

- Which upstream component owns credential resolution?
- Which target clients support full managed ownership versus patch-only behavior?
- What exact non-destructive Exasol validation query or probe should be standardized?
- Should uninstall archive the manifest or delete it after final backup?

## Definition Of Ready For Phase 5

- All major workstreams have explicit task coverage.
- Dependencies are clear enough to sequence work safely.
- Test-first requirements are attached to each major workstream.
- Remaining ambiguities are surfaced as questions, not hidden in tasks.
