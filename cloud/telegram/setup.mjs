// Points the Telegram bot at the mora-telegram function: webhook, commands and
// the menu button that opens the Mini App. Run once after deploying, and again
// when an address changes. No dependencies (Node 18+).
//
//   TELEGRAM_BOT_TOKEN=... TELEGRAM_WEBHOOK_SECRET=... \
//   MORA_FUNCTION_URL=https://<project>.supabase.co/functions/v1/mora-telegram \
//   TELEGRAM_MINIAPP_URL='https://<pages>/miniapp/?api=https://<project>.supabase.co/functions/v1/mora-telegram' \
//   node cloud/telegram/setup.mjs
//
// Widgets and their requests (widget_query) are part of Bot API 10.4. A webhook
// left on the 10.4 beta server is removed, so updates come only from the stable API.
const env = (name) => process.env[name] || (console.error(`Set ${name}`), process.exit(1));
const token = env('TELEGRAM_BOT_TOKEN'), secret = env('TELEGRAM_WEBHOOK_SECRET');
const functionUrl = env('MORA_FUNCTION_URL').replace(/\/+$/, ''), miniApp = env('TELEGRAM_MINIAPP_URL');
const stable = 'https://api.telegram.org', beta = 'https://api.telegram.org/beta';
if (!/^[A-Za-z0-9_-]{1,256}$/.test(secret)) { console.error('TELEGRAM_WEBHOOK_SECRET: 1-256 characters A-Z, a-z, 0-9, _ and -'); process.exit(1); }
if (!miniApp.startsWith('https://')) { console.error('TELEGRAM_MINIAPP_URL must be an https:// address'); process.exit(1); }

async function call(base, method, params = {}) {
  const response = await fetch(`${base}/bot${token}/${method}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(params) });
  const body = await response.json().catch(() => ({ ok: false, description: `HTTP ${response.status}` }));
  if (!body.ok) throw new Error(`${method}: ${body.description}`);
  return body.result;
}

const me = await call(stable, 'getMe');
console.log(`Bot @${me.username}`);
const webhook = { url: `${functionUrl}/webhook`, secret_token: secret, allowed_updates: ['message', 'widget_query'], drop_pending_updates: true };
await call(beta, 'deleteWebhook').catch(() => {});
await call(stable, 'setWebhook', webhook);
await call(stable, 'setMyCommands', { commands: [
  { command: 'start', description: 'Кнопка формы и виджет' },
  { command: 'widget', description: 'Прислать виджет для быстрых записей' },
] });
await call(stable, 'setChatMenuButton', { menu_button: { type: 'web_app', text: 'Добавить', web_app: { url: miniApp } } });
const info = await call(stable, 'getWebhookInfo');
console.log(`Webhook: ${info.url}${info.last_error_message ? ` (last error: ${info.last_error_message})` : ''}`);
console.log(`Done. For the widget's "Новая трата" button, enable the Main Mini App in @BotFather (Bot Settings → Configure Mini App) with the same URL and set TELEGRAM_MINIAPP_LINK to https://t.me/${me.username}.`);
