// Remote MCP server for AI agents (Claude, ChatGPT and other MCP clients).
// URL: https://<project>.supabase.co/functions/v1/mora-mcp/<agent key>
// The agent key from Mora is the only credential; deploy with JWT verification
// off. The function holds no secrets: it calls two database functions with the
// project's publishable key, and they check the agent key themselves.

const PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];
const VERSION = "1.0.0";

const INSTRUCTIONS = `Mora is a personal finance ledger. To import transactions:
1. Call get_mora_context to see accounts, categories and recent transactions.
2. Read the user's statement, screenshot or description. Skip rows that are already in recent_transactions.
3. If an account is unclear, ask the user one short question first.
4. Call add_transactions once with all new rows. Amounts are positive; kind sets the direction.
5. Tell the user how many rows were added and that Mora shows them as one import that can be rolled back.`;

const TOOLS = [
  {
    name: "get_mora_context",
    title: "Read Mora accounts and categories",
    description: "Returns account names and currencies, categories, the base currency, today's date and transactions from the last 60 days. Call it before add_transactions.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  {
    name: "add_transactions",
    title: "Record transactions in Mora",
    description: "Records new transactions in the shared Mora database as one import batch. All rows are validated first: if any row is invalid nothing is recorded and the errors are returned. Rows already recorded (same account, day, amount and description, or the same external_id) are skipped.",
    inputSchema: {
      type: "object",
      properties: {
        transactions: {
          type: "array", minItems: 1, maxItems: 500,
          items: {
            type: "object",
            properties: {
              date: { type: "string", description: "YYYY-MM-DD, or an ISO 8601 time with offset" },
              description: { type: "string", description: "Merchant or short description" },
              amount: { type: "number", exclusiveMinimum: 0, description: "Positive amount in the account's currency" },
              kind: { type: "string", enum: ["expense", "income", "transfer"], default: "expense" },
              account: { type: "string", description: "Account name or id from get_mora_context" },
              to_account: { type: "string", description: "Destination account for transfers" },
              to_amount: { type: "number", description: "Amount credited to to_account when its currency differs" },
              category: { type: "string", description: "Category name or id of the same kind. Omit to apply Mora's rules" },
              note: { type: "string" },
              tags: { type: "array", items: { type: "string" }, maxItems: 20 },
              external_id: { type: "string", description: "Stable id from the statement, used to avoid duplicates" },
            },
            required: ["date", "description", "amount", "account"],
            additionalProperties: false,
          },
        },
        source: { type: "string", description: "Short name for the import history, e.g. 'Bank statement October'" },
        skip_duplicates: { type: "boolean", default: true },
      },
      required: ["transactions"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
];

type Json = Record<string, unknown>;
export type Environment = { url: string; key: string; fetch?: typeof fetch };

class ToolError extends Error {}

async function rpc(env: Environment, name: string, body: Json): Promise<unknown> {
  const headers: Record<string, string> = { "content-type": "application/json", apikey: env.key };
  // Legacy anon keys are JWTs; publishable keys go only in the apikey header.
  if (env.key.startsWith("eyJ")) headers.authorization = `Bearer ${env.key}`;
  const response = await (env.fetch ?? fetch)(`${env.url}/rest/v1/rpc/${name}`, { method: "POST", headers, body: JSON.stringify(body) });
  const text = await response.text();
  const value = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const message = typeof value?.message === "string" ? value.message : `Database error ${response.status}`;
    throw new ToolError(message.includes("Agent key") || message.includes("agent key")
      ? "This Mora connection was revoked. Create a new one in Mora → Import via AI." : message);
  }
  return value;
}

async function callTool(env: Environment, token: string, name: string, args: Json): Promise<unknown> {
  switch (name) {
    case "get_mora_context":
      return await rpc(env, "mora_agent_context", { p_token: token });
    case "add_transactions":
      if (!Array.isArray(args.transactions)) throw new ToolError("transactions must be an array");
      return await rpc(env, "mora_agent_add_transactions", {
        p_token: token,
        p_transactions: args.transactions,
        p_source: typeof args.source === "string" ? args.source : null,
        p_skip_duplicates: args.skip_duplicates !== false,
      });
    default:
      throw new ToolError(`Unknown tool: ${name}`);
  }
}

async function respond(env: Environment, token: string, message: Json): Promise<Json | null> {
  const { id, method } = message;
  const params = (message.params ?? {}) as Json;
  if (id === undefined || id === null) return null; // Notifications need no answer.
  const result = (value: unknown) => ({ jsonrpc: "2.0", id, result: value });
  switch (method) {
    case "initialize": {
      const requested = String(params.protocolVersion ?? "");
      return result({
        protocolVersion: PROTOCOL_VERSIONS.includes(requested) ? requested : PROTOCOL_VERSIONS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "mora", title: "Mora", version: VERSION },
        instructions: INSTRUCTIONS,
      });
    }
    case "ping":
      return result({});
    case "tools/list":
      return result({ tools: TOOLS });
    case "tools/call":
      try {
        const value = await callTool(env, token, String(params.name), (params.arguments ?? {}) as Json);
        return result({ content: [{ type: "text", text: JSON.stringify(value) }], structuredContent: value });
      } catch (error) {
        const text = error instanceof ToolError ? error.message : "Mora could not complete the request. Try again later.";
        return result({ content: [{ type: "text", text }], isError: true });
      }
    default:
      return { jsonrpc: "2.0", id, error: { code: -32601, message: `Method not found: ${method}` } };
  }
}

export async function handle(request: Request, env: Environment): Promise<Response> {
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
  const token = new URL(request.url).pathname.split("/").filter(Boolean).pop() ?? "";
  if (!/^[0-9a-f]{64}$/.test(token)) return json({ error: "Use the full connection URL from Mora" }, 404);
  // Stateless Streamable HTTP: no server-sent event stream and no sessions.
  if (request.method === "GET" || request.method === "DELETE") return new Response(null, { status: 405, headers: { allow: "POST" } });
  if (request.method !== "POST") return new Response(null, { status: 405, headers: { allow: "POST" } });
  let body: unknown;
  try {
    const text = await request.text();
    if (text.length > 2_000_000) return json({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "Request too large" } }, 413);
    body = JSON.parse(text);
  } catch {
    return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }, 400);
  }
  const messages = Array.isArray(body) ? body : [body];
  if (messages.length === 0 || messages.length > 20 || messages.some((m) => typeof m !== "object" || m === null)) {
    return json({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "Invalid request" } }, 400);
  }
  const answers = (await Promise.all(messages.map((m) => respond(env, token, m as Json)))).filter((a) => a !== null);
  if (answers.length === 0) return new Response(null, { status: 202 });
  return json(Array.isArray(body) ? answers : answers[0]);
}

// Deno runs this file in Supabase; tests import handle() without it.
const deno = (globalThis as { Deno?: { env: { get(name: string): string | undefined }; serve(handler: (request: Request) => Promise<Response>): void } }).Deno;
if (deno) {
  const url = deno.env.get("SUPABASE_URL") ?? "";
  // Projects with new API keys expose them as a JSON object; older ones as SUPABASE_ANON_KEY.
  let key = deno.env.get("SUPABASE_ANON_KEY") ?? "";
  try { key = Object.values(JSON.parse(deno.env.get("SUPABASE_PUBLISHABLE_KEYS") ?? "{}"))[0] as string || key; } catch { /* keep the anon key */ }
  deno.serve((request) => handle(request, { url, key }));
}
