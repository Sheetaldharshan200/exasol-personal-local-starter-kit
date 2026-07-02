"""Adapter coverage tests for documented client formats."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import tempfile
import unittest

from mcp.adapters.registry import AdapterRegistry
from mcp.core.models import DeploymentMode, ServerDefinition
from mcp.runtime.environment import ExecutionEnvironment


class AdditionalAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-adapter-tests-"))
        self._workspace = self._temp_dir / "workspace"
        self._workspace.mkdir(parents=True, exist_ok=True)
        self._environment = ExecutionEnvironment(
            os_name="darwin",
            home=self._temp_dir,
            env={
                "CURSOR_MCP_CONFIG_PATH": str(self._temp_dir / "cursor" / "mcp.json"),
                "CODEX_MCP_CONFIG_PATH": str(self._temp_dir / "codex" / "config.toml"),
                "CLAUDE_DESKTOP_CONFIG_PATH": str(
                    self._temp_dir / "claude" / "claude_desktop_config.json"
                ),
            },
            cwd=self._workspace,
        )
        self._registry = AdapterRegistry()
        self._server = ServerDefinition(
            transport=DeploymentMode.STDIO,
            name="exasol",
            command="uvx",
            args=("exasol-mcp-server@1.10.1",),
            env={"EXA_DSN": "127.0.0.1:8563", "EXA_USER": "sys"},
        )

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def test_json_backed_adapters_render_valid_documents(self) -> None:
        for adapter_id, top_level_key in (
            ("claude_desktop", "mcpServers"),
            ("cursor", "mcpServers"),
        ):
            with self.subTest(adapter=adapter_id):
                adapter = self._registry.get(adapter_id)
                location = adapter.locate(self._environment)
                inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
                rendered = adapter.render(self._server, inspection)
                findings = adapter.validate_render(rendered)
                self.assertEqual(findings, [])
                payload = json.loads(rendered.content or "{}")
                self.assertIn(top_level_key, payload)
                self.assertIn("exasol", payload[top_level_key])

    def test_codex_adapter_renders_valid_toml(self) -> None:
        adapter = self._registry.get("codex")
        location = adapter.locate(self._environment)
        inspection = adapter.inspect(location.path, "exasol")  # type: ignore[arg-type]
        rendered = adapter.render(self._server, inspection)
        findings = adapter.validate_render(rendered)
        self.assertEqual(findings, [])
        self.assertIn("[mcp_servers.exasol]", rendered.content or "")
        self.assertIn('command = "uvx"', rendered.content or "")

    def test_discover_reports_supported_adapters(self) -> None:
        for adapter_id in (
            "claude_desktop",
            "cursor",
            "codex",
        ):
            with self.subTest(adapter=adapter_id):
                adapter = self._registry.get(adapter_id)
                detection = adapter.detect(self._environment)
                self.assertTrue(detection.location.available)
                self.assertIn(detection.confidence, {"low", "medium", "high"})


if __name__ == "__main__":
    unittest.main()
