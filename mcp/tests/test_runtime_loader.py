"""Failure-path tests for loading starter-kit MCP runtime state."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import tempfile
import unittest

from mcp.core.errors import MCPSubsystemError
from mcp.runtime.environment import ExecutionEnvironment
from mcp.runtime.exakit import ExakitRuntimeLoader


class RuntimeLoaderEdgeCaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-runtime-loader-"))
        self.runtime_root = self._temp_dir / "runtime"
        self.manifest_path = self.runtime_root / "manifest.json"
        self.password_file = self.runtime_root / "credentials" / "db_password"
        self.mcp_password_file = self.runtime_root / "credentials" / "mcp_password"
        self.password_file.parent.mkdir(parents=True, exist_ok=True)
        self.password_file.write_text("admin-secret\n", encoding="utf-8")
        self.mcp_password_file.write_text("readonly-secret\n", encoding="utf-8")
        self.runtime_root.mkdir(parents=True, exist_ok=True)
        self.loader = ExakitRuntimeLoader(
            environment=ExecutionEnvironment(os_name="darwin", home=self._temp_dir, env={}),
        )

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def test_load_requires_mcp_connection_block(self) -> None:
        self._write_manifest(components={})
        with self.assertRaises(MCPSubsystemError) as ctx:
            self.loader.load(self.runtime_root)
        self.assertEqual(ctx.exception.code, "runtime_mcp_connection_missing")

    def test_load_requires_validated_mcp_connection(self) -> None:
        self._write_manifest(
            components={
                "mcp_server": {
                    "connection": {
                        "user": "mcp_readonly",
                        "password_file": str(self.mcp_password_file),
                        "validated": False,
                    }
                }
            }
        )
        with self.assertRaises(MCPSubsystemError) as ctx:
            self.loader.load(self.runtime_root)
        self.assertEqual(ctx.exception.code, "runtime_mcp_connection_unvalidated")

    def test_load_rejects_admin_user_as_mcp_connection(self) -> None:
        self._write_manifest(
            components={
                "mcp_server": {
                    "connection": {
                        "user": "sys",
                        "password_file": str(self.password_file),
                        "validated": True,
                    }
                }
            }
        )
        with self.assertRaises(MCPSubsystemError) as ctx:
            self.loader.load(self.runtime_root)
        self.assertEqual(ctx.exception.code, "runtime_mcp_connection_not_isolated")

    def test_load_rejects_incomplete_mcp_connection(self) -> None:
        self._write_manifest(
            components={
                "mcp_server": {
                    "connection": {
                        "user": "mcp_readonly",
                        "validated": True,
                    }
                }
            }
        )
        with self.assertRaises(MCPSubsystemError) as ctx:
            self.loader.load(self.runtime_root)
        self.assertEqual(ctx.exception.code, "runtime_mcp_connection_incomplete")

    def _write_manifest(self, *, components: dict) -> None:
        manifest = {
            "manifest_version": 1,
            "kit_level": 1,
            "runtime": {
                "type": "personal",
                "dsn": "127.0.0.1:8563",
                "user": "sys",
                "password_file": str(self.password_file),
            },
            "components": components,
            "steps_completed": ["runtime", "mcp_server"],
        }
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
