-- Starter-kit baseline for a dedicated MCP-safe database user.
-- Replace the password before running manually in another environment.
CREATE USER mcp_readonly IDENTIFIED BY 'replace-with-a-strong-password';
GRANT CREATE SESSION TO mcp_readonly;
GRANT SELECT ON SCHEMA STARTER_KIT TO mcp_readonly;
