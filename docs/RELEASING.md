# Public release procedure

1. Update `Resources/Info.plist`, `CHANGELOG.md` and `docs/RELEASE-NOTES.md`.
2. Run `swift test`. Stage only application files, inspect the staged diff, and run `python3 scripts/check-publication.py` before committing.
3. Commit with a no-reply email. Check `git show --format=fuller --no-patch HEAD` for personal metadata.
4. Run `zsh scripts/build-public-release.sh HEAD`.
5. Inspect `build/releases/`: each architecture has its own ZIP and SHA-256 file. Only upload those verified artifacts. Never upload the workspace's `build/`, `outputs/`, `.build/`, local plugins or a configured iPhone shortcut.
6. Tag the tested commit, for example `git tag v1.5.0`, and push the commit and tag.
7. Run the **Release preview** workflow for that existing tag. It builds Intel and Apple Silicon packages on clean GitHub-hosted runners and publishes a prerelease after both builds succeed. The ordinary CI workflow only tests and does not publish.

The public build exports only the selected Git tree to a fresh temporary directory, builds there, and checks the resulting `.app`. This avoids embedding the developer's home path through SwiftPM resource accessors. Packaging omits Finder metadata and resource forks. The main app does not include optional Python runtime dependencies, a preconfigured backend, a ledger, session tokens or local configuration.

## Signing

Current previews have an ad hoc signature and are not notarized. For a smoother public installation, obtain an Apple Developer ID certificate, sign with the hardened runtime, notarize with Apple's notary service, staple the result, and verify on a different Mac before switching to a normal stable release. Signing identities, certificate files and notarization credentials must remain outside Git and source archives.

See [Apple notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Do not label an archive as notarized unless that exact signed build completed notarization and verification.

## Donations

Configure the chosen public donation URL only after the maintainer supplies it. Add it to GitHub Funding and README; never store a payment provider's secret key in the app. Voluntary support does not grant source redistribution or commercial licensing rights.
