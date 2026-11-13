# Changelog

## iPhone 1.0.48 — 2026-11-14

iPhone 1.0.48 (build 49) · Mac unchanged (1.7.19, build 98)

- **Screens end above the tab bar.** The floating bar now lives in the tab controller's own view, at the real bottom edge, and each tab reserves its height through UIKit's safe area. Overview, Transactions and every other screen, including pushed ones, scroll to their last row above the bar. 1.0.47's SwiftUI inset never reached the screens, and its bar sat 34 points higher than its reserved space.
- **Native Liquid Glass lens, also with Reduce Motion.** Like Telegram, the bar drives UIKit's own tab lens directly: it lifts as refracting glass on touch, follows the finger, and settles on the chosen tab with UIKit's lift and move springs. Reduce Motion no longer turns it off. This replaces 1.0.47's hand-made lens, which jumped between touch events.

## iPhone 1.0.47 — 2026-11-13

iPhone 1.0.47 (build 48) · Mac unchanged (1.7.19, build 98)

- **Content stops above the tab bar.** Each tab now reserves the floating bar's height in its own bottom safe area, so every screen, including pushed ones, scrolls to its end above the bar instead of under it.
- **Liquid Glass tab bar with Reduce Motion.** The bottom bar is now a custom Liquid Glass capsule. Its selection pill and glass lens slide with explicit animations that keep working when Reduce Motion is on; the selection never extends over neighbouring tabs.


## 1.7.19 — 2026-11-13

Mac 1.7.19 (build 98) · iPhone 1.0.46 (build 47)

- **Compact iPhone footer.** Removes the 64-point spacer below storage status and raises only its caption by 12 points, restoring compact Overview and More screens.
- **More bank formats.** Reads Raiffeisen push fields separated by bars and `Gde`, Russian amounts such as `450р`, MIR card endings and SBP messages. Adds setup instructions for reading payment screenshots through Shortcuts.
- **Conservative SMS/push matching.** A pair must have the same explicit source, merchant, card ending, currency and amount within ten minutes, different wordings, and exactly one eligible match. Missing fields, different banks or merchants, ambiguous matches and repeated identical wordings remain separate. Wallet notification handling is preserved.


## 1.7.18 — 2026-11-13

Mac 1.7.18 (build 97) · iPhone 1.0.45 (build 46)

- **Wallet notification action restored.** Restores `Log Wallet Notification` with the same intent and Title, Subtitle and Body parameters as the 9 November preview. The three Wallet changes remained on `feature/wallet-transit-notification` and were absent from subsequent main builds.
- **Card names stay cards.** A known card passed only as Wallet's Name is recovered from the local journal. An unverified Name without a card is never sent as a merchant; explicit card names and generic transaction placeholders are excluded too. Review forms do not suggest an earlier amount for a merchant that equals the supplied card.
- **Delayed transit prices.** Restores completion from Wallet notifications, retaining the tap's event ID, card and time. Incomplete taps wait up to 20 minutes for a delayed notification. Ambiguous taps and known card mismatches wait for review instead of taking another purchase's amount.


## iPhone 1.0.44 — 2026-11-12

iPhone 1.0.44 (build 45)

- **Storage status spacing.** Adds bottom clearance below the local/shared-data status on Overview and More so the floating iPhone tab bar does not cover it. Tab interaction and Reduce Motion behavior are unchanged.

## iPhone 1.0.43 — 2026-11-12

iPhone 1.0.43 (build 44)

- **Gentler tab switching.** The native glass reacts to touch while the screen changes only on release; cancelling the touch keeps the current screen. A short opacity fade softens screen changes, including with Reduce Motion, without moving or scaling the content. VoiceOver activation and repeated-tab actions remain available.
- **Tab spacing.** Adds a little more room between the five native tab items while keeping full localized labels and stable geometry throughout selection.

## iPhone 1.0.42 — 2026-11-11

iPhone 1.0.42 (build 43)

- **Stable native tab bar.** Uses a real system UITabBar with constraints set before selection animations. Removes the post-transition frame changes that made icons jump. Keeps all five full localized labels, native Liquid Glass selection and existing screen navigation.

## iPhone 1.0.41 — 2026-11-11

iPhone 1.0.41 (build 42)

- **Native tab bar restored.** Removes the custom tab strip and restores the system selection, labels, badges and Liquid Glass switching. Widens only the native bottom bar by 16 points on narrow iPhones, giving its icons more room while preserving screen layout. Visa caching and Wallet loading fixes remain.

## 1.7.17 — 2026-11-11

