"""Execution environment helpers."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import sys


@dataclass
class ExecutionEnvironment:
    os_name: str
    home: Path
    env: dict[str, str]

    @classmethod
    def current(cls) -> "ExecutionEnvironment":
        return cls(os_name=sys.platform, home=Path.home(), env=dict(os.environ))
