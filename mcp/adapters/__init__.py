"""Client adapter implementations."""

from .claude_code import ClaudeCodeAdapter
from .claude_desktop import ClaudeDesktopAdapter
from .codex import CodexAdapter
from .cursor import CursorAdapter
from .gemini_cli import GeminiCliAdapter
from .registry import AdapterRegistry
from .vscode_copilot import VSCodeCopilotAdapter

__all__ = [
    "AdapterRegistry",
    "ClaudeCodeAdapter",
    "ClaudeDesktopAdapter",
    "CodexAdapter",
    "CursorAdapter",
    "GeminiCliAdapter",
    "VSCodeCopilotAdapter",
]
