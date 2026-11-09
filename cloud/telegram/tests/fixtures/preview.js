// Offline preview only. This replaces the Telegram SDK in the generated demo;
// production index.html never imports it and never exposes mock purchases.
(function () {
  var context = {
    base_currency: 'USD', default_account_id: 'daily',
    accounts: [{ id: 'daily', name: 'Повседневный', currency: 'USD' }, { id: 'travel', name: 'Поездки', currency: 'EUR' }],
    categories: [{ id: 'food', name: 'Продукты' }, { id: 'coffee', name: 'Кафе' }, { id: 'transport', name: 'Транспорт' }],
    recent: [{ merchant: 'Lidl', account_id: 'daily', category_id: 'food', currency: 'USD' }],
    totals: { today: { USD: 12.5 }, month: { USD: 125 } }
  };
  var events = {};
  var state = window.__moraPreview = { purchases: [], keyboardHides: 0, mainVisible: true, failNext: false };
  var tg = {
    initData: 'synthetic-preview', initDataUnsafe: {}, colorScheme: 'light',
    MainButton: { hide: function () { state.mainVisible = false; } },
    HapticFeedback: { selectionChanged: function () {}, notificationOccurred: function () {} },
    isVersionAtLeast: function () { return true; },
    hideKeyboard: function () { state.keyboardHides++; },
    onEvent: function (name, fn) { events[name] = fn; }, ready: function () {}, expand: function () {}
  };
  window.Telegram = { WebApp: tg };
  state.theme = function (dark) {
    tg.colorScheme = dark ? 'dark' : 'light';
    var colors = dark ? { bg: '#282828', text: '#ffffff', hint: '#b4b4b4', secondary_bg: '#1c1c1c' }
      : { bg: '#ffffff', text: '#111111', hint: '#686d76', secondary_bg: '#f1f3f6' };
    Object.keys(colors).forEach(function (name) {
      document.documentElement.style.setProperty('--tg-theme-' + name.replace(/_/g, '-') + '-color', colors[name]);
    });
    if (events.themeChanged) events.themeChanged();
  };
  state.theme(new URLSearchParams(location.search).get('theme') === 'dark' ||
    (!new URLSearchParams(location.search).has('theme') && matchMedia('(prefers-color-scheme: dark)').matches));
  window.fetch = function (url, options) {
    if (!url.startsWith('https://preview.invalid/mora/api/')) return Promise.reject(new Error('Offline preview'));
    if (url.endsWith('/context')) return Promise.resolve({ ok: true, json: function () { return Promise.resolve(context); } });
    var purchase = JSON.parse(options.body);
    state.purchases.push(purchase);
    return new Promise(function (done) {
      setTimeout(function () {
        var fail = state.failNext;
        state.failNext = false;
        done({ ok: !fail, status: fail ? 503 : 200, json: function () {
          return Promise.resolve(fail ? { error: 'Тестовая ошибка: попробуйте ещё раз.' }
            : { state: 'booked', message: 'Тестовая трата: ' + purchase.merchant + ' −' + purchase.amount + ' ' + purchase.currency + '. Ничего не сохранено.' });
        } });
      }, 400);
    });
  };
  document.addEventListener('DOMContentLoaded', function () {
    var note = document.createElement('p');
    note.className = 'note';
    note.style.marginTop = '0';
    note.textContent = 'Предпросмотр ' + document.documentElement.dataset.version + ' (' + document.documentElement.dataset.build + ') · тестовые данные';
    document.querySelector('main').prepend(note);
  });
})();
