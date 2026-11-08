// Points the Telegram bot at the mora-telegram function: webhook, commands and
// the menu button that opens the Mini App. Run once after deploying, and again
// when an address changes. No dependencies (Node 18+).
//
//   TELEGRAM_BOT_TOKEN=... TELEGRAM_WEBHOOK_SECRET=... \
//   MORA_FUNCTION_URL=https://<project>.supabase.co/functions/v1/mora-telegram \
//   TELEGRAM_MINIAPP_URL='https://<pages>/miniapp/?api=https://<project>.supabase.co/functions/v1/mora-telegram' \
//   node cloud/telegram/setup.mjs
//
// The webhook is set through the Bot API 10.4 beta when it answers, so widget
// requests (widget_query) reach the function; otherwise through the stable API,
// and only the Mini App works.
const env = (name) => process.env[name] || (console.error(`Set ${name}`), process.exit(1));
const token = env('TELEGRAM_BOT_TOKEN'), secret = env('TELEGRAM_WEBHOOK_SECRET');
const functionUrl = env('MORA_FUNCTION_URL').replace(/\/+$/, ''), miniApp = env('TELEGRAM_MINIAPP_URL');
const stable = 'https://api.telegram.org', beta = process.env.TELEGRAM_WIDGET_API || 'https://api.telegram.org/beta';
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
try {
  await call(beta, 'setWebhook', webhook);
  console.log(`Webhook set through the Bot API beta (${beta}): widget requests will arrive.`);
} catch (error) {
  console.log(`The beta did not accept the webhook (${error.message}). Using the stable Bot API: the Mini App works, widget buttons will not.`);
  await call(stable, 'setWebhook', { ...webhook, allowed_updates: ['message'] });
}
await call(stable, 'setMyCommands', { commands: [
  { command: 'start', description: 'Кнопка формы и виджет' },
  { command: 'widget', description: 'Прислать виджет для быстрых записей' },
] });
await call(stable, 'setChatMenuButton', { menu_button: { type: 'web_app', text: 'Добавить', web_app: { url: miniApp } } });
const info = await call(stable, 'getWebhookInfo');
console.log(`Webhook: ${info.url}${info.last_error_message ? ` (last error: ${info.last_error_message})` : ''}`);
console.log('Done. For the widget\'s "Новая трата" button, create a Mini App link in @BotFather (/newapp) with the same URL and put it in TELEGRAM_MINIAPP_LINK.');
