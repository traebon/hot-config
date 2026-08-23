# uptimerobot-mcp

Standalone MCP server giving JARVIS (Claude Code on the Gateway) direct read access to UptimeRobot
— the external monitor covering Gateway/hot-pn/hot-erp-nl (see
`docs/HoT_Gateway_External_Monitoring_Scope.md` section 7 for the full build/verification detail).
Deliberately separate from PrivateNexus's own MCP server — Mr. Byrne's explicit call.

## Rebuild from scratch

```
apt-get install -y python3.14-venv   # or whatever python3.X-venv matches the current python3
python3 -m venv /opt/mcp-servers/uptimerobot/venv
/opt/mcp-servers/uptimerobot/venv/bin/pip install mcp
mkdir -p /opt/mcp-servers/uptimerobot
cp server.py /opt/mcp-servers/uptimerobot/server.py
mkdir -p /etc/uptimerobot-mcp
# API key: Vaultwarden — "UptimeRobot Main API Key (Gateway/hot-pn/hot-erp-nl external monitoring)",
# House of Trae — Gateway VPS folder. Write it to /etc/uptimerobot-mcp/api_key.txt, chmod 600.
claude mcp add uptimerobot -e UPTIMEROBOT_API_KEY_FILE=/etc/uptimerobot-mcp/api_key.txt \
  -- /opt/mcp-servers/uptimerobot/venv/bin/python3 /opt/mcp-servers/uptimerobot/server.py
```

Note on the `mcp` SDK: as of v2.0.0 the decorator API is `mcp.server.MCPServer`, not
`mcp.server.fastmcp.FastMCP` (that import path doesn't exist in this version) — check
`dir(mcp.server.MCPServer)` if this ever breaks after an SDK upgrade.
