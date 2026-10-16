# Development

Mora is source available under [LICENSE](LICENSE), not a permissively licensed open-source project. Reports, reproducible synthetic examples and suggestions are welcome. Before submitting code intended for incorporation, contact the maintainer to agree on the contribution's licensing; do not assume that publishing a pull request assigns copyright.

## Local checks

Use macOS 14+ and Swift 6. Run `swift test`, then `zsh scripts/build-app.sh`. MCP dependencies are optional and pinned in `mcp/requirements.txt`; `zsh scripts/setup-mcp.sh` creates a local environment and launch configuration.

Keep tests offline, temporary and synthetic. Never point tests at a real ledger or cloud project. The optional PostgreSQL integration test is described in [cloud/README.md](cloud/README.md).

Enable the local guards after cloning: `git config core.hooksPath .githooks`.

## Before a commit

```sh
git add <specific-public-files>
python3 scripts/check-publication.py
git diff --cached --stat
git diff --cached
```

The publication check reads the exact Git index. `--tree HEAD` inspects the committed tree. Unknown top-level files, generated output, personal machine paths, live project addresses and common credential formats are rejected. It is a conservative guard, not a substitute for review. A local `.build/publication-denylist.json` may contain an additional JSON list of exact private strings; it is ignored by Git.

Do not force-add ignored financial files. Use a GitHub no-reply commit address if you do not want your personal email in public history. GitHub's repository setting does not retroactively remove data from commits.
