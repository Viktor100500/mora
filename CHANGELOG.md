# Changelog

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