Mac 1.7.17 (build 96) · iPhone 1.0.40 (build 41)

- **Visa fallback.** Successful quotes persist per currency pair across restarts. Same-day quotes are reused; after a failed refresh or a 25-second total deadline, purchases use the last successful quote for that direction and record its original date in the note. Failed pairs wait one minute before retrying. Existing quotes migrate automatically.
- **iPhone Wallet loading.** The purchase spinner runs only during automatic booking and stops while waiting for a retry. Pending purchases no longer bypass the cloud retry delay.
- **iPhone tab bar.** The Liquid Glass tab bar keeps each selection inside its button with an 8-point gap between tabs. Older iOS versions retain the native bar.

## 1.7.16 — 2026-11-10

Mac 1.7.16 (build 95) · iPhone 1.0.39 (build 40)

- **Merchant categories.** History and shortened regional directory names now recognize known New York/New Jersey location endings, including city/state variants. For example, `SQ * Dan Bakery Hoboken` can match `Dan Bakery` in history and `DÄN BAKERY & CAFÉ` in the directory. Conflicting categories and unknown directory types still block inferred matches; explicit rules and exact history keep priority.

## 1.7.15 — 2026-11-10

Mac 1.7.15 (build 94) · Telegram form 1.7.15 (94)

- **Telegram bot.** Uses the released Bot API 10.4 for the chat widget. "Новая трата" and "Подробнее" open the form directly through the bot's Main Mini App link. The widget's buttons and the purchase celebration use Mora's green palette.
- **Categories for converted purchases.** A Telegram purchase in another currency than its account keeps the category and note chosen in the form while it waits for the Visa conversion; Mora books it with that category unless a different one is chosen during review. Requires the `telegram_capture_category` cloud migration.
- The bot's settings can live in Supabase Vault (`telegram_bot_settings` migration), so it can be configured without the Supabase CLI. The direct link has a cover in Mora's style.

## 1.7.14 — 2026-11-09

Mac 1.7.14 (build 93) · Telegram form 1.7.14 (93)

- **Telegram purchase form.** Uses a persistent green page button with readable white text instead of Telegram's native bottom button. The action stays visible on short screens and above the on-screen keyboard.
- A Done action, tapping outside a text field, or pressing Return dismisses the keyboard. Selecting a category, currency, account, date or recent merchant no longer returns focus to the amount. Existing amounts are preserved.
- Retains the published form's embedded server address, network error messages and purchase celebration. Preview fixtures and browser checks use synthetic purchases only.

## 1.7.13 — 2026-11-09

Mac 1.7.13 (build 92)

- **Apple Pay review in Settings.** Purchases awaiting review appear directly in the Shared Database and Apple Pay block, without opening cloud configuration.
- Review notifications open the main window's Settings and scroll reliably to the review block, including first-time and repeated navigation.
- Each pending purchase has its own outlined card, a clear prompt and a prominent review action. After scrolling finishes, the cards briefly glow orange to draw attention to the required input.

## 1.7.9 — 2026-11-09

Mac 1.7.9 (build 88) · iPhone 1.0.38 (build 39)

- iPhone: bundles the signed Mora Apple Pay automation for iOS 27, with its Transaction trigger and both Mora actions already connected. Select your Wallet cards, enable the automation, and check the first payment in Mora. The template has no phone key or selected cards; its signing certificate expires on 8 December 2027.

## 1.7.8 — 2026-11-09

Mac 1.7.8 (build 87)

- **Telegram bot for purchases.** A new optional Supabase function, `mora-telegram`, records purchases from a strict form in a Telegram Mini App: amount, currency, merchant, category, account and date, with no free-text parsing. A Telegram HTML bubble widget offers recent merchants with a keypad. Purchases in the account's currency are booked at once with their category and the account's purchase fee; other currencies wait in the inbox for the Visa conversion. Requires the `telegram_bot` cloud migration after `same_currency_purchase_fee`. Setup is in `cloud/telegram/README.md`.

## 1.7.6 — 2026-11-08

Mac 1.7.6 (build 85) · iPhone 1.0.37 (build 38)

- **Purchase fees.** Accounts can set separate percentages for expenses in the account currency and for currency conversion. Changing either fee recalculates existing expenses from their recorded original amounts or saved exchange rates. New expenses include the applicable fee.
- Legacy split foreign-currency expenses lack per-part exchange details; changing their conversion fee is blocked rather than recalculating them incorrectly.
- Requires the `same_currency_purchase_fee` cloud migration and updated Mora versions on all shared devices before enabling the new fee.

## 1.7.5 — 2026-11-08

