# Security and private data

Do not report secrets, credentials, personal ledger contents, bank statements or private screenshots in public Issues.

For a vulnerability, use the repository's **Security → Report a vulnerability** when private reporting is enabled. If that option is unavailable, first request a private reporting channel without including exploit details or data.

If a credential has been exposed, revoke or rotate it at its provider. Removing it from a current file does not remove it from Git history, forks, downloaded archives or caches. Coordinate any history cleanup with the maintainer.

Public builds contain no preconfigured personal cloud project or phone keys. Runtime ledgers and configuration belong outside Git. Automatic publication checks detect common accidental inclusions but cannot guarantee the absence of every secret.
