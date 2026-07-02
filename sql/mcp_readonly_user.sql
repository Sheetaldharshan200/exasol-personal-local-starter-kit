-- Reference baseline for the dedicated MCP-safe database user.
-- The installer provisions and posture-checks this user automatically
-- (exakit_configure_mcp_readonly_access in setup/lib/common.sh); this file
-- documents the equivalent grants for manual setups.
-- For manual use, replace {{MCP_PASSWORD}} with your own strong password token.
CREATE USER mcp_readonly IDENTIFIED BY {{MCP_PASSWORD}};
GRANT CREATE SESSION TO mcp_readonly;
GRANT SELECT ON SCHEMA STARTER_KIT TO mcp_readonly;