Mac 1.7.5 (build 84)

- **Transaction diagnostics.** The local diagnostic log records data refreshes and filtered-list updates to help investigate intermittent freezes.

## 1.7.4 — 2026-11-08

Mac 1.7.4 (build 83)

- **Cloud sync diagnostics.** A local, size-limited log records sync stages and cancellation codes without financial data or credentials.

## 1.7.3 — 2026-11-08

Mac 1.7.3 (build 82)

- **Cloud sync.** Cancelled network requests no longer appear as errors, and background sync can retry promptly.

## 1.7.2 — 2026-11-08

Mac 1.7.2 (build 81)

- **Purchase review dates.** Wallet purchases awaiting review show their transaction date and time in the list.

## 1.7.1 — 2026-11-07

Mac 1.7.1 (build 80)

- **Settings layout.** The AI agent picker in Settings → AI Assistant lines up with the Copy buttons below it again, instead of stopping short of the right edge.

## 1.7.0 — 2026-11-07

Mac 1.7.0 (build 79) · iPhone 1.0.33 (build 34)

### Mac

- **Sidebar width stays within limits.** Dragging the divider now stops at the narrowest and widest sidebar width instead of letting it squeeze or stretch without limit. The narrowest width always keeps menu items such as Categories and Rules and Import History on one line.
- **Net worth is always shown in full.** The Net Worth amount at the bottom of the sidebar is no longer cut off with an ellipsis. Long amounts (tens of millions with kopecks, in any currency) shrink smoothly to fit, and if an amount still does not fit at the smallest size, the sidebar becomes wider. Hiding amounts does not change the layout.

### iPhone

- **One list of Apple Pay purchases to review** (1.0.31). Purchases saved on the iPhone and those waiting in the shared database now form a single Purchases to Review screen in More, so the counts always agree. The overview shows how many are waiting and opens the list; the More tab badge counts both. Swiping deletes a purchase after a confirmation instead of hiding it.
- **Reliable pull to refresh** (1.0.32). A sync is no longer reported as "cancelled" when the screen redraws during a pull to refresh, and a deleted purchase to review disappears at once instead of briefly coming back.
- **Back to the top** (1.0.33). Tapping the open Overview or Analytics tab again scrolls back to the top with the large title expanded, like Transactions and Accounts.

## 1.6.40 — 2026-11-04

- Mac: an opaque Mora launch screen with a softly glowing particle network. Nearby particles connect with brighter lines and move away from the pointer. The screen fades into the ready app without an added delay; Reduce Motion keeps the network still. The welcome sheet appears after the transition.

## 1.6.39 — 2026-11-04

- iPhone 1.0.26: purchases from bank text messages and, on iOS 27, bank app notifications. A Shortcuts "Message" or "Notification" automation passes the text to the new Mora action Log Bank Message. One-time codes, fraud checks, declines and offers are skipped without saving their text. The first message of a new format waits under More → Bank Texts and Notifications: check the amount and pick the merchant by tapping words, and Mora remembers the format so later messages are sent to the shared database automatically. Cards are named after the sender and last four digits, for example `Raiffeisen ··5109`, and are linked to an account once like Wallet cards.
- Bank messages and the Wallet automation work together: a purchase reported by both is recorded once, and a bank amount completes a Wallet purchase that arrived without one (transit taps).

## 1.6.36 — 2026-11-01

- Multi-currency Wallet cards: besides its main account, a card can have one account per other currency. A purchase in that currency is booked to that account (for example RSD to the dinar account, USD to the dollar account); other currencies go to the main account with the usual Visa conversion. Set them when turning on Apple Pay on the iPhone (iPhone 1.0.22) or later in Apple Pay cards; waiting purchases are routed again. Requires the `wallet_card_currency_accounts` migration.
- Wallet amounts with any three-letter currency code, such as `RSD 1,234.00`, are recognized on the server and in automatic booking; previously only a fixed list of currencies was.

## 1.6.35 — 2026-11-01

- iPhone 1.0.21: Apple Pay on this iPhone fills in every card already used on this iPhone from Wallet runs, so only accounts need to be chosen. iOS gives apps no list of Wallet cards; the names come from the Card or Pass value of past payments.

## 1.6.34 — 2026-11-01

- iPhone 1.0.20: a ? button next to the Wallet card name explains that it is the Card or Pass value of the payment, and names already seen in Wallet runs are offered to fill in with one tap. The Mac card field shows the same explanation as a tooltip.

## 1.6.33 — 2026-11-01

