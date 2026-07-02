"""Runtime path conventions."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass
class RuntimePaths:
    runtime_root: Path

    @property
    def manifest_path(self) -> Path:
        return self.runtime_root / "manifest.json"

    @property
    def mcp_dir(self) -> Path:
        return self.runtime_root / "mcp"

    @property
    def backups_dir(self) -> Path:
        return self.runtime_root / "backups"

    @property
    def logs_dir(self) -> Path:
        return self.runtime_root / "logs"

    def ensure(self) -> None:
        self.runtime_root.mkdir(parents=True, exist_ok=True)
        self.mcp_dir.mkdir(parents=True, exist_ok=True)
        self.backups_dir.mkdir(parents=True, exist_ok=True)
        self.logs_dir.mkdir(parents=True, exist_ok=True)
