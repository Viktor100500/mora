# Необязательная общая база и Apple Pay

Обычный учет Mora работает локально без регистрации. Общая база требует **собственного** проекта Supabase; разработчик не предоставляет общий сервер и не получает доступ к вашей базе. В публичной сборке нет заранее настроенного проекта, учетных записей или ключей.

## Подготовить проект

1. Создайте отдельный проект Supabase.
2. Выполните файлы из `supabase/migrations/` в SQL Editor по порядку имен. В существующем проекте выполняйте только новые миграции; повторная установка начальной схемы не требуется.
3. Создайте отдельного пользователя приложения для каждого участника в Authentication. Пароли вводят сами пользователи.
4. Для частной базы отключите открытую регистрацию. Скопируйте Project URL и Publishable key. `service_role` и Secret key в приложение вводить нельзя.

Адрес, ключи, учетные записи, приглашения и пользовательские данные никогда не добавляйте в Git, Issues или скриншоты.

## Подключить Mac

1. Начните собственный учет и создайте счет. Сохраните резервную копию JSON.
2. Откройте **Настройки → Общая база и Apple Pay → Настроить**.
3. Введите параметры своего проекта, email и пароль пользователя приложения.
4. На первом Mac создайте общую базу из локального учета.
5. Для другого Mac создайте код подключения и передайте его участнику лично. Войти нужно отдельным пользователем того же проекта. Перед заменой локальной базы приложение сохраняет резервную копию.

Открытая Mora проверяет изменения примерно каждые восемь секунд. Независимые изменения объединяются; конфликтующие требуют ручного выбора. Общие данные: счета, операции, категории, планы и история импортов. Настройки отображения и история отмены остаются локальными.

## Apple Pay / Wallet

Это экспериментальная интеграция через «Быстрые команды», **не банковская синхронизация**. Следуйте [инструкции для iPhone](shortcuts/IPHONE-SETUP.md). У каждого человека один ключ телефона с доступом только на отправку покупок. Автоматизация передаёт название карты; новая карта появляется в Mora после первой покупки, и её покупки ждут, пока участник не выберет для неё счёт. Покупки без названия карты идут в основной счёт ключа.

Если сумма, продавец или валюта неизвестны, покупка попадает во входящие для проверки. Сумма бывает пустой, когда iOS запускает автоматизацию раньше, чем банк или транспортный оператор пришлёт её в Wallet. Тогда форма проверки предлагает сумму прошлой покупки у того же продавца. Сверяйте итог с выпиской. Прошлые покупки, возвраты, платежи физической картой и работа без интернета не гарантируются. Очередь повторной отправки в команде пока не реализована.

Сумма может приходить с символом валюты, например `$31.54`, или разделителями групп, например `1 234,56 €`. При пустом поле сервер определяет поддерживаемую валюту из форматированной суммы; явный код валюты имеет приоритет. `$` считается USD, `€` — EUR, `₽` — RUB. Открытая Mora автоматически обрабатывает полные покупки, включая старые входящие: получает тот же курс Visa, что форма обычной операции, применяет комиссию счета и округление в его валюте. Ручное подтверждение не требуется. При недоступности курса покупка остается во входящих до автоматической повторной попытки. Пока Mora закрыта или синхронизация выключена, сервер сохраняет такие покупки во входящие.

«Проверить» открывает ту же форму, что и новая операция: счет, сумма и название продавца предзаполняются. Источник Apple Wallet, метка телефона и время попадают в заметку. Категория предлагается по правилам, истории продавца и знакомым названиям; ее можно изменить вручную. Можно изменить валюту покупки, получить пересчет Visa, выбрать категорию, заметку и теги. Запись операции и обработка входящей покупки сохраняются в облаке вместе; повторная отправка не создает дубль. Если валюта неизвестна, выберите ее явно.

## Импорт через AI-агента (удаленный MCP)

AI-агент (Claude, ChatGPT или другой клиент MCP) записывает операции прямо в общую базу. Mora забирает их при синхронизации. Каждая запись — один импорт: его видно и можно отменить в истории импортов.