- iPhone 1.0.19: Apple Pay without a shortcut file. In Shared database → Apple Pay on this iPhone, choose Wallet cards and accounts; Mora creates the phone key itself and keeps it in the Keychain. The Log Wallet Payment action then saves each purchase on the iPhone first and sends it, also on a locked iPhone, without failing the automation. Offline purchases are retried with the same event id on the next payment or when Mora opens; a purchase not sent within 15 minutes waits for Send to Mora or Already entered by hand, so it never duplicates a manual entry. Purchases without amount or merchant are never sent. Wallet runs show every run and its delivery. Mora warns two days before its development signature expires.
- Mac: the iPhone shortcut setup explains that it is not needed when Mora is installed on the iPhone.

## 1.6.32 — 2026-11-01

- iPhone 1.0.18 (build 19).
- Archiving an account preserves its recorded income, expenses, transfers, history totals, category reports, budgets, charts, and spending calendar on Mac and iPhone. New entries and Wallet booking still require an active account.

## 1.6.31 — 2026-11-01

- iPhone 1.0.17: Accounts tab rows put the account name on its own line across the full row width, with the type and balance below, so names fit on small iPhones and with large text.

## 1.6.30 — 2026-11-01

- iPhone 1.0.16: Mora registers an App Shortcut for Log Wallet Payment, so iOS lists the action under Mora in Shortcuts right after installation.

## 1.6.29 — 2026-11-01

- iPhone 1.0.15: new Shortcuts action Log Wallet Payment. Placed first in the Wallet Transaction automation, it saves the amount, merchant and card on the iPhone without opening Mora, also on a locked iPhone, and never fails the automation. Shared database → Wallet runs lists every run, so a failed payment shows whether the automation reached Mora at all. Nothing is sent to the server yet.

## 1.6.28 — 2026-11-01

- Mac: notification text uses the available width and wraps onto multiple lines, so transaction details and multiple operations are readable without premature truncation.

## 1.6.27 — 2026-11-01

- iPhone 1.0.14: pull to refresh in Overview and Transactions (and Sync now in Shared database) synchronizes with the shared database right away and reports the result — completed, purchases to review, canceled or failed — like Reload on the Mac.
- Mac: a saved change goes to the shared database right away instead of waiting for the next eight-second poll, and a lost connection retries within 30 seconds instead of backing off for minutes, as on the iPhone.
- Mac: connect Claude, ChatGPT or another MCP client through the shared database in Shared database and Apple Pay → Import with an AI agent, as in More → Import via AI on the iPhone. The connection address is shown once; agents can be disconnected at any time.
- iPhone: Apple Pay cards are always listed in Shared database and explain that the shortcut with cards and accounts is created by Mora on a Mac.

## 1.6.26 — 2026-11-01

- Mac: configure Wallet card names and their accounts before creating a quiet, locally signed iPhone shortcut in Shared database and Apple Pay. New configured keys hold unidentified cards for explicit account choice; new cards wait for linking. Existing purchases are unchanged.
- Fix the five-second sender omitting the payment card. It now reads and sends Card or Pass with the same delayed fallback as amount and merchant; transaction notes include the card.

## 1.6.25 — 2026-11-01

- Mac and iPhone 1.0.13: optionally edit a transaction’s hour and minute under Transaction time to put purchases in their actual order within a day. Lists and Mac transaction details show the time. Changing only the calendar date or another field preserves the original timestamp, including Wallet and imported seconds.

## 1.6.24 — 2026-11-01

- Mac and iPhone 1.0.12: a complete Apple Wallet purchase no longer flashes as “waiting for review” while it is being booked. Purchases that can be booked automatically stay out of the review inbox, badges and notifications until booking has been tried; meanwhile a “Loading Wallet purchases…” banner is shown. Only a purchase that really needs the user, or whose booking failed, appears for review.

## 1.6.23 — 2026-10-31

- iPhone 1.0.11: stay signed in to the shared database after app updates. The Keychain session was stored under the absolute data path, which iOS changes on every update, so the iPhone silently stopped syncing and showed the sign-in screen. The session now uses the path inside the app container, and a session saved under an earlier path is moved over automatically.

## 1.6.22 — 2026-10-31

- Mac: show an animated Reset filters button in Transactions when search, type, account, category or dates differ from the defaults. Match the other toolbar buttons and reset to all transactions in the current month.

## 1.6.21 — 2026-10-31

- Mac: show a success or error notification after Reload finishes, including unchanged data and repeated connection failures. Keep routine background checks quiet.
- Mac: use Mora green for the Wallet loading notification border.

