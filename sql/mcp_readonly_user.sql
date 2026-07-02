-- Starter-kit baseline for a dedicated MCP-safe database user.
-- Replace the password before running manually in another environment.
CREATE USER mcp_readonly IDENTIFIED BY ReplaceWithAStrongPassword1;
GRANT CREATE SESSION TO mcp_readonly;
GRANT SELECT ON SCHEMA STARTER_KIT TO mcp_readonly;