1. Выполните миграцию `supabase/migrations/20261028090000_agent_import.sql` после `wallet_cards`.
2. Разверните функцию `supabase/functions/mora-mcp` с выключенной проверкой JWT. Через CLI: `supabase functions deploy mora-mcp --no-verify-jwt`. Или в панели Supabase: Edge Functions → Deploy a new function → Via Editor. Назовите функцию `mora-mcp`, вставьте `index.ts`, выключите «Verify JWT» и разверните.
3. В Mora на iPhone откройте «Ещё → Импорт через AI → Подключить AI-агента». Mora покажет адрес вида `https://<проект>.supabase.co/functions/v1/mora-mcp/<ключ>`.
4. Добавьте адрес как коннектор. Claude: на claude.ai «Настройки → Коннекторы → Добавить свой коннектор». ChatGPT: на chatgpt.com «Настройки → Приложения и коннекторы → Расширенные → Режим разработчика», затем создайте коннектор без авторизации. Коннектор появится и в мобильном приложении.
5. В чате приложите выписку или скриншот и попросите импортировать операции в Mora. Готовый запрос есть на том же экране.

У MCP два инструмента. `get_mora_context` возвращает названия счетов и категорий, базовую валюту и операции за 60 дней. `add_transactions` добавляет до 500 операций за раз. Сервер сначала проверяет все строки: при ошибке ничего не записывается, а агент получает список проблем. Уже записанные операции пропускаются: совпадают счет, день, сумма и описание или `external_id`. Без категории применяются правила Mora. Дата без времени сохраняется полднем UTC.

Адрес подключения работает как пароль: в базе хранится только его хеш, и Mora показывает его один раз. Функция не хранит секретов и вызывает базу с Publishable key. Ключ агента может только читать перечисленный контекст и добавлять новые операции. Изменять, удалять операции и счета он не может. Отключите агента в Mora, и адрес сразу перестанет работать. Выписки и контекст счетов попадают к выбранному AI-провайдеру.

## Хранение и ограничения

- Сессия приложения хранится в Связке ключей macOS. При обновлении локально подписанной сборки macOS может повторно запросить доступ.
- По сети данные передаются по HTTPS. Сквозного шифрования нет; администратор вашего Supabase-проекта имеет доступ к данным.
- Локальные JSON-файлы и резервные копии Mora не шифрует. Используйте защиту учетной записи macOS и диска.
- Максимальный облачный снимок — 4 МБ. Это интеграция для небольшой личной или семейной базы.
- Условия, лимиты и резервное копирование зависят от вашего тарифа Supabase. Проверяйте их перед использованием.

## Проверка на синтетических данных

`cloud/tests/integration.mjs` создает временный PostgreSQL без сетевого порта. Проверяет изоляцию участников, хеши ключей, повторы, входящие и точность сумм. Включенный пример `fixtures/backend-ledger.json` синтетический.

На Apple Silicon Mac с Node и pnpm:

```sh
cd cloud/tests
pnpm install --frozen-lockfile --ignore-scripts
pnpm test
```

Тесты не должны подключаться к настоящему проекту. Установка схемы и проверка SQL не гарантируют работу автоматизации Wallet на конкретном iPhone: проверьте ее отдельно небольшой реальной покупкой.

Справка: [ключи Supabase](https://supabase.com/docs/guides/api/api-keys), [Wallet automation](https://support.apple.com/guide/shortcuts/apd65c67538a/ios).

### Wallet import history

Apply `wallet_import_batches` after the Wallet review migration. `mora_collect_wallet_import` collects all recorded, unbatched Wallet purchases currently in the household into one import, regardless of purchase date or phone. Mora calls it after loading/booking the available purchases; subsequent loads create subsequent batches. It also picks up purchases from older Mora versions. Incomplete captures stay pending until reviewed. Collection takes the existing household lock, requires membership and is idempotent across retries and concurrent Macs. It never recreates removed purchases.

Batch records use the existing import-history format, with `source: Apple Shortcuts`; the existing batch preview and rollback apply. Swift histories remain computer-local.

### Wallet cards

Apply `wallet_cards` after the currency inference migration and before installing a sender that passes `card`. `mora_capture_payment` gains an optional seventh argument `p_card`; the six-argument call is unchanged. Each new card is remembered per phone key and holds its purchases with the reason «Новая карта: выберите для неё счёт» until a member links it with `mora_link_wallet_card` (Mora does this from the review form or the Apple Pay cards list). Linking moves the card's waiting purchases to that account and recomputes their reasons; Mora then books complete ones as usual. `mora_list_pending` adds `card_id`, `card` and `card_linked`; `mora_list_wallet_cards` lists cards of active keys in the household.

The first reviewed purchase links an unassigned card and records the transaction under the same household lock and database transaction. A failed review leaves the card unlinked; a retry cannot replace an already committed purchase. Historical amount suggestions only use the known purchase currency when one was supplied.
