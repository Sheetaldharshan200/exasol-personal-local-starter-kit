-- Starter-kit baseline for a dedicated MCP-safe database user.
-- The installer replaces {{MCP_PASSWORD}} with the generated password stored at
-- ~/.exasol-starter-kit/credentials/mcp_readonly_password.
-- For manual use, replace {{MCP_PASSWORD}} with your own strong password token.
CREATE USER mcp_readonly IDENTIFIED BY {{MCP_PASSWORD}};
GRANT CREATE SESSION TO mcp_readonly;
GRANT SELECT ON SCHEMA STARTER_KIT TO mcp_readonly;
