import express from "express";
import { readFileSync } from "node:fs";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";

// Routed over Tailscale, not wg4 — hot-bm-nl's UFW only allows 8006 from tailscale0 or
// hot-pn's own wg3 IP (its PrivateNexus health check), not the Gateway's wg4 address. This
// matches the documented purpose of the Gateway<->hot-bm-nl Tailscale link (admin/Proxmox-UI
// access) rather than opening a new wg4 UFW hole for it.
const PVE_URL = process.env.PVE_URL || "https://100.90.156.88:8006/api2/json";
const PVE_TOKEN_ID = process.env.PVE_TOKEN_ID || "jarvis@pve!mcp";
const PVE_TOKEN_SECRET = readFileSync(process.env.PVE_TOKEN_SECRET_FILE || "/run/secrets/pve_token_secret", "utf8").trim();
// Proxmox's own node name is "proxmox22272" (Hostkey's own hostname), not "hot-bm-nl" —
// confirmed live via /api2/json/nodes, don't assume the project's own alias matches the PVE node id.
const NODE = process.env.PVE_NODE || "proxmox22272";
const MCP_AUTH_TOKEN = readFileSync(process.env.MCP_AUTH_TOKEN_FILE || "/run/secrets/mcp_auth_token", "utf8").trim();
const PORT = process.env.PORT || 3006;
const LISTEN_HOST = process.env.LISTEN_HOST || "0.0.0.0";

// Internal, self-signed Proxmox cert — same tradeoff already documented in
// docs/HoT_JARVIS_MCP_Expansion_Scope.md 3.6 (internal-only, acceptable).
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

async function pveApi(path) {
  const res = await fetch(`${PVE_URL}${path}`, {
    headers: { Authorization: `PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}` },
    signal: AbortSignal.timeout(10000),
  });
  const body = await res.json();
  if (!res.ok) {
    throw new Error(`Proxmox API ${res.status} on ${path}: ${JSON.stringify(body)}`);
  }
  return body.data;
}

function textResult(data) {
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
}

function errorResult(err) {
  return { content: [{ type: "text", text: `Error: ${err.message}` }], isError: true };
}

function buildServer() {
  const server = new McpServer({ name: "proxmox-mcp", version: "1.0.0" });

  server.registerTool(
    "proxmox_list_vms",
    {
      description: `List all VMs on the ${NODE} Proxmox node — status, uptime, and resource config.`,
      inputSchema: {},
    },
    async () => {
      try {
        return textResult(await pveApi(`/nodes/${NODE}/qemu`));
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "proxmox_get_vm",
    {
      description: "Detailed current status for one VM (CPU, RAM, disk usage) by VMID.",
      inputSchema: { vmid: z.number().int().describe("VM ID, e.g. 100 for sn-infra, 102 sn-web, 104 sn-monitor, 106 sn-security") },
    },
    async ({ vmid }) => {
      try {
        return textResult(await pveApi(`/nodes/${NODE}/qemu/${vmid}/status/current`));
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "proxmox_get_node_resources",
    {
      description: `Host-level resource usage for ${NODE} (RAM, CPU, ZFS/local-zfs pool).`,
      inputSchema: {},
    },
    async () => {
      try {
        const [status, storage] = await Promise.all([
          pveApi(`/nodes/${NODE}/status`),
          pveApi(`/nodes/${NODE}/storage`),
        ]);
        return textResult({ status, storage });
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "proxmox_list_snapshots",
    {
      description: "List snapshots for a VM by VMID.",
      inputSchema: { vmid: z.number().int() },
    },
    async ({ vmid }) => {
      try {
        return textResult(await pveApi(`/nodes/${NODE}/qemu/${vmid}/snapshot`));
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "proxmox_list_backups",
    {
      description: `List PBS/vzdump backup records on ${NODE}, optionally filtered to one VM.`,
      inputSchema: {
        storage: z.string().default("pbs-hot").describe("Storage ID, e.g. 'pbs-hot' or 'local-backup-zfs'"),
        vmid: z.number().int().optional(),
      },
    },
    async ({ storage, vmid }) => {
      try {
        const data = await pveApi(`/nodes/${NODE}/storage/${storage}/content?content=backup`);
        const filtered = vmid ? data.filter((b) => b.vmid === vmid) : data;
        return textResult(filtered);
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  return server;
}

const app = express();
app.use(express.json());

app.use((req, res, next) => {
  const auth = req.headers.authorization || "";
  if (auth !== `Bearer ${MCP_AUTH_TOKEN}`) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }
  next();
});

app.post("/mcp", async (req, res) => {
  const mcpServer = buildServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => {
    transport.close();
    mcpServer.close();
  });
  await mcpServer.connect(transport);
  await transport.handleRequest(req, res, req.body);
});

app.listen(PORT, LISTEN_HOST, () => {
  console.log(`proxmox-mcp listening on ${LISTEN_HOST}:${PORT}`);
});
