import express from "express";
import { readFileSync } from "node:fs";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";

const PROM_URL = process.env.PROM_URL || "http://10.10.50.104:9090";
const MCP_AUTH_TOKEN = readFileSync(process.env.MCP_AUTH_TOKEN_FILE || "/run/secrets/mcp_auth_token", "utf8").trim();
const PORT = process.env.PORT || 3003;

async function promApi(path, params = {}) {
  const url = new URL(`${PROM_URL}${path}`);
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== null) url.searchParams.set(k, v);
  }
  const res = await fetch(url, { signal: AbortSignal.timeout(10000) });
  const body = await res.json();
  if (!res.ok || body.status !== "success") {
    throw new Error(`Prometheus ${path} failed: ${body.error || res.statusText}`);
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
  const server = new McpServer({ name: "prometheus-mcp", version: "1.0.0" });

server.registerTool(
  "prometheus_query",
  {
    description: "Instant PromQL query against sn-monitor's central Prometheus (current value(s) of a metric/expression).",
    inputSchema: { query: z.string().describe("PromQL expression, e.g. 'up' or 'node_memory_MemAvailable_bytes{instance=\"sn-web\"}'") },
  },
  async ({ query }) => {
    try {
      return textResult(await promApi("/api/v1/query", { query }));
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "prometheus_query_range",
  {
    description: "Range PromQL query over a time window with a step interval — e.g. last 6h of a metric.",
    inputSchema: {
      query: z.string(),
      start: z.string().describe("RFC3339 timestamp or unix seconds, e.g. '2026-09-14T00:00:00Z'"),
      end: z.string().describe("RFC3339 timestamp or unix seconds"),
      step: z.string().default("60s").describe("Step interval, e.g. '60s', '5m'"),
    },
  },
  async ({ query, start, end, step }) => {
    try {
      return textResult(await promApi("/api/v1/query_range", { query, start, end, step }));
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "prometheus_alerts",
  {
    description: "List currently active/firing alerts from Prometheus's own Alertmanager-facing rule evaluation.",
    inputSchema: {},
  },
  async () => {
    try {
      return textResult(await promApi("/api/v1/alerts"));
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "prometheus_targets",
  {
    description: "List scrape target health (up/down per job/instance).",
    inputSchema: { state: z.enum(["active", "dropped", "any"]).optional() },
  },
  async ({ state }) => {
    try {
      return textResult(await promApi("/api/v1/targets", { state }));
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "prometheus_labels",
  {
    description: "List label names, or values for a specific label — useful for finding the right selector for a query.",
    inputSchema: { label: z.string().optional().describe("If given, list values for this label instead of listing label names") },
  },
  async ({ label }) => {
    try {
      const path = label ? `/api/v1/label/${encodeURIComponent(label)}/values` : "/api/v1/labels";
      return textResult(await promApi(path));
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

app.listen(PORT, "0.0.0.0", () => {
  console.log(`prometheus-mcp listening on :${PORT}`);
});
