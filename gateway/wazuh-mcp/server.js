import express from "express";
import { readFileSync } from "node:fs";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";

const MANAGER_URL = process.env.WAZUH_MANAGER_URL || "https://10.10.70.106:55000";
const INDEXER_URL = process.env.WAZUH_INDEXER_URL || "https://10.10.70.106:9200";
const API_USER = readFileSync(process.env.WAZUH_API_USER_FILE || "/run/secrets/wazuh_api_user", "utf8").trim();
const API_PASS = readFileSync(process.env.WAZUH_API_PASS_FILE || "/run/secrets/wazuh_api_pass", "utf8").trim();
const INDEXER_USER = readFileSync(process.env.WAZUH_INDEXER_USER_FILE || "/run/secrets/wazuh_indexer_user", "utf8").trim();
const INDEXER_PASS = readFileSync(process.env.WAZUH_INDEXER_PASS_FILE || "/run/secrets/wazuh_indexer_pass", "utf8").trim();
const MCP_AUTH_TOKEN = readFileSync(process.env.MCP_AUTH_TOKEN_FILE || "/run/secrets/mcp_auth_token", "utf8").trim();
const PORT = process.env.PORT || 3007;
const ALERTS_INDEX_PATTERN = "wazuh-alerts-4.x-*";

// Internal, self-signed certs on both the manager API and the OpenSearch indexer.
process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

let cachedToken = null;
let tokenExpiresAt = 0;

async function getManagerToken() {
  if (cachedToken && Date.now() < tokenExpiresAt) return cachedToken;
  const res = await fetch(`${MANAGER_URL}/security/user/authenticate`, {
    method: "POST",
    headers: { Authorization: `Basic ${Buffer.from(`${API_USER}:${API_PASS}`).toString("base64")}` },
    signal: AbortSignal.timeout(10000),
  });
  const body = await res.json();
  if (!res.ok || !body.data?.token) {
    throw new Error(`Wazuh manager auth failed: ${JSON.stringify(body)}`);
  }
  cachedToken = body.data.token;
  tokenExpiresAt = Date.now() + 13 * 60 * 1000; // JWT is ~15min; refresh a bit early
  return cachedToken;
}

async function managerApi(path) {
  const token = await getManagerToken();
  const res = await fetch(`${MANAGER_URL}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(10000),
  });
  const body = await res.json();
  if (!res.ok) {
    throw new Error(`Wazuh manager API ${res.status} on ${path}: ${JSON.stringify(body)}`);
  }
  return body.data;
}

async function indexerSearch(body) {
  const res = await fetch(`${INDEXER_URL}/${ALERTS_INDEX_PATTERN}/_search`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${Buffer.from(`${INDEXER_USER}:${INDEXER_PASS}`).toString("base64")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10000),
  });
  const data = await res.json();
  if (!res.ok) {
    throw new Error(`Wazuh indexer search failed: ${JSON.stringify(data)}`);
  }
  return data;
}

function textResult(data) {
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
}

function errorResult(err) {
  return { content: [{ type: "text", text: `Error: ${err.message}` }], isError: true };
}

function buildServer() {
  const server = new McpServer({ name: "wazuh-mcp", version: "1.0.0" });

  server.registerTool(
    "wazuh_get_agents",
    {
      description: "List all Wazuh-enrolled agents with connection status, OS, and version.",
      inputSchema: { status: z.enum(["active", "disconnected", "never_connected", "pending"]).optional() },
    },
    async ({ status }) => {
      try {
        const qs = status ? `?status=${status}` : "";
        return textResult(await managerApi(`/agents${qs}`));
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "wazuh_get_agent",
    {
      description: "Details for one agent by ID (last keepalive, version, OS).",
      inputSchema: { agent_id: z.string().describe("Wazuh agent ID, e.g. '001'") },
    },
    async ({ agent_id }) => {
      try {
        return textResult(await managerApi(`/agents?agents_list=${encodeURIComponent(agent_id)}`));
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "wazuh_query_alerts",
    {
      description:
        "Query recent Wazuh alerts from the OpenSearch indexer, optionally filtered by minimum rule level, " +
        "rule ID, or agent name.",
      inputSchema: {
        hours: z.number().int().default(24).describe("How far back to search"),
        min_level: z.number().int().optional(),
        rule_id: z.string().optional(),
        agent_name: z.string().optional(),
        size: z.number().int().default(50).describe("Max alerts to return"),
      },
    },
    async ({ hours, min_level, rule_id, agent_name, size }) => {
      try {
        const filter = [{ range: { "@timestamp": { gte: `now-${hours}h` } } }];
        if (min_level) filter.push({ range: { "rule.level": { gte: min_level } } });
        if (rule_id) filter.push({ term: { "rule.id": rule_id } });
        if (agent_name) filter.push({ term: { "agent.name": agent_name } });
        const data = await indexerSearch({
          size,
          sort: [{ "@timestamp": "desc" }],
          query: { bool: { filter } },
          _source: ["@timestamp", "agent.name", "rule.id", "rule.level", "rule.description"],
        });
        const hits = data.hits.hits.map((h) => h._source);
        return textResult({ total: data.hits.total.value, returned: hits.length, alerts: hits });
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "wazuh_get_alert_summary",
    {
      description: "Count of alerts by rule level over the last N hours.",
      inputSchema: { hours: z.number().int().default(24) },
    },
    async ({ hours }) => {
      try {
        const data = await indexerSearch({
          size: 0,
          query: { bool: { filter: [{ range: { "@timestamp": { gte: `now-${hours}h` } } }] } },
          aggs: { by_level: { terms: { field: "rule.level", size: 20, order: { _key: "desc" } } } },
        });
        return textResult({
          totalAlerts: data.hits.total.value,
          byLevel: data.aggregations.by_level.buckets.map((b) => ({ level: b.key, count: b.doc_count })),
        });
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "wazuh_get_top_rules",
    {
      description: "Top triggered rules over the last N hours.",
      inputSchema: { hours: z.number().int().default(24), limit: z.number().int().default(10) },
    },
    async ({ hours, limit }) => {
      try {
        const data = await indexerSearch({
          size: 0,
          query: { bool: { filter: [{ range: { "@timestamp": { gte: `now-${hours}h` } } }] } },
          aggs: {
            by_rule: {
              terms: { field: "rule.id", size: limit, order: { _count: "desc" } },
              aggs: { sample: { top_hits: { size: 1, _source: ["rule.description", "rule.level"] } } },
            },
          },
        });
        const buckets = data.aggregations.by_rule.buckets.map((b) => ({
          ruleId: b.key,
          count: b.doc_count,
          description: b.sample.hits.hits[0]?._source?.rule?.description,
          level: b.sample.hits.hits[0]?._source?.rule?.level,
        }));
        return textResult(buckets);
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
  console.log(`wazuh-mcp listening on :${PORT}`);
});
