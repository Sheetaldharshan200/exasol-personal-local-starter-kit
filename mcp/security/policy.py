"""Local security and safety checks."""

from __future__ import annotations

from pathlib import Path
import stat
from urllib.parse import urlparse

from mcp.core.models import DeploymentMode, Finding, OperationRequest, Severity


class SecurityPolicy:
    """Enforce safe-by-default request and file behavior."""

    def preflight(self, request: OperationRequest) -> list[Finding]:
        findings: list[Finding] = []
        if request.operation.value in {"configure", "repair"} and request.server_definition is None:
            findings.append(
                Finding(
                    code="missing_server_definition",
                    severity=Severity.ERROR,
                    message="Mutating client configuration requires a server definition.",
                    recommended_action="Provide a transport-specific server definition from the upstream installer.",
                    blocking=True,
                )
            )
            return findings
        if request.server_definition is None:
            return findings
        if request.server_definition.transport != request.deployment_mode:
            findings.append(
                Finding(
                    code="deployment_mode_mismatch",
                    severity=Severity.ERROR,
                    message="The request deployment mode does not match the server definition transport.",
                    recommended_action="Align deployment_mode with server_definition.transport.",
                    blocking=True,
                )
            )
        if request.server_definition.transport == DeploymentMode.STDIO:
            if not request.server_definition.command:
                findings.append(
                    Finding(
                        code="missing_server_command",
                        severity=Severity.ERROR,
                        message="A stdio server definition requires a command.",
                        recommended_action="Populate server_definition.command.",
                        blocking=True,
                    )
                )
        if request.server_definition.transport == DeploymentMode.HTTP:
            parsed = urlparse(request.server_definition.url or "")
            if parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
                findings.append(
                    Finding(
                        code="unsafe_http_target",
                        severity=Severity.CRITICAL,
                        message="HTTP deployment must target a loopback address by default.",
                        evidence=[request.server_definition.url or "<missing-url>"],
                        recommended_action="Bind the MCP HTTP endpoint to localhost and retry.",
                        blocking=True,
                    )
                )
        if request.credential_reference and request.credential_reference.kind == "literal":
            findings.append(
                Finding(
                    code="plaintext_credential_reference",
                    severity=Severity.WARNING,
                    message="Literal credentials increase the risk of local secret exposure.",
                    recommended_action="Prefer an environment-backed or external credential reference.",
                )
            )
        return findings

    def apply_managed_permissions(self, path: Path) -> str | None:
        if path.exists() and path.is_file() and hasattr(path, "chmod"):
            path.chmod(stat.S_IRUSR | stat.S_IWUSR)
            return format(stat.S_IMODE(path.stat().st_mode), "04o")
        return None
