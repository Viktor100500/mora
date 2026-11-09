// Telegram bot for Mora: a strict purchase form, no free-text parsing.
//   POST /mora-telegram/webhook       Telegram updates (header X-Telegram-Bot-Api-Secret-Token)
//   POST /mora-telegram/api/context   the Mini App's form data   { init_data }
//   POST /mora-telegram/api/purchase  one purchase from the form { init_data, event_id, account_id, amount, ... }
// The Mini App (cloud/telegram/miniapp) proves the user with Telegram's signed
// initData; the HTML bubble (widget.ts) asks the bot through widget_query.
// Only TELEGRAM_ALLOWED_USERS may record. The phone key and the bot token stay
// in the function's secrets. Deploy with JWT verification off.
import { WIDGET_HTML } from "./widget.ts";

type Json = Record<string, unknown>;
export type Environment = {
  url: string; key: string;            // Supabase project URL and publishable key
  botToken: string; phoneToken: string; webhookSecret: string;
  allowedUsers: Set<number>;
  miniAppUrl: string;                  // HTTPS page of the Mini App, opened by web_app buttons
  miniAppLink?: string;                // t.me direct link (https://t.me/<bot>/<app>), for the widget
  botApi?: string;                     // https://api.telegram.org
  widgetApi?: string;                  // Bot API 10.4 for widgets; the beta until it is released
  fetch?: typeof fetch;
  now?: () => Date;
};

class UserError extends Error {}

// ---------- Supabase

async function rpc(env: Environment, name: string, body: Json): Promise<any> {
  const headers: Record<string, string> = { "content-type": "application/json", apikey: env.key };
  if (env.key.startsWith("eyJ")) headers.authorization = `Bearer ${env.key}`;
  const response = await (env.fetch ?? fetch)(`${env.url}/rest/v1/rpc/${name}`, { method: "POST", headers, body: JSON.stringify(body) });
  const text = await response.text();
  const value = text ? JSON.parse(text) : null;
  if (!response.ok) throw new UserError(translate(typeof value?.message === "string" ? value.message : `Database error ${response.status}`));
  return value;
}

function translate(message: string): string {
  if (message.includes("Invalid phone token")) return "Ключ телефона отозван. Создайте новый в Mora и обновите секрет MORA_PHONE_TOKEN.";
  if (message.includes("Enter the merchant")) return "Укажите продавца.";
  if (message.includes("Amount must be positive")) return "Проверьте сумму: " + message.replace(/^.*decimals for/, "слишком много знаков после запятой для");
  if (message.includes("active shared account")) return "Выберите действующий счёт.";
  if (message.includes("expense category")) return "Выберите категорию расходов.";
  if (message.includes("purchase date")) return "Проверьте дату покупки.";
  if (message.includes("purchase currency")) return "Выберите валюту.";
  if (message.includes("daily limit")) return "Достигнут дневной лимит покупок для этого ключа.";
  return message;
}

const context = (env: Environment) => rpc(env, "mora_phone_context", { p_token: env.phoneToken });

type Purchase = { event_id: string; account_id: string; amount: number; currency: string; merchant: string;
  category_id?: string | null; note?: string; date?: string };

async function addPurchase(env: Environment, p: Purchase): Promise<any> {
  return rpc(env, "mora_phone_add_purchase", {
    p_token: env.phoneToken, p_event_id: p.event_id, p_account_id: p.account_id, p_amount: p.amount,
    p_currency: p.currency, p_merchant: p.merchant, p_category_id: p.category_id || null,
    p_note: p.note ?? "", p_occurred_at: p.date ?? (env.now?.() ?? new Date()).toISOString(),
  });
}

// ---------- Telegram

async function telegram(env: Environment, method: string, params: Json, widget = false): Promise<any> {
  const base = widget ? (env.widgetApi ?? "https://api.telegram.org/beta") : (env.botApi ?? "https://api.telegram.org");
  const response = await (env.fetch ?? fetch)(`${base}/bot${env.botToken}/${method}`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(params),
  });
  const body = await response.json().catch(() => ({ ok: false, description: `HTTP ${response.status}` }));
  if (!body.ok) throw new Error(`${method}: ${body.description}`);
  return body.result;
}

