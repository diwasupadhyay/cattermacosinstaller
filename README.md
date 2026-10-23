# Catter build workspace

Temporary build-only repository for the unsigned Catter iPhone IPA and Apple Silicon macOS installer. No Windows builds, owner dashboard, activation database, device records or account credentials are included.

## Build and download

In **Actions**, select **Build experimental iPhone IPA** or **Build Catter macOS installer**, then **Run workflow**. Both use standard macOS runners. Workflows run manually only; artifacts are retained for seven days.

Download the artifact after a successful run. The IPA is unsigned and must be signed to your Apple Account before installation. The Mac installer targets Apple Silicon and macOS 13 or later; its ad-hoc signature is not Apple notarization. Builds and smoke checks do not establish successful Apple authentication or operation on a physical iPhone.

The activation API URL is public configuration, not an owner credential. No Apple credentials or signing certificates are needed in Actions. Never put credentials or invitation codes in repository files or issues.

Original source uses the [MIT license](LICENSE); dependency licenses and distribution obligations remain applicable. See [third-party notices](docs/THIRD_PARTY_NOTICES.md). Keep required source and notices with distributed builds. Removing this temporary repository does not erase downloaded copies or end source-distribution obligations.
