"""End-to-end tests for MCP lifecycle operations."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

from mcp.core.models import OperationStatus
from mcp.runtime.environment import ExecutionEnvironment
from mcp.service import MCPAccessSubsystem


class MCPSubsystemLifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-subsystem-tests-"))
        self.runtime_root = self._temp_dir / "runtime"
        self.config_path = self._temp_dir / "claude" / "claude_desktop_config.json"
        self.environment = ExecutionEnvironment(
            os_name="darwin",
            home=self._temp_dir,
            env={"CLAUDE_DESKTOP_CONFIG_PATH": str(self.config_path)},
        )
        self.subsystem = MCPAccessSubsystem(environment=self.environment)

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def test_full_lifecycle_flow(self) -> None:
        with self._mock_connectivity():
            configure = self.subsystem.execute(self._base_request("configure"))
            self.assertEqual(configure.status, OperationStatus.SUCCESS)
            self.assertTrue(self.config_path.exists())
            config_doc = json.loads(self.config_path.read_text(encoding="utf-8"))
            self.assertIn("exasol", config_doc["mcpServers"])
            self.assertEqual(config_doc["mcpServers"]["exasol"]["command"], "exasol-mcp-server")

            discover = self.subsystem.execute(self._base_request("discover"))
            self.assertEqual(discover.status, OperationStatus.SUCCESS)
            discovered = discover.details["discovered_clients"][0]
            self.assertTrue(discovered["detected"])

            validate = self.subsystem.execute(self._base_request("validate"))
            self.assertEqual(validate.status, OperationStatus.SUCCESS)
            self.assertGreaterEqual(len(validate.verification_evidence), 4)

            backup = self.subsystem.execute(self._base_request("backup"))
            self.assertEqual(backup.status, OperationStatus.SUCCESS)
            snapshot_id = backup.details["snapshot_id"]

            drifted = json.loads(self.config_path.read_text(encoding="utf-8"))
            drifted["mcpServers"]["exasol"]["command"] = "unexpected-binary"
            self.config_path.write_text(json.dumps(drifted, indent=2) + "\n", encoding="utf-8")

            drift_validate = self.subsystem.execute(self._base_request("validate"))
            self.assertEqual(drift_validate.status, OperationStatus.FAILED_RECOVERABLE)

            repair = self.subsystem.execute(self._base_request("repair"))
            self.assertEqual(repair.status, OperationStatus.SUCCESS)
            repaired_doc = json.loads(self.config_path.read_text(encoding="utf-8"))
            self.assertEqual(repaired_doc["mcpServers"]["exasol"]["command"], "exasol-mcp-server")

            status = self.subsystem.execute(self._base_request("status"))
            self.assertEqual(status.status, OperationStatus.SUCCESS)
            self.assertEqual(len(status.artifacts), 1)

            doctor = self.subsystem.execute(self._base_request("doctor"))
            self.assertIn(doctor.status, {OperationStatus.SUCCESS, OperationStatus.SUCCESS_WITH_WARNINGS})

            restore_source = json.loads(self.config_path.read_text(encoding="utf-8"))
            restore_source["mcpServers"]["exasol"]["args"] = ["--broken"]
            self.config_path.write_text(
                json.dumps(restore_source, indent=2) + "\n", encoding="utf-8"
            )
            restore = self.subsystem.execute(
                {
                    **self._base_request("restore"),
                    "snapshot_id": snapshot_id,
                }
            )
            self.assertEqual(restore.status, OperationStatus.SUCCESS)
            restored_doc = json.loads(self.config_path.read_text(encoding="utf-8"))
            self.assertEqual(restored_doc["mcpServers"]["exasol"]["args"], ["--profile", "starter-kit"])

            uninstall = self.subsystem.execute(self._base_request("uninstall"))
            self.assertEqual(uninstall.status, OperationStatus.SUCCESS)
            self.assertFalse(self.config_path.exists())

    def test_uninstall_preserves_unmanaged_servers(self) -> None:
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        self.config_path.write_text(
            json.dumps(
                {
                    "mcpServers": {
                        "filesystem": {
                            "command": "npx",
                            "args": ["-y", "@modelcontextprotocol/server-filesystem"],
                        }
                    }
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        with self._mock_connectivity():
            configure = self.subsystem.execute(self._base_request("configure"))
            self.assertEqual(configure.status, OperationStatus.SUCCESS)
            uninstall = self.subsystem.execute(self._base_request("uninstall"))
            self.assertEqual(uninstall.status, OperationStatus.SUCCESS)
            remaining = json.loads(self.config_path.read_text(encoding="utf-8"))
            self.assertIn("filesystem", remaining["mcpServers"])
            self.assertNotIn("exasol", remaining["mcpServers"])

    def test_install_is_explicitly_blocked(self) -> None:
        result = self.subsystem.execute(self._base_request("install"))
        self.assertEqual(result.status, OperationStatus.BLOCKED)

    def _base_request(self, operation: str) -> dict:
        return {
            "operation": operation,
            "target_clients": ["claude_desktop"],
            "deployment_mode": "stdio",
            "runtime_root": str(self.runtime_root),
            "server_definition": {
                "name": "exasol",
                "transport": "stdio",
                "command": "exasol-mcp-server",
                "args": ["--profile", "starter-kit"],
                "env": {
                    "EXASOL_DSN": "127.0.0.1:8563",
                    "EXASOL_USER": "exa_readonly",
                },
            },
            "credential_reference": {"kind": "inline_env", "name": "EXASOL_PASSWORD"},
            "dsn_reference": {"kind": "literal", "value": "127.0.0.1:8563"},
            "create_snapshot": True,
            "validate_after_apply": True,
        }

    def _mock_connectivity(self):
        connection = mock.MagicMock()
        connection.__enter__.return_value = connection
        connection.__exit__.return_value = False
        return mock.patch("mcp.validator.service.socket.create_connection", return_value=connection)


if __name__ == "__main__":
    unittest.main()