## 1.6.20 — 2026-10-30

- Mac: add a circular Reload button to the right of Import for immediate cloud synchronization, with a loading indicator and a tooltip explaining its purpose.

## 1.6.19 — 2026-10-30

- Apple Wallet: add a quiet five-second sender (`--wallet-delay`) with no diagnostic notifications, keeping the amount/merchant checks. Delivery still requires internet; the five-second delay is not an offline queue or retry scheduler.

## 1.6.18 — 2026-10-30

- iPhone 1.0.10: send a saved change to the shared database right away instead of waiting for the next poll, and give it background time to finish when the app is closed right after saving. Lost connections retry within 30 seconds instead of backing off for minutes, and returning to the app retries at once.

## 1.6.17 — 2026-10-30

- Apple Wallet shortcuts: send a purchase only when both amount and merchant contain text. The five-second diagnostic still reads the original input twice and preserves available values, but skips delivery when either field remains empty. Independent complete purchases retain separate event IDs.

## 1.6.16 — 2026-10-29

- Mac and iPhone: recognize the Whole Foods bank abbreviation `WHOLEFDS` with branch codes and store numbers as groceries, including automatic Apple Wallet booking. The Mac also fills existing uncategorized purchases; manual categories, rules and Undo choices retain priority.

## 1.6.15 — 2026-10-27

- iPhone: connecting to a Mac is animated like AirDrop — a radar with nearby Macs floating around the iPhone, a beam between the devices and a glowing screen edge while you compare the code, then a burst of light and a check mark with a haptic. Reduce Motion keeps it still.
- iPhone onboarding: "Connect to Mac" next to "Create your first account" joins the shared database right away; a project without anonymous sign-ins opens the prefilled sign-in screen.

## 1.6.14 — 2026-10-27

- Mac: fix a launch crash when restoring a shared database connection. The iPhone pairing prompt now receives its store explicitly instead of looking outside its SwiftUI environment.

## 1.6.13 — 2026-10-27

- iPhone: the expense calendar in Analytics → Dates selects a period: tap the first and last day and every day in between is picked. "Separate days" keeps the old tap-to-toggle choice.
- iPhone: spending per day is now a small orange bar under the amount instead of a stronger green fill, so the most expensive day no longer looks selected; selected days are solid green.

## 1.6.12 — 2026-10-27

- Connect an iPhone to the shared database like AirDrop: on the iPhone choose Shared database → Connect to Mac, check that the Mac shows the same six-digit code and click Allow. Over an encrypted local channel (Bonjour, X25519 with a key commitment, ChaChaPoly) the Mac sends the project address, publishable key and a one-time invitation; the iPhone signs in anonymously and opens the household with nothing typed. Without anonymous sign-ins the iPhone's sign-in form is prefilled instead.

## 1.6.11 — 2026-10-27

- Import via AI agent through the shared database: the new `agent_import` migration and the `mora-mcp` Supabase Edge Function give Claude, ChatGPT and other MCP clients a remote MCP server. `get_mora_context` reads accounts, categories and recent transactions; `add_transactions` validates every row and records new ones as one import that can be rolled back. Each connection has its own revocable key.
- iPhone: More → Import via AI connects and disconnects agents, shows the connection address once with setup steps, and copies a ready request.

## 1.6.10 — 2026-10-27

- iPhone: transaction descriptions wrap to two lines instead of being cut off.
- iPhone: add "Feedback and help" to More: write to support (the subject includes the app and iOS versions) or copy the address.

## 1.6.9 — 2026-10-27

- iPhone: choose any ISO currency with search by code or name (Russian or English) in onboarding, account editing and CSV import; the region's currency and popular ones come first.
- iPhone: the separator above the month totals in Transactions spans the whole card again.

## 1.6.8 — 2026-10-27

- Combine two or more categories under 5% of expenses into one "Other" sector in category rings on Mac and iPhone; the lists below keep every category.
- iPhone: show the spending calendar only for the "Dates" period, right below the period picker; long account names wrap instead of being cut off.
- iPhone: add `scripts/install-ios.sh` to build, sign and install Mora on a connected iPhone; the development team lives in the untracked `iOS/Local.xcconfig`.

## 1.6.7 — 2026-10-27

- Add Mora for iPhone (`iOS/`, iOS 17+): overview, transactions with filters and bulk actions, transaction entry with Visa conversion, analytics with a spending calendar, accounts, categories and rules, budgets, goals, recurring payments, CSV import and import history, JSON backups, undo and redo, and the shared Supabase database with the Apple Pay inbox. It reuses `FinanceCore` and the Mac ledger format; the interface language follows the iPhone.
- Build `FinanceCore` for iOS: the Visa calculator no longer requires AppKit, and UI translations accept app-specific supplements. The Mac app's behavior is unchanged.

