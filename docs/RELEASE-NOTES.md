Mora 1.6.0 (build 37) is a public macOS preview.

- Save new, edited and reviewed transactions in the background. The form closes immediately, standard notifications track progress and failures offer retry with the submitted fields retained for the current session.
- Preview account balances before saving, including conversion fees, future dates, edits and transfers. Cache daily Visa rates on disk, share concurrent requests and allow saving while the preview rate is still loading.
- Keep transaction filters when switching sections. Combine multiple types, accounts and categories with checkboxes, choose date ranges in a compact calendar and export exactly the filtered transactions.
- Keep notifications above the page, retain balances and charts during recalculation, and animate updates with Reduce Motion support. Dashboard lines morph between aggregation modes; duplicated transactions appear smoothly without moving the viewport or briefly losing selection.
- Match merchants locally against a bundled regional directory containing 187,072 public-source name/type records from Overture Places, New York State food stores and NYC restaurant trading names. Preserve manual categories, recognize transit descriptors, cache validated brand catalogs and explain ambiguous or missing matches. Public-source attribution and coverage details are included with the app.
- Make Wallet synchronization quieter and more reliable: process incoming purchases and categories together, include purchases arriving during a sync, retain purchase dates in review, update unresolved review counts and clear resolved warnings. Production iPhone senders use no notification or diagnostic delay.
- Include the accumulated analytics, transaction editing, import and notification improvements since the previous public preview. This release packages Apple Silicon only.

Requirements: macOS 14+ on Apple Silicon (arm64). Unzip and move Mora.app to Applications. Checksums are attached beside each ZIP.

This preview uses ad hoc signing and has not been notarized by Apple. macOS may require manual approval in Privacy & Security after you verify the download source. Do not disable system-wide security protections.

The application starts without a personal ledger, cloud project or credentials. Your data stays local unless you explicitly configure optional integrations. Wallet capture remains experimental and requires verification against bank records.

Use is governed by LICENSE. Donations are voluntary and do not transfer rights to the code.
