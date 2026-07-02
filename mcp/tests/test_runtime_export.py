"""Tests for exporting starter-kit MCP client bundles."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class RuntimeExportTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-runtime-export-"))
        self.runtime_root = self._temp_dir / "runtime"
        self.password_file = self.runtime_root / "credentials" / "db_password"
        self.mcp_password_file = self.runtime_root / "credentials" / "mcp_password"
        self.password_file.parent.mkdir(parents=True, exist_ok=True)
        self.password_file.write_text("starter-secret\n", encoding="utf-8")
        self.mcp_password_file.write_text("readonly-secret\n", encoding="utf-8")
        manifest = {
            "manifest_version": 1,
            "kit_level": 1,
            "runtime": {
                "type": "personal",
                "dsn": "127.0.0.1:8563",
                "user": "sys",
                "password_file": str(self.password_file),
            },
            "components": {
                "mcp_server": {
                    "connection": {
                        "user": "mcp_readonly",
                        "password_file": str(self.mcp_password_file),
                        "validated": True,
                    }
                }
            },
            "steps_completed": ["runtime", "mcp_server"],
        }
        self.runtime_root.mkdir(parents=True, exist_ok=True)
        (self.runtime_root / "manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        shutil.rmtree(self._temp_dir, ignore_errors=True)

    def test_cli_exports_all_client_bundles(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "mcp",
                "export-runtime-configs",
                "--runtime-root",
                str(self.runtime_root),
            ],
            cwd=Path(__file__).resolve().parents[2],
            check=True,
            capture_output=True,
            text=True,
        )
        output = json.loads(result.stdout)
        self.assertEqual(output["runtime_root"], str(self.runtime_root))
        self.assertIn("codex", output["exported_clients"])

        mcp_dir = self.runtime_root / "mcp"
        expected_files = {
            "claude-config.json",
            "cursor-mcp.json",
            "codex-config.toml",
            "bundle-index.json",
        }
        self.assertEqual(expected_files, {path.name for path in mcp_dir.iterdir()})

        claude = json.loads((mcp_dir / "claude-config.json").read_text(encoding="utf-8"))
        self.assertEqual(claude["mcpServers"]["exasol"]["command"], "uvx")
        self.assertEqual(claude["mcpServers"]["exasol"]["args"], ["exasol-mcp-server@1.10.1"])
        self.assertEqual(claude["mcpServers"]["exasol"]["env"]["EXA_DSN"], "127.0.0.1:8563")
        self.assertEqual(claude["mcpServers"]["exasol"]["env"]["EXA_USER"], "mcp_readonly")

        codex = (mcp_dir / "codex-config.toml").read_text(encoding="utf-8")
        self.assertIn("[mcp_servers.exasol]", codex)
        self.assertIn('command = "uvx"', codex)
        self.assertIn('EXA_PASSWORD = "readonly-secret"', codex)

        manifest = json.loads((self.runtime_root / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["runtime"]["dsn"], "127.0.0.1:8563")
        self.assertIn("mcp_server", manifest["components"])
        self.assertIn("claude-config.json", manifest["components"]["mcp_server"]["configs"])
        managed_state = manifest["components"]["mcp_server"]["managed_state"]
        self.assertEqual(len(managed_state["artifacts"]), 3)
        self.assertEqual(
            sorted(artifact["client"] for artifact in managed_state["artifacts"]),
            [
                "claude_desktop",
                "codex",
                "cursor",
            ],
        )


if __name__ == "__main__":
    unittest.main()