## 1.6.6 — 2026-10-27

- Commit the first reviewed purchase and its card-to-account choice atomically, and keep historical amount suggestions in the known purchase currency.

- Use one Apple Pay key per person for all of their cards: the Shortcuts sender passes the Wallet card name, a new card appears after its first purchase, and its purchases wait until an account is chosen in the review form or the new Apple Pay cards list. Purchases without a card name keep the key's main account; older senders keep working.
- When Wallet starts the automation before the purchase is priced (transit, deferred authorizations), keep the purchase in the inbox and prefill the last amount paid at the same merchant in its original currency for one-click confirmation. No merchant- or city-specific rules.
- Add the `wallet_cards` Supabase migration with card listing and linking RPCs and integration checks.

## 1.6.5 — 2026-10-27

- Report a cloud connection outage once, retry silently, and notify when the connection is restored.

## 1.6.4 — 2026-10-26

- Keep the center of category charts clear while preserving contrast around light-colored sectors.

## 1.6.3 — 2026-10-26

- Add a subtle backdrop to category expense rings and legend dots so light colors remain visible.

## 1.6.2 — 2026-10-26

- Isolate transaction scrolling from the surrounding screen while retaining lazy rows and the visible position.
- Match card spacing throughout the app to the overview and allow overview metric descriptions to wrap at narrow widths.

## 1.6.1 — 2026-10-26

- Keep transaction entry responsive by recalculating balance previews only for relevant financial changes and updating the preview independently.

## 1.6.0 — 2026-10-26

- Select Xcode 26.3 explicitly for macOS CI and release builds so macOS 26 APIs compile even when the runner defaults to Xcode 16.4.

- Dismiss all completed notification banners after seven seconds, including warnings, errors and transient notices; preserve history and available actions.
- Morph dashboard trend curves through one fixed-topology path when changing aggregation; retain real bucket values for accessibility and hold the plot inset steady.
- Fade duplicated transaction rows into a lazily rendered scroll view, preserve the viewport anchor and switch selection to the copies only with their filtered rows. Preserve insertion order for identical rows so random UUIDs cannot put a new copy above its original.

- Float notifications over the whole window with short fade/settle transitions; keep notices and exchange-rate warnings out of page layout so they never push content down.
- Keep previous report results visible while recalculating a new ledger generation, publish complete report groups together, and prepare initial balances before dismissing the launch loader.
- Smooth financial text, chart, transaction-row and page updates, respect Reduce Motion, and avoid flashing an empty transaction screen while its first search runs. Prepare the next month or analysis scope before changing the visible selection.

- Fit the transaction preview to its actual balance and quote lines while keeping loading/error states stable; remove excess space above the save buttons.
- Replace the transaction table header with selection actions in the same footprint, with a compact actions menu at narrow widths, so checking rows never shifts the list or filters.

- Retain transaction filters when switching sections; combine several types, accounts and categories with checkbox popovers and explicit select-all/clear-all behavior.
- Replace separate date fields with one period control and a compact month calendar, highlighted ranges, month/year navigation and quick presets.

- Keep the transaction preview footer stable during Visa loading; show the potential account balance before saving, including conversion fees, edits, future dates and both transfer legs.
- Persist Visa rates for each purchase date and currency direction until the next UTC day, share concurrent requests and reuse the rate immediately as the amount changes.

- Preserve the incoming Wallet purchase date when reopening the review form, initialize the native date field before editing, and isolate form state by purchase identity.
- Order transaction fields as account, type, amount, purchase currency and name; show account currencies first in the purchase currency menu.
- Close new, edited and reviewed transaction forms immediately after submission; save in the background with standard progress/success/error notifications and a retry action that retains submitted fields. Keep full ledger/history snapshots out of transaction-row rendering.
- Finish native date-field editing before disabling a saving or terminating form, preventing an AppKit/SwiftUI focus-navigation cycle that can hang the main thread.

- Keep production Wallet senders silent, retire the five-second diagnostic setup from installation instructions, and recommend extracting Wallet fields inside the transaction automation before passing a plain dictionary to the sender.
- Expand the local merchant directory with the complete NYC restaurant-name feed, preserve branch names and match short multiword bank descriptors correctly; cover THISBOWL Noho, The Wild and the exact Perk House spelling while retaining ambiguity and manual-choice protections.
- Infer supported Wallet currencies from formatted amounts on the server when Shortcuts cannot provide a separate currency field; keep foreign-currency captures queued for Mora conversion and leave ambiguous symbols for review.
- Build future public releases for Apple Silicon only, using local pre-release tests instead of rerunning tests in the release workflow.

