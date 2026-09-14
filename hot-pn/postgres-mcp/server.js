import express from "express";
import pg from "pg";
import { readFileSync } from "node:fs";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";

const { Pool } = pg;

const DB_LABEL = process.env.DB_LABEL || "database";
const PG_HOST = process.env.PG_HOST || "localhost";
const PG_PORT = Number(process.env.PG_PORT || 5432);
const PG_DATABASE = process.env.PG_DATABASE;
const PG_USER = process.env.PG_USER;
const PG_PASSWORD = readFileSync(process.env.PG_PASSWORD_FILE, "utf8").trim();
const MCP_AUTH_TOKEN = readFileSync(process.env.MCP_AUTH_TOKEN_FILE || "/run/secrets/mcp_auth_token", "utf8").trim();
const PORT = process.env.PORT || 3005;
const MAX_ROWS = 500;
const STATEMENT_TIMEOUT_MS = 10000;

// Read-only role (SELECT-only grants) is the real enforcement — everything below is defense
// in depth, not the primary control.
const pool = new Pool({
  host: PG_HOST,
  port: PG_PORT,
  database: PG_DATABASE,
  user: PG_USER,
  password: PG_PASSWORD,
  max: 3,
  idleTimeoutMillis: 30000,
  statement_timeout: STATEMENT_TIMEOUT_MS,
  application_name: "jarvis-postgres-mcp",
});

function isReadOnlyStatement(sql) {
  const trimmed = sql.trim().replace(/;+\s*$/, "");
  if (trimmed.includes(";")) return false; // no stacked statements
  const head = trimmed.slice(0, 20).trimStart().toUpperCase();
  return head.startsWith("SELECT") || head.startsWith("WITH") || head.startsWith("EXPLAIN") || head.startsWith("SHOW") || head.startsWith("TABLE ");
}

async function runReadOnlyQuery(sql) {
  if (!isReadOnlyStatement(sql)) {
    throw new Error("Only a single SELECT/WITH/EXPLAIN/SHOW/TABLE statement is allowed (no writes, no stacked statements).");
  }
  const client = await pool.connect();
  try {
    await client.query("BEGIN READ ONLY");
    const result = await client.query(sql);
    await client.query("COMMIT");
    const truncated = result.rows.length > MAX_ROWS;
    return {
      rowCount: result.rowCount,
      fields: result.fields?.map((f) => f.name) || [],
      rows: result.rows.slice(0, MAX_ROWS),
      truncated,
    };
  } catch (err) {
    await client.query("ROLLBACK").catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

function textResult(data) {
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
}

function errorResult(err) {
  return { content: [{ type: "text", text: `Error: ${err.message}` }], isError: true };
}

function buildServer() {
  const server = new McpServer({ name: `postgres-mcp-${DB_LABEL.toLowerCase()}`, version: "1.0.0" });

  server.registerTool(
    "postgres_query",
    {
      description:
        `Run a read-only SQL query (SELECT/WITH/EXPLAIN/SHOW only) against the ${DB_LABEL} ` +
        `PostgreSQL database, connected as a dedicated read-only role. No writes are possible — ` +
        `enforced by the DB role's own grants, a read-only transaction, and a statement-shape check.`,
      inputSchema: { sql: z.string().describe("A single SELECT/WITH/EXPLAIN/SHOW statement") },
    },
    async ({ sql }) => {
      try {
        return textResult(await runReadOnlyQuery(sql));
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "postgres_list_tables",
    {
      description: `List tables and their row estimate in the ${DB_LABEL} database's public schema.`,
      inputSchema: {},
    },
    async () => {
      try {
        return textResult(
          await runReadOnlyQuery(
            "SELECT relname AS table_name, n_live_tup AS approx_rows FROM pg_stat_user_tables ORDER BY relname"
          )
        );
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "postgres_describe_table",
    {
      description: `Describe a table's columns and types in the ${DB_LABEL} database's public schema.`,
      inputSchema: { table: z.string() },
    },
    async ({ table }) => {
      try {
        return textResult(
          await runReadOnlyQuery(
            `SELECT column_name, data_type, is_nullable FROM information_schema.columns ` +
            `WHERE table_schema = 'public' AND table_name = '${table.replace(/'/g, "''")}' ORDER BY ordinal_position`
          )
        );
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
  console.log(`postgres-mcp (${DB_LABEL}) listening on :${PORT}`);
});
