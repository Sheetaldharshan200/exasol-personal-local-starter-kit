"""Export ready-to-merge MCP client configuration files for the starter kit."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
from typing import Iterable

from mcp.core.models import ArtifactReference, OwnershipState, ServerDefinition
from mcp.core.serialization import sha256_text
from mcp.security.policy import SecurityPolicy

from .exakit import ExakitRuntimeContext
from .filesystem import FileSystem
from .manifest import ManifestRepository
from .paths import RuntimePaths


ALL_CLIENT_IDS = (
    "claude_desktop",
    "cursor",
    "codex",
)

SETUP_CLIENT_IDS = ALL_CLIENT_IDS


@dataclass
class ExportedClientConfig:
    client: str
    path: Path
    content: str
    description: str


class RuntimeMCPConfigExporter:
    """Render and persist client-specific config files under the kit runtime."""

    def __init__(
        self,
        paths: RuntimePaths,
        manifest_repository: ManifestRepository,
        filesystem: FileSystem | None = None,
    ) -> None:
        self._paths = paths
        self._manifest_repository = manifest_repository
        self._filesystem = filesystem or FileSystem()
        self._security = SecurityPolicy()

    def export(
        self,
        context: ExakitRuntimeContext,
        clients: Iterable[str] | None = None,
    ) -> list[ArtifactReference]:
        self._paths.ensure()
        exported = [
            self._render_client_config(client_id, context.server_definition)
            for client_id in (tuple(clients) if clients else ALL_CLIENT_IDS)
        ]
        artifacts: list[ArtifactReference] = []
        for item in exported:
            self._filesystem.write_text(item.path, item.content)
            permissions = self._security.apply_managed_permissions(item.path)
            artifact = ArtifactReference(
                artifact_id="",
                path=str(item.path),
                kind="client_config",
                ownership_state=OwnershipState.MANAGED,
                client=item.client,
                content_hash=sha256_text(item.content),
                permissions=permissions,
                source_adapter="runtime_exporter",
                metadata={
                    "entry_name": context.server_definition.name,
                    "description": item.description,
                    "dsn": context.dsn,
                    "user": context.user,
                },
            )
            artifacts.append(self._manifest_repository.upsert_artifact(artifact))
        self._write_bundle_index(exported)
        return artifacts

    def _render_client_config(
        self,
        client_id: str,
        server_definition: ServerDefinition,
    ) -> ExportedClientConfig:
        server_name = server_definition.name
        if client_id == "claude_desktop":
            return ExportedClientConfig(
                client=client_id,
                path=self._paths.mcp_dir / "claude-config.json",
                content=self._json_document({"mcpServers": {server_name: self._stdio_entry(server_definition)}}),
                description="Claude Desktop config fragment",
            )
        if client_id == "cursor":
            return ExportedClientConfig(
                client=client_id,
                path=self._paths.mcp_dir / "cursor-mcp.json",
                content=self._json_document({"mcpServers": {server_name: self._stdio_entry(server_definition)}}),
                description="Cursor mcp.json fragment",
            )
        if client_id == "codex":
            return ExportedClientConfig(
                client=client_id,
                path=self._paths.mcp_dir / "codex-config.toml",
                content=self._codex_toml(server_definition),
                description="Codex config.toml fragment",
            )
        raise ValueError(f"Unsupported client export '{client_id}'.")

    @staticmethod
    def _stdio_entry(server_definition: ServerDefinition) -> dict:
        entry = {
            "command": server_definition.command,
            "args": list(server_definition.args),
        }
        if server_definition.env:
            entry["env"] = dict(server_definition.env)
        return entry

    @staticmethod
    def _json_document(payload: dict) -> str:
        return json.dumps(payload, indent=2, sort_keys=True) + "\n"

    def _codex_toml(self, server_definition: ServerDefinition) -> str:
        args = ", ".join(self._toml_quote(argument) for argument in server_definition.args)
        env_lines = "\n".join(
            f"{key} = {self._toml_quote(value)}"
            for key, value in sorted(server_definition.env.items())
        )
        return (
            f"[mcp_servers.{server_definition.name}]\n"
            f"command = {self._toml_quote(server_definition.command or '')}\n"
            f"args = [{args}]\n"
            "\n"
            f"[mcp_servers.{server_definition.name}.env]\n"
            f"{env_lines}\n"
        )

    @staticmethod
    def _toml_quote(value: str) -> str:
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f"\"{escaped}\""

    def _write_bundle_index(self, exported: list[ExportedClientConfig]) -> None:
        index_path = self._paths.mcp_dir / "bundle-index.json"
        payload = {
            "clients": [
                {
                    "client": item.client,
                    "path": str(item.path),
                    "description": item.description,
                }
                for item in exported
            ]
        }
        self._filesystem.write_json(index_path, payload)
