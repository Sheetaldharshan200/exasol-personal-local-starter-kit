"""Filesystem primitives used by runtime services."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import stat

from mcp.core.serialization import sha256_text


class FileSystem:
    """Small wrapper around common filesystem operations."""

    def ensure_dir(self, path: Path) -> None:
        path.mkdir(parents=True, exist_ok=True)

    def write_text(self, path: Path, content: str) -> None:
        self.ensure_dir(path.parent)
        path.write_text(content, encoding="utf-8")

    def read_text(self, path: Path) -> str:
        return path.read_text(encoding="utf-8")

    def read_json(self, path: Path) -> dict:
        return json.loads(self.read_text(path))

    def remove_file(self, path: Path) -> None:
        if path.exists():
            path.unlink()

    def copy_file(self, source: Path, target: Path) -> None:
        self.ensure_dir(target.parent)
        shutil.copy2(source, target)

    def exists(self, path: Path) -> bool:
        return path.exists()

    def hash_file(self, path: Path) -> str:
        return sha256_text(self.read_text(path))

    def mode_string(self, path: Path) -> str | None:
        if not path.exists():
            return None
        return format(stat.S_IMODE(path.stat().st_mode), "04o")

    def prune_empty_parents(self, path: Path, stop_at: Path) -> None:
        current = path
        while current != stop_at and current.exists():
            try:
                current.rmdir()
            except OSError:
                break
            current = current.parent