## 1.5.18 — 2026-10-24

- Reuse the existing notification system for Wallet import progress and completion; keep empty sync checks and previously reported unresolved purchases quiet.
- Hide successful import notices automatically, update review counts as purchases are corrected, and clear resolved Wallet warnings and unread indicators.

## 1.5.17 — 2026-10-24

- Add a bundled, locally matched regional merchant directory generated from Overture Places and the New York State Retail Food Stores open dataset, with 171,649 source-derived names/types and no per-merchant expense overrides. Keep source licenses and a reproducible extraction script with the app.
- Import NSI transit networks/operators and recognize contactless pay-as-you-go descriptors while keeping short network names from becoming arbitrary merchant prefixes.
- Retain independently validated brand feeds on disk, use the last good data during outages, and distinguish missing merchants from missing expense categories. Preserve user history, manual edits and Undo.

## 1.5.16 — 2026-10-24

- Keep a synchronization notice visible at startup while new purchases download and convert in the background. Recheck the server version and pending purchases before finishing, including purchases arriving during the current batch.
- Publish the final transaction list, categories and Wallet review notifications together instead of refreshing after each purchase; preserve durable writes and concurrent local edits, and report incomplete synchronization on failure.
- Apply automatic categories in one coordinated change and keep unchanged background polls quiet.

## 1.5.15 — 2026-10-21

- Equalize the spacing between the three floating toolbar controls.
- Clear the last selected calendar day on a repeated click and move selected-date transactions into a separate card below category spending.
- Give analytics one shared period control for the income/expense chart, category donut and category totals, with a common date scope and background report calculation.
- Place category hover cards beside the donut, outside every sector, and show the category icon and color.
- Switch to Selected dates after calendar clicks and give all unselected expense days the same fill, independent of spending size.
- Keep category tiles the same height when long names wrap in a narrow window.
- Preserve a transaction's exact time when editing its category or other fields; changing the day retains its clock time, and new manual/similar purchases retain their creation time.

## 1.5.14 — 2026-10-21

- Rebuild transaction filters with aligned 40-point controls and integrated date labels; align row checkboxes with category icons, show notes as secondary truncated text and open full details from the context menu.
- Open accounts from the sidebar net-worth card and combine sync status and the exchange-rate source into one footer line.
- Align chart detail switches with their headings and legends with the plot; move the expense calendar above analytics charts and compare its selected days using the Selected dates mode.
- Show five category legend entries and category, amount and share tooltips for every donut sector.
- Remove the window title, toolbar-wide background and scroll-edge overlay; keep only the floating Import, New transaction and Notifications controls with their own Liquid Glass surfaces.

## 1.5.13 — 2026-10-21

- Give the dashboard cash-flow icon the same rounded background and size as the metric-card icons; use the standard body font for the All analytics and All transactions links.
- Enlarge edit buttons in transactions, accounts, categories and categorization rules to match the 36-point circular Liquid Glass toolbar controls.
- Make every disclosure header an outlined button that expands or collapses from its text, arrow or padding, including import transactions, saved change-history steps and cloud setup details.
- Add Months, Weeks and Days detail switches to the overview cash-flow chart and analytics income/expense chart, with Monday-based weeks and daily totals within the selected month prepared in the background.
- Replace the transactions month selector and All time switch with an inclusive date range; export the displayed filtered rows with one action, remove the ambiguous column header and show expandable user notes below each transaction.

## 1.5.12 — 2026-10-21

- Select individual expense-calendar days with Ctrl/Command-click and inclusive ranges with Shift-click; show transactions for all selected days and clear the selection when changing months.

## 1.5.11 — 2026-10-21

- Reuse merchant history across payment prefixes and optional store descriptors, such as “Test Deli” and “Test Deli Market”, only when the matching variants agree on a category. Exact history and explicit rules retain priority.
- Display transfer currencies as read-only suffixes inside the debit and credit amount fields instead of a separate currency row.
- Restrict manual transaction amounts to decimal digits and either decimal separator; never interpret mixed separators as thousands grouping.
- Move ledger loading, coordinated commits, history descriptions, cloud merges, reports, search, notification storage and import/prompt preparation off MainActor. Serialize mutations in an actor, publish revisioned snapshots, and cancel or reject stale search/suggestion results.
- Preserve independent edits while a transaction form is open, reject conflicting field changes and stale Undo actions, and drain accepted writes before terminating the app.
- Cache currency choices and use reusable value date format styles to reduce work during typing. Preserve immediate local text editing and resolve categories again against the committed snapshot.

