import { execFile } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

// Deliberately hardcoded, not configurable at runtime — folder scoping is a build-time
// decision, not something a tool call (or an injected instruction inside one) can widen.
// "House of Trae — Gateway VPS" folder in Vaultwarden.
const FOLDER_ID = "7bc68d47-1669-4f35-9a45-7c94c8f9eb1f";
const FOLDER_NAME = "House of Trae — Gateway VPS";

const SESSION_FILE = process.env.BW_SESSION_FILE || "/opt/stacks/vaultwarden-mcp/secrets/bw_session.txt";

// Pure metadata noise stripped from bw's raw item JSON before returning it — everything else
// (login, secureNote, card, identity, fields, notes, name, passwordHistory) is passed through,
// since this tool only ever returns items already confirmed to be inside FOLDER_ID.
const STRIP_KEYS = [
  "object", "collectionIds", "organizationId", "revisionDate", "creationDate",
  "deletedDate", "favorite", "reprompt", "edit", "viewPassword",
];

function readSession() {
  if (!existsSync(SESSION_FILE)) return null;
  const s = readFileSync(SESSION_FILE, "utf8").trim();
  return s.length > 0 ? s : null;
}

function runBw(args) {
  return new Promise((resolve, reject) => {
    const session = readSession();
    if (!session) {
      reject(new Error(
        "No Vaultwarden session configured — this tool is inert by design until Mr. Byrne " +
        "runs `bw unlock` himself and writes the resulting session key to " +
        `${SESSION_FILE} (chmod 600). There is no standing auto-unlock.`
      ));
      return;
    }
    execFile("bw", args, { env: { ...process.env, BW_SESSION: session }, timeout: 15000 }, (err, stdout, stderr) => {
      if (err) {
        const msg = (stderr || err.message || "").toLowerCase();
        if (msg.includes("you are not logged in") || msg.includes("vault is locked") || msg.includes("session")) {
          reject(new Error(
            "Vaultwarden session is invalid, expired, or the vault is locked. Ask Mr. Byrne to " +
            `run \`bw unlock\` again and refresh ${SESSION_FILE}.`
          ));
          return;
        }
        reject(new Error(`bw ${args.join(" ")} failed: ${stderr || err.message}`));
        return;
      }
      try {
        resolve(stdout.trim() ? JSON.parse(stdout) : null);
      } catch {
        resolve(stdout.trim());
      }
    });
  });
}

function textResult(data) {
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
}

function errorResult(err) {
  return { content: [{ type: "text", text: `Error: ${err.message}` }], isError: true };
}

const TYPE_NAMES = { 1: "login", 2: "secure_note", 3: "card", 4: "identity" };

function summarize(item) {
  return {
    id: item.id,
    name: item.name,
    type: TYPE_NAMES[item.type] || `unknown(${item.type})`,
    username: item.login?.username || null,
    hasTotp: !!item.login?.totp,
    uris: (item.login?.uris || []).map((u) => u.uri),
  };
}

function stripMetadata(item) {
  const out = { ...item };
  for (const k of STRIP_KEYS) delete out[k];
  return out;
}

const server = new McpServer({ name: "vaultwarden-mcp", version: "1.0.0" });

server.registerTool(
  "vaultwarden_status",
  {
    description:
      `Check whether a Vaultwarden session is currently configured and the vault is unlocked. ` +
      `Always call this before vaultwarden_list_items/vaultwarden_get_item if unsure.`,
    inputSchema: {},
  },
  async () => {
    const configured = readSession() !== null;
    if (!configured) {
      return textResult({ sessionConfigured: false, note: "No session file present — vault is inert, ask Mr. Byrne to unlock." });
    }
    try {
      const status = await runBw(["status"]);
      return textResult({ sessionConfigured: true, folder: FOLDER_NAME, ...status });
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "vaultwarden_list_items",
  {
    description:
      `List items in the "${FOLDER_NAME}" Vaultwarden folder ONLY — this tool cannot see any ` +
      `other folder in the vault. Returns names/types/usernames/URIs, never passwords or note ` +
      `contents. Use vaultwarden_get_item for the actual secret value of a specific item.`,
    inputSchema: { search: z.string().optional().describe("Case-insensitive substring filter on item name") },
  },
  async ({ search }) => {
    try {
      const items = (await runBw(["list", "items", "--folderid", FOLDER_ID])) || [];
      let summaries = items.map(summarize);
      if (search) {
        const needle = search.toLowerCase();
        summaries = summaries.filter((i) => i.name.toLowerCase().includes(needle));
      }
      return textResult(summaries);
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "vaultwarden_get_item",
  {
    description:
      `Get the full contents (including secret values) of one item — ONLY if it belongs to the ` +
      `"${FOLDER_NAME}" folder. Items outside that folder are refused even if you have their ID. ` +
      `Get the item_id from vaultwarden_list_items first.`,
    inputSchema: { item_id: z.string().describe("Vaultwarden item ID, from vaultwarden_list_items") },
  },
  async ({ item_id }) => {
    try {
      const item = await runBw(["get", "item", item_id]);
      if (!item) {
        return errorResult(new Error(`Item ${item_id} not found.`));
      }
      if (item.folderId !== FOLDER_ID) {
        return errorResult(new Error(
          `Item "${item.name}" is outside the "${FOLDER_NAME}" folder this tool is scoped to — refused.`
        ));
      }
      return textResult(stripMetadata(item));
    } catch (err) {
      return errorResult(err);
    }
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
