import express from "express";
import { readFileSync } from "node:fs";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";

const FORGEJO_URL = process.env.FORGEJO_URL || "http://10.10.10.100:3000";
const FORGEJO_TOKEN = readFileSync(process.env.FORGEJO_TOKEN_FILE || "/run/secrets/forgejo_token", "utf8").trim();
const MCP_AUTH_TOKEN = readFileSync(process.env.MCP_AUTH_TOKEN_FILE || "/run/secrets/mcp_auth_token", "utf8").trim();
const PORT = process.env.PORT || 3004;

async function forgejoApi(path, opts = {}) {
  const res = await fetch(`${FORGEJO_URL}/api/v1${path}`, {
    ...opts,
    headers: {
      Authorization: `token ${FORGEJO_TOKEN}`,
      "Content-Type": "application/json",
      ...(opts.headers || {}),
    },
  });
  const text = await res.text();
  let body;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  if (!res.ok) {
    throw new Error(`Forgejo API ${res.status} on ${path}: ${typeof body === "string" ? body : JSON.stringify(body)}`);
  }
  return body;
}

function textResult(data) {
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
}

function buildServer() {
  const server = new McpServer({ name: "forgejo-mcp", version: "1.0.0" });

  server.registerTool(
    "forgejo_list_repos",
    {
      description: "List repositories for a Forgejo owner (user or org).",
      inputSchema: { owner: z.string().describe("Username or org name, e.g. 'tristian'") },
    },
    async ({ owner }) => textResult(await forgejoApi(`/users/${encodeURIComponent(owner)}/repos`))
  );

  server.registerTool(
    "forgejo_create_issue",
    {
      description: "Create an issue in a Forgejo repo.",
      inputSchema: {
        owner: z.string(),
        repo: z.string(),
        title: z.string(),
        body: z.string().optional(),
        labels: z.array(z.string()).optional().describe("Label names (resolved to IDs is not attempted; pass label IDs as strings if known, otherwise omit)"),
      },
    },
    async ({ owner, repo, title, body, labels }) =>
      textResult(
        await forgejoApi(`/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/issues`, {
          method: "POST",
          body: JSON.stringify({ title, body: body || "", labels: labels || [] }),
        })
      )
  );

  server.registerTool(
    "forgejo_list_issues",
    {
      description: "List issues in a Forgejo repo, optionally filtered by state and labels.",
      inputSchema: {
        owner: z.string(),
        repo: z.string(),
        state: z.enum(["open", "closed", "all"]).optional(),
        labels: z.string().optional().describe("Comma-separated label names"),
      },
    },
    async ({ owner, repo, state, labels }) => {
      const params = new URLSearchParams();
      if (state) params.set("state", state);
      if (labels) params.set("labels", labels);
      const qs = params.toString() ? `?${params.toString()}` : "";
      return textResult(await forgejoApi(`/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/issues${qs}`));
    }
  );

  server.registerTool(
    "forgejo_get_issue",
    {
      description: "Get a single issue by number from a Forgejo repo.",
      inputSchema: { owner: z.string(), repo: z.string(), number: z.number().int() },
    },
    async ({ owner, repo, number }) =>
      textResult(await forgejoApi(`/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/issues/${number}`))
  );

  server.registerTool(
    "forgejo_create_pr",
    {
      description: "Create a pull request in a Forgejo repo (head branch -> base branch).",
      inputSchema: {
        owner: z.string(),
        repo: z.string(),
        head: z.string(),
        base: z.string(),
        title: z.string(),
        body: z.string().optional(),
      },
    },
    async ({ owner, repo, head, base, title, body }) =>
      textResult(
        await forgejoApi(`/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/pulls`, {
          method: "POST",
          body: JSON.stringify({ head, base, title, body: body || "" }),
        })
      )
  );

  server.registerTool(
    "forgejo_list_prs",
    {
      description: "List pull requests in a Forgejo repo.",
      inputSchema: { owner: z.string(), repo: z.string(), state: z.enum(["open", "closed", "all"]).optional() },
    },
    async ({ owner, repo, state }) => {
      const qs = state ? `?state=${state}` : "";
      return textResult(await forgejoApi(`/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/pulls${qs}`));
    }
  );

  server.registerTool(
    "forgejo_get_commit_log",
    {
      description: "Get the last N commits on a branch in a Forgejo repo.",
      inputSchema: { owner: z.string(), repo: z.string(), branch: z.string().optional(), limit: z.number().int().optional() },
    },
    async ({ owner, repo, branch, limit }) => {
      const params = new URLSearchParams();
      if (branch) params.set("sha", branch);
      params.set("limit", String(limit || 10));
      return textResult(
        await forgejoApi(`/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/commits?${params.toString()}`)
      );
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
  const server = buildServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => {
    transport.close();
    server.close();
  });
  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`forgejo-mcp listening on :${PORT}`);
});