const enc = new TextEncoder();
const hex = (bytes: ArrayBuffer) => [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
async function hmac(key: Uint8Array | string, data: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey("raw", typeof key === "string" ? enc.encode(key) : key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", k, enc.encode(data));
}
const sha256 = async (text: string) => hex(await crypto.subtle.digest("SHA-256", enc.encode(text)));
const merchantHash = async (merchant: string) => (await sha256(merchant.toLowerCase())).slice(0, 4);

// A UUID derived from a Telegram id, so a retried request never records twice.
async function eventId(seed: string): Promise<string> {
  const h = await sha256(seed);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-${((parseInt(h[16], 16) & 3) | 8).toString(16)}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

/** Telegram Mini App initData, checked as core.telegram.org/bots/webapps describes. Returns the user id. */
export async function verifyInitData(env: Environment, initData: string, maxAgeSeconds = 86400): Promise<number> {
  const params = new URLSearchParams(initData);
  const hash = params.get("hash") ?? "";
  params.delete("hash");
  const check = [...params.entries()].map(([k, v]) => `${k}=${v}`).sort().join("\n");
  const secret = new Uint8Array(await hmac("WebAppData", env.botToken));
  const expected = hex(await hmac(secret, check));
  if (!/^[0-9a-f]{64}$/.test(hash) || !timingSafeEqual(hash, expected)) throw new UserError("Откройте форму из бота заново.");
  const age = (env.now?.() ?? new Date()).getTime() / 1000 - Number(params.get("auth_date"));
  if (!(age < maxAgeSeconds)) throw new UserError("Форма устарела. Откройте её из бота заново.");
  const id = Number(JSON.parse(params.get("user") ?? "{}").id);
  if (!env.allowedUsers.has(id)) throw new UserError("Этот бот записывает покупки только для своих участников.");
  return id;
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// ---------- formatting

const decimals = (currency: string) =>
  ["BIF","CLP","DJF","GNF","ISK","JPY","KMF","KRW","PYG","RWF","UGX","UYI","VND","VUV","XAF","XOF","XPF"].includes(currency) ? 0
    : ["BHD","IQD","JOD","KWD","LYD","OMR","TND"].includes(currency) ? 3 : 2;
const money = (amount: number, currency: string) =>
  `${amount.toLocaleString("ru-RU", { minimumFractionDigits: decimals(currency), maximumFractionDigits: decimals(currency) })} ${currency}`;
const totals = (map: Record<string, number> | undefined) =>
  Object.entries(map ?? {}).map(([c, v]) => money(Number(v), c)).join(" + ") || "0";

// The widget names categories and accounts by their index; this version says which lists it saw.
const listsVersion = async (ctx: any) =>
  (await sha256(JSON.stringify([(ctx.categories ?? []).map((c: any) => c.id), (ctx.accounts ?? []).map((a: any) => a.id)]))).slice(0, 4);

/** The widget's chat state, at most 1024 bytes: totals, the Mini App link, recent merchants, categories and accounts. */
export async function widgetState(env: Environment, ctx: any): Promise<string> {
  const recent = await Promise.all((ctx.recent ?? []).slice(0, 6).map(async (r: any) =>
    [String(r.merchant).slice(0, 24), r.currency, await merchantHash(r.merchant)]));
  const accounts: any[] = ctx.accounts ?? [];
  const lists = (n: number) => ({
    c: (ctx.categories ?? []).map((c: any) => String(c.name).slice(0, n)),
    a: accounts.map((a) => [String(a.name).slice(0, n), a.currency]),
  });
  const state = { t: totals(ctx.totals?.today), m: totals(ctx.totals?.month), l: env.miniAppLink ?? "", r: recent,
    ...lists(22), d: Math.max(0, accounts.findIndex((a) => a.id === ctx.default_account_id)), v: await listsVersion(ctx) };
  const size = () => enc.encode(JSON.stringify(state)).length;
  while (size() > 1024 && state.r.length) state.r.pop();
  // Shorter names keep every category and account, so their indexes stay those of the lists.
  for (const n of [16, 12, 8, 4]) if (size() > 1024) Object.assign(state, lists(n));
  return JSON.stringify(state);
}

function purchaseLine(p: { merchant: string; amount: number; currency: string }, result: any): string {
  const where = [result.account, result.category].filter(Boolean).join(" · ");
  const line = `${p.merchant} −${money(p.amount, p.currency)}${where ? ` (${where})` : ""}`;
  if (result.duplicate) return `✓ Уже записано: ${line}`;
  if (result.state === "recorded") return `✓ ${line}`;
  return result.reason === "Валюта покупки отличается от валюты счета"
    ? `✓ ${line}. Mora пересчитает по курсу Visa, когда откроется.`
    : `⏳ ${line}. Ждёт проверки в Mora: ${result.reason}`;
}

// ---------- the bot

// Without a Mini App address yet, messages go without the button (Telegram refuses an empty web_app URL).
const menuButton = (env: Environment) => env.miniAppUrl.startsWith("https://")
  ? { inline_keyboard: [[{ text: "＋ Добавить трату", web_app: { url: env.miniAppUrl } }]] } : undefined;

async function sendWidget(env: Environment, chatId: number): Promise<void> {
  await telegram(env, "sendWidget", {
    chat_id: chatId, html: WIDGET_HTML, allow_queries: true, chat_data: await widgetState(env, await context(env)),
  }, true);
}

async function onMessage(env: Environment, message: any): Promise<void> {
  const chatId = message.chat?.id, userId = message.from?.id;
  if (message.chat?.type !== "private" || !chatId) return;
  if (!env.allowedUsers.has(userId)) {
    await telegram(env, "sendMessage", { chat_id: chatId,
      text: `Это личный бот Mora. Ваш Telegram ID: ${userId}. Чтобы записывать покупки, передайте его владельцу бота.` });
    return;
  }
  const command = String(message.text ?? "").trim().split(/[\s@]/)[0];
  if (command === "/widget") {
    try { await sendWidget(env, chatId); }
    catch (error) {
      await telegram(env, "sendMessage", { chat_id: chatId, reply_markup: menuButton(env),
        text: `Виджет в чате пока недоступен (${(error as Error).message}). Записывайте покупки через форму.` });
    }
    return;
  }
  await telegram(env, "sendMessage", { chat_id: chatId, reply_markup: menuButton(env),
    text: command === "/start"
      ? "Привет! Покупки записываются через форму: сумма, валюта, счёт, продавец и категория. Нажмите кнопку ниже или «Добавить» слева от поля ввода. Команда /widget присылает виджет для быстрых записей."
      : "Я не разбираю текст, чтобы не ошибиться в сумме. Нажмите кнопку и заполните форму." });
  if (command === "/start") await sendWidget(env, chatId).catch((error) => console.log(`sendWidget: ${error.message}`));
}

/** A request from the HTML bubble: `r` refreshes it, `q|amount|index|hash` records a recent merchant again,
 *  `a|amount|currency|category|account|version` records a new purchase named after its category. */
async function onWidgetQuery(env: Environment, q: any): Promise<void> {
  const answer = (data: string) => telegram(env, "answerWidgetQuery", { widget_query_id: q.id, data: data.slice(0, 300) }, true);
  if (!env.allowedUsers.has(q.from?.id)) return answer("✗ Этот бот записывает покупки только для своих участников.");
  try {
    let text = "↻ Обновлено";
    const fresh = /^a\|(\d{1,9}(?:\.\d{1,3})?)\|([A-Z]{3})\|(\d{1,2})\|(\d{1,2})\|([0-9a-f]{4})$/.exec(String(q.data ?? ""));
    const quick = /^q\|(\d{1,9}(?:\.\d{1,3})?)\|(\d{1,2})\|([0-9a-f]{4})$/.exec(String(q.data ?? ""));
    if (quick) {
      const ctx = await context(env);
      const recent: any[] = ctx.recent ?? [];
      const byIndex = recent[Number(quick[2])];
      const hashes = await Promise.all(recent.map((r) => merchantHash(r.merchant)));
      const entry = byIndex && hashes[Number(quick[2])] === quick[3] ? byIndex : recent[hashes.indexOf(quick[3])];
      if (!entry) return answer("✗ Не нашёл этого продавца. Нажмите ↻ и попробуйте снова.");
      const account = ctx.accounts.find((a: any) => a.id === entry.account_id) ?? ctx.accounts.find((a: any) => a.id === ctx.default_account_id);
      if (!account) return answer("✗ Счёт недоступен. Запишите через форму.");
      const p = { event_id: await eventId(`widget:${q.id}`), account_id: account.id, amount: Number(quick[1]),
        currency: entry.currency || account.currency, merchant: entry.merchant, category_id: entry.category_id };
      text = purchaseLine(p, await addPurchase(env, p));
    } else if (fresh) {
      const ctx = await context(env);
      const category = ctx.categories?.[Number(fresh[3])], account = ctx.accounts?.[Number(fresh[4])];
      if (!category || !account || await listsVersion(ctx) !== fresh[5]) return answer("✗ Счета или категории изменились. Нажмите ↻ и повторите.");
      const p = { event_id: await eventId(`widget:${q.id}`), account_id: account.id, amount: Number(fresh[1]),
        currency: fresh[2], merchant: category.name, category_id: category.id };
      text = purchaseLine(p, await addPurchase(env, p));
    } else if (q.data !== "r") {
      return answer("✗ Неизвестная команда виджета.");
    }
    const state = await widgetState(env, await context(env));
    const where = q.inline_message_id ? { inline_message_id: q.inline_message_id } : { chat_id: q.chat?.id, message_id: q.message_id };
    await telegram(env, "editMessageWidgetData", { ...where, chat_data: state }, true)
      .catch((error) => { if (!String(error.message).includes("not modified")) throw error; });
    await answer(text);
  } catch (error) {
    await answer(`✗ ${error instanceof UserError ? error.message : "Не получилось. Попробуйте ещё раз."}`);
    if (!(error instanceof UserError)) console.error(error);
  }
}

// ---------- the Mini App's API

async function api(env: Environment, action: string, body: Json): Promise<Json> {
  const userId = await verifyInitData(env, String(body.init_data ?? ""));
  if (action === "context") return await context(env);
  if (action !== "purchase") throw new UserError("Неизвестный запрос.");
  const amount = Number(body.amount);
  const p: Purchase = {
    event_id: String(body.event_id ?? ""), account_id: String(body.account_id ?? ""), amount,
    currency: String(body.currency ?? ""), merchant: String(body.merchant ?? ""),
    category_id: body.category_id ? String(body.category_id) : null, note: String(body.note ?? "").slice(0, 500),
    date: body.date ? String(body.date) : undefined,
  };
  if (!/^[0-9a-f-]{36}$/i.test(p.event_id) || !/^[0-9a-f-]{36}$/i.test(p.account_id)) throw new UserError("Откройте форму из бота заново.");
  if (!Number.isFinite(amount) || amount <= 0) throw new UserError("Введите сумму больше нуля.");
  if (p.date && Number.isNaN(Date.parse(p.date))) throw new UserError("Проверьте дату покупки.");
  const result = await addPurchase(env, p);
  const line = purchaseLine(p, result);
  // A receipt in the chat, so every purchase is visible there too.
  if (!result.duplicate) await telegram(env, "sendMessage", { chat_id: userId, text: line }).catch((e) => console.log(e.message));
  return { ...result, message: line };
}

// ---------- HTTP

const CORS = { "access-control-allow-origin": "*", "access-control-allow-methods": "POST, OPTIONS",
  "access-control-allow-headers": "content-type", "access-control-max-age": "86400" };
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...CORS } });

export async function handle(request: Request, env: Environment): Promise<Response> {
  const parts = new URL(request.url).pathname.split("/").filter(Boolean);
  const at = parts.indexOf("mora-telegram");
  const route = (at >= 0 ? parts.slice(at + 1) : parts).join("/");
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (request.method !== "POST") return new Response(null, { status: 405, headers: { allow: "POST, OPTIONS" } });
  const text = await request.text();
  if (text.length > 100_000) return json({ error: "Request too large" }, 413);
  let body: Json;
  try { body = JSON.parse(text); if (typeof body !== "object" || body === null) throw 0; }
  catch { return json({ error: "Invalid JSON" }, 400); }

  if (route === "webhook") {
    const secret = request.headers.get("x-telegram-bot-api-secret-token") ?? "";
    if (!env.webhookSecret || !timingSafeEqual(secret, env.webhookSecret)) return json({ error: "Forbidden" }, 403);
    try {
      if (body.message) await onMessage(env, body.message);
      else if (body.widget_query) await onWidgetQuery(env, body.widget_query);
    } catch (error) { console.error(error); }
    // Telegram retries non-2xx answers; a failed update is logged, not retried forever.
    return json({ ok: true });
  }
  const action = /^api\/(context|purchase)$/.exec(route)?.[1];
  if (!action) return json({ error: "Not found" }, 404);
  try { return json(await api(env, action, body)); }
  catch (error) {
    if (error instanceof UserError) return json({ error: error.message }, 400);
    console.error(error);
    return json({ error: "Mora не ответила. Попробуйте ещё раз." }, 502);
  }
}

/** Settings from function secrets, else from Vault (mora_telegram_*), read with the service role. */
export async function loadEnvironment(get: (name: string) => string, fetcher: typeof fetch = fetch): Promise<Environment> {
  const firstKey = (json: string) => { try { return Object.values(JSON.parse(json || "{}"))[0] as string || ""; } catch { return ""; } };
  const url = get("SUPABASE_URL");
  const key = firstKey(get("SUPABASE_PUBLISHABLE_KEYS")) || get("SUPABASE_ANON_KEY");
  let vault: Record<string, string> = {};
  const service = firstKey(get("SUPABASE_SECRET_KEYS")) || get("SUPABASE_SERVICE_ROLE_KEY");
  if (service && !get("TELEGRAM_BOT_TOKEN")) {
    const headers: Record<string, string> = { "content-type": "application/json", apikey: service };
    if (service.startsWith("eyJ")) headers.authorization = `Bearer ${service}`;
    const response = await fetcher(`${url}/rest/v1/rpc/mora_telegram_settings`, { method: "POST", headers, body: "{}" });
    if (response.ok) vault = await response.json() ?? {};
    else console.error(`mora_telegram_settings: HTTP ${response.status}`);
  }
  const setting = (secret: string, name: string) => get(secret) || vault[name] || "";
  return {
    url, key,
    botToken: setting("TELEGRAM_BOT_TOKEN", "bot_token"), phoneToken: setting("MORA_PHONE_TOKEN", "phone_token"),
    webhookSecret: setting("TELEGRAM_WEBHOOK_SECRET", "webhook_secret"),
    allowedUsers: new Set(setting("TELEGRAM_ALLOWED_USERS", "allowed_users").split(/[\s,]+/).filter(Boolean).map(Number)),
    miniAppUrl: setting("TELEGRAM_MINIAPP_URL", "miniapp_url"), miniAppLink: setting("TELEGRAM_MINIAPP_LINK", "miniapp_link") || undefined,
    widgetApi: setting("TELEGRAM_WIDGET_API", "widget_api") || undefined,
  };
}

// Deno runs this file in Supabase; tests import handle() without it.
const deno = (globalThis as { Deno?: { env: { get(name: string): string | undefined }; serve(handler: (request: Request) => Promise<Response>): void } }).Deno;
if (deno) {
  // Vault changes (a new participant, a new key) apply within a minute.
  let cached: { env: Promise<Environment>; at: number } | null = null;
  const environment = () => {
    if (!cached || Date.now() - cached.at > 60_000) {
      const env = loadEnvironment((name) => deno.env.get(name) ?? "");
      cached = { env, at: Date.now() };
      env.catch(() => { cached = null; });
    }
    return cached.env;
  };
  deno.serve(async (request) => handle(request, await environment()));
}
