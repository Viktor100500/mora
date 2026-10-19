# Changelog

## Unreleased

- Build future public releases for Apple Silicon only, using local pre-release tests instead of rerunning tests in the release workflow.

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
