"""Client adapter implementations."""

from .claude_desktop import ClaudeDesktopAdapter
from .registry import AdapterRegistry

__all__ = ["AdapterRegistry", "ClaudeDesktopAdapter"]
