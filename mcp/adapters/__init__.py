"""Client adapter implementations."""

from .claude_desktop import ClaudeDesktopAdapter
from .codex import CodexAdapter
from .cursor import CursorAdapter
from .registry import AdapterRegistry

__all__ = [
    "AdapterRegistry",
    "ClaudeDesktopAdapter",
    "CodexAdapter",
    "CursorAdapter",
]
