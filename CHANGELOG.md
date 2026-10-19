# Changelog

## Unreleased

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
