"""Command-line entry points for the MCP subsystem."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from mcp.adapters.registry import AdapterRegistry
from mcp.core.errors import MCPSubsystemError
from mcp.core.models import (
    DsnReference,
    NextAction,
    OperationName,
    OperationRequest,
    OperationStatus,
    utc_now,
)
from mcp.core.serialization import to_primitive
from mcp.runtime.environment import ExecutionEnvironment
from mcp.runtime.exakit import ExakitRuntimeLoader
from mcp.runtime.exporter import ALL_CLIENT_IDS, RuntimeMCPConfigExporter, SETUP_CLIENT_IDS
from mcp.runtime.filesystem import FileSystem
from mcp.runtime.manifest import ManifestRepository
from mcp.runtime.paths import RuntimePaths
from mcp.service import MCPAccessSubsystem
from mcp.validator.service import StageResult, ValidatorService


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m mcp")
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_parser = subparsers.add_parser(
        "export-runtime-configs",
        help="Generate ready-made MCP client config files from an installed starter-kit runtime.",
    )
    export_parser.add_argument(
        "--runtime-root",
        default="~/.exasol-starter-kit",
        help="Starter-kit runtime root. Defaults to ~/.exasol-starter-kit.",
    )
    export_parser.add_argument(
        "--clients",
        nargs="*",
        default=list(ALL_CLIENT_IDS),
        choices=list(ALL_CLIENT_IDS),
        help="Subset of client configs to export.",
    )
    setup_parser = subparsers.add_parser(
        "setup-runtime-clients",
        help="Apply or export MCP client setup for an installed starter-kit runtime.",
    )
    setup_parser.add_argument(
        "--runtime-root",
        default="~/.exasol-starter-kit",
        help="Starter-kit runtime root. Defaults to ~/.exasol-starter-kit.",
    )
    setup_parser.add_argument(
        "--mode",
        default="temporary",
        choices=("temporary", "permanent"),
        help="temporary exports ready-made configs; permanent writes directly into client config files.",
    )
    setup_parser.add_argument(
        "--clients",
        nargs="+",
        default=list(SETUP_CLIENT_IDS),
        choices=list(SETUP_CLIENT_IDS),
        help="One or more concrete MCP clients to set up.",
    )
    operation_parser = subparsers.add_parser(
        "run-runtime-operation",
        help="Run a managed MCP lifecycle operation against an installed starter-kit runtime.",
    )
    operation_parser.add_argument(
        "operation",
        choices=("validate", "repair", "backup", "restore", "doctor", "uninstall", "status"),
        help="Managed MCP lifecycle operation to run.",
    )
    operation_parser.add_argument(
        "--runtime-root",
        default="~/.exasol-starter-kit",
        help="Starter-kit runtime root. Defaults to ~/.exasol-starter-kit.",
    )
    operation_parser.add_argument(
        "--clients",
        nargs="*",
        default=[],
        choices=list(SETUP_CLIENT_IDS),
        help="Optional subset of concrete MCP clients.",
    )
    operation_parser.add_argument(
        "--snapshot-id",
        default="",
        help="Optional snapshot id for restore. Defaults to the latest snapshot when omitted.",
    )

    args = parser.parse_args(argv)
    if args.command == "export-runtime-configs":
        return _export_runtime_configs(args)
    if args.command == "setup-runtime-clients":
        return _setup_runtime_clients(args)
    if args.command == "run-runtime-operation":
        return _run_runtime_operation(args)
    parser.error(f"Unsupported command: {args.command}")
    return 2


def _export_runtime_configs(args: argparse.Namespace) -> int:
    environment = ExecutionEnvironment.current()
    filesystem = FileSystem()
    runtime_root = _resolve_runtime_root(args.runtime_root, environment)
    try:
        loader = ExakitRuntimeLoader(environment=environment, filesystem=filesystem)
        context = loader.load(runtime_root)
        paths = RuntimePaths(runtime_root)
        repository = ManifestRepository(paths, filesystem)
        exporter = RuntimeMCPConfigExporter(paths, repository, filesystem)
        artifacts = exporter.export(context, clients=args.clients)
        payload = {
            "runtime_root": str(runtime_root),
            "exported_clients": args.clients,
            "artifacts": [to_primitive(artifact) for artifact in artifacts],
        }
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    except MCPSubsystemError as exc:
        print(f"{exc.code}: {exc.message}", file=sys.stderr)
        return 1


def _setup_runtime_clients(args: argparse.Namespace) -> int:
    environment = ExecutionEnvironment.current()
    filesystem = FileSystem()
    runtime_root = _resolve_runtime_root(args.runtime_root, environment)
    try:
        loader = ExakitRuntimeLoader(environment=environment, filesystem=filesystem)
        repository = ManifestRepository(RuntimePaths(runtime_root), filesystem)
        clients = list(dict.fromkeys(args.clients))
        if args.mode == "temporary":
            payload = _temporary_setup(
                environment=environment,
                filesystem=filesystem,
                runtime_root=runtime_root,
                repository=repository,
                context_loader=loader,
                clients=clients,
            )
        else:
            payload = _permanent_setup(
                environment=environment,
                filesystem=filesystem,
                runtime_root=runtime_root,
                context_loader=loader,
                clients=clients,
            )
        _record_client_setup(repository, args.mode, clients, payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        if payload.get("status") in {
            OperationStatus.SUCCESS.value,
            OperationStatus.SUCCESS_WITH_WARNINGS.value,
            OperationStatus.NO_CHANGE.value,
        }:
            return 0
        return 1
    except MCPSubsystemError as exc:
        print(f"{exc.code}: {exc.message}", file=sys.stderr)
        return 1


def _run_runtime_operation(args: argparse.Namespace) -> int:
    environment = ExecutionEnvironment.current()
    filesystem = FileSystem()
    runtime_root = _resolve_runtime_root(args.runtime_root, environment)
    repository = ManifestRepository(RuntimePaths(runtime_root), filesystem)
    clients = list(dict.fromkeys(args.clients))
    try:
        raw_request = _build_operation_request(
            operation=args.operation,
            environment=environment,
            filesystem=filesystem,
            repository=repository,
            runtime_root=runtime_root,
            clients=clients,
            snapshot_id=args.snapshot_id,
        )
        subsystem = MCPAccessSubsystem(environment=environment, filesystem=filesystem)
        result = subsystem.execute(raw_request)
        payload = result.to_dict()
        payload.update(
            {
                "runtime_root": str(runtime_root),
                "selected_clients": clients,
            }
        )
        print(json.dumps(payload, indent=2, sort_keys=True))
        if payload.get("status") in {
            OperationStatus.SUCCESS.value,
            OperationStatus.SUCCESS_WITH_WARNINGS.value,
            OperationStatus.NO_CHANGE.value,
        }:
            return 0
        return 1
    except MCPSubsystemError as exc:
        print(f"{exc.code}: {exc.message}", file=sys.stderr)
        return 1


def _temporary_setup(
    environment: ExecutionEnvironment,
    filesystem: FileSystem,
    runtime_root: Path,
    repository: ManifestRepository,
    context_loader: ExakitRuntimeLoader,
    clients: list[str],
) -> dict:
    context = context_loader.load(runtime_root)
    paths = RuntimePaths(runtime_root)
    exporter = RuntimeMCPConfigExporter(paths, repository, filesystem)
    artifacts = exporter.export(context, clients=clients)
    validator = ValidatorService(AdapterRegistry(), repository, environment)
    request = OperationRequest(
        operation=OperationName.VALIDATE,
        target_clients=tuple(clients),
        runtime_root=str(runtime_root),
        dsn_reference=DsnReference(kind="literal", value=context.dsn),
        stages=("config_syntax", "connectivity", "permission_posture"),
    )
    stages = validator.run(request, paths, artifacts)
    status = _status_from_stage_results(stages)
    findings = [finding for stage in stages for finding in stage.findings]
    evidence = [item for stage in stages for item in stage.evidence]
    config_paths = {artifact.client: artifact.path for artifact in artifacts}
    return {
        "mode": "temporary",
        "runtime_root": str(runtime_root),
        "selected_clients": clients,
        "status": status.value,
        "summary": f"Exported ready-made MCP configs for {len(clients)} client(s).",
        "bundle_dir": str(paths.mcp_dir),
        "artifacts": [to_primitive(artifact) for artifact in artifacts],
        "findings": [to_primitive(finding) for finding in findings],
        "verification_evidence": [to_primitive(item) for item in evidence],
        "next_actions": [
            to_primitive(
                NextAction(
                    kind="apply_bundle",
                    message=(
                        f"Copy the ready-made {client_id} config from "
                        f"{config_paths[client_id]} into that client's active MCP config location."
                    ),
                )
            )
            for client_id in clients
        ]
        + [
            to_primitive(
                NextAction(
                    kind="restart_client",
                    message="Restart the selected client(s) after placing the ready-made config files.",
                )
            )
        ],
    }


def _permanent_setup(
    environment: ExecutionEnvironment,
    filesystem: FileSystem,
    runtime_root: Path,
    context_loader: ExakitRuntimeLoader,
    clients: list[str],
) -> dict:
    context = context_loader.load(runtime_root)
    subsystem = MCPAccessSubsystem(environment=environment, filesystem=filesystem)
    result = subsystem.execute(
        {
            "operation": "configure",
            "target_clients": clients,
            "deployment_mode": "stdio",
            "runtime_root": str(runtime_root),
            "server_definition": to_primitive(context.server_definition),
            "credential_reference": {"kind": "inline_env", "name": "EXA_PASSWORD"},
            "dsn_reference": {"kind": "literal", "value": context.dsn},
            "create_snapshot": True,
            "validate_after_apply": True,
        }
    )
    payload = result.to_dict()
    payload.update(
        {
            "mode": "permanent",
            "runtime_root": str(runtime_root),
            "selected_clients": clients,
        }
    )
    return payload


def _record_client_setup(
    repository: ManifestRepository,
    mode: str,
    clients: list[str],
    payload: dict,
) -> None:
    repository.record_client_setup(
        {
            "completed": True,
            "mode": mode,
            "clients": clients,
            "status": payload.get("status"),
            "bundle_dir": payload.get("bundle_dir"),
            "updated_at": utc_now(),
            "artifacts": [artifact["path"] for artifact in payload.get("artifacts", [])],
        }
    )


def _build_operation_request(
    *,
    operation: str,
    environment: ExecutionEnvironment,
    filesystem: FileSystem,
    repository: ManifestRepository,
    runtime_root: Path,
    clients: list[str],
    snapshot_id: str,
) -> dict:
    request: dict = {
        "operation": operation,
        "runtime_root": str(runtime_root),
    }
    if clients:
        request["target_clients"] = clients
    if operation in {"validate", "repair", "doctor"}:
        loader = ExakitRuntimeLoader(environment=environment, filesystem=filesystem)
        context = loader.load(runtime_root)
        request["dsn_reference"] = {"kind": "literal", "value": context.dsn}
    if operation == "repair":
        loader = ExakitRuntimeLoader(environment=environment, filesystem=filesystem)
        context = loader.load(runtime_root)
        request["deployment_mode"] = "stdio"
        request["server_definition"] = to_primitive(context.server_definition)
        request["credential_reference"] = {"kind": "inline_env", "name": "EXA_PASSWORD"}
        request["validate_after_apply"] = True
        request["create_snapshot"] = True
    if operation == "restore":
        resolved_snapshot_id = snapshot_id or repository.latest_snapshot_id()
        if not resolved_snapshot_id:
            raise MCPSubsystemError(
                "runtime_snapshot_missing",
                "No MCP snapshot is available to restore yet.",
            )
        request["snapshot_id"] = resolved_snapshot_id
    return request


def _status_from_stage_results(stages: list[StageResult]) -> OperationStatus:
    statuses = {stage.status for stage in stages}
    if "fail_blocking" in statuses:
        return OperationStatus.FAILED_TERMINAL
    if "fail_recoverable" in statuses:
        return OperationStatus.FAILED_RECOVERABLE
    if "pass_with_warnings" in statuses:
        return OperationStatus.SUCCESS_WITH_WARNINGS
    return OperationStatus.SUCCESS


def _resolve_runtime_root(raw: str, environment: ExecutionEnvironment) -> Path:
    path = Path(raw).expanduser()
    if path.is_absolute():
        return path
    return environment.home / path


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