## 1.5.10 — 2026-10-20

- Preview the exact next Undo/Redo step and show the saved change history, including older snapshots; describe affected purchases, categories, accounts and settings in notifications.
- Collect available Apple Shortcuts purchases as shared import batches across dates and phones, with details and batch rollback. Make collection idempotent across concurrent Macs and preserve independent edits during Undo.
- Open “Create similar” as a new purchase instead of editing a nonexistent record; retain the deleted-record and archived-account guards for real edits.

## 1.5.9 — 2026-10-19

- Make the entire Wallet review notification banner open purchases awaiting review.
- Replace the inbox wording with explicit purchase review labels in Russian and English.

## 1.5.8 — 2026-10-19

- Categorize new merchants from public Merchant Studio and OpenStreetMap NSI catalogs without API keys or sending transactions to a provider.
- Reuse explicit rules and merchant history first, leave conflicting/unknown results uncategorized, and preserve manual changes and Undo during background categorization.
- Add settings, source attribution and a verified public descriptor alias for SIREN47906 (MCC 5814).

## 1.5.7 — 2026-10-19

- Interpret a bare dollar symbol in Wallet amounts as USD while preserving explicitly supplied currency codes.
- Automatically book complete Wallet purchases during sync, using the regular Visa conversion, account fee and rounding rules. Existing pending purchases are included; failed conversions retry without creating partial transactions or duplicates.

## 1.5.6 — 2026-10-19

- Separate the Wallet purchase amount and currency from the phone/card label in the inbox; explicitly show when purchase currency is missing.
- Replace the Shortcuts modal result with a notification and add an optional startup diagnostic notification before reading Wallet fields.
- Document separate diagnosis for a missing Wallet trigger, a local Shortcuts failure and a delivered purchase awaiting currency review.

## 1.5.5 — 2026-10-19

- Use matching Liquid Glass materials and heights for Import, New transaction and Notifications; increase the toolbar's trailing inset.

## 1.5.4 — 2026-10-18

- Remove required-field asterisks; highlight missing fields after saving and disable Save until the next form edit.
- Give the day/month/year control enough width for the full date and stepper.
- Increase import button padding and give New transaction and Notifications matching circular Liquid Glass controls.

## 1.5.3 — 2026-10-18

- Start transaction entry with the account; show the currency only after an account is selected, default to its actual currency code and keep currency optional.

## 1.5.2 — 2026-10-18

- Suggest tags from saved transactions when focusing the tags field; filter while typing and select multiple tags without case duplicates.
- Mark required transaction fields and explain missing or invalid values beside each field after attempting to save.
- Preselect the only active account or the most recently used active account for new manual transactions.

## 1.5.1 — 2026-10-18

- Copy the support email address with a confirmation when clicked; keep the feedback button opening the email app.
- Make AI import automatic: use available MCP, the bundled native bridge without MCP installation, or a CSV file for import.
- Keep the original AI import dialog, open native ChatGPT with a prefilled draft, and leave an editable request section for chat instructions and attachments.
- Collect missing import details in one question and interpret selected screenshot rows as new imports unless correction is explicitly requested.

- Keep background cloud polling silent when the data has not changed.
- Review Wallet purchases in the full transaction form, including currency conversion, category, notes and tags; save atomically without duplicate transactions.
- Accept formatted Wallet amounts and explain missing purchase currencies accurately.
- Suggest categories from merchant rules, previous transactions and familiar merchant names.
- Add persistent notification history with available actions and a review indicator in the main window.
- Add quick removal of unapproved Wallet purchases.
- Show the developer contact beside feedback and add support methods with click-to-copy details.
- Separate notifications from transaction creation, align settings controls, and use day/month/year date fields with room for the full year.

## 1.5.0 — Public preview

- Load translations from the installed application bundle without depending on a development checkout.
- First-run welcome screen with Russian/English language selection and reporting currency.
- Clean personal ledger setup and a guided path to the first account.
- Per-account foreign-currency conversion fee; saved operations retain their historical fee.
- All analytics link on the Overview category card.
- Aligned controls in the account editor.
- Public installation and privacy documentation; no bundled private cloud configuration.
- Source publication checks, GitHub CI, clean release packaging and SHA-256 checksums.

The preview uses ad hoc signing and is not notarized by Apple. Wallet integration remains experimental.
