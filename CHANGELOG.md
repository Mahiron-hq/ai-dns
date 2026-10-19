# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [3.0.0] - 2026-10-20

### Added

- `AI-DNS-Update.bat`: a full rollback, removal of every cached artefact, then a fresh selection with
  newly downloaded provider lists.
- Remote provider lists: this repository's `src/providers.json` and the DnsSwitch community list,
  each with a jsDelivr mirror, a 6-hour cache and a fallback to the stale copy.
- Discovery of current provider addresses through their DoH host names as well as their host names.
- 17 providers with 57 addresses in the bundled catalog (up from 8 providers with 19 addresses),
  described by a JSON schema that CI validates.
- `-DryRun` and `-Trace`, plus trace and dry-run copies of the three scripts in `tests/manual`.
- English console output, selected from the Windows UI language or with `-Language`.
- Brave browser policies.
- Pester tests, PSScriptAnalyzer and a compile check of the probe engine in GitHub Actions.

### Changed

- The logic lives in a PowerShell module (`src/`) driven by `AI-DNS.ps1`; the `.bat` files are thin
  launchers, so the three actions share one implementation.
- DNS polling sends every query from a single UDP socket, so a poll takes at most two 1.5 s rounds
  regardless of how many resolvers are dead. HTTPS checks run asynchronously.
- Options use PowerShell syntax: `-TestOnly`, `-NoWait`, `-Full`, `-ResetNetwork` and `-EnableIPv6`
  replace `/test`, `/nowait`, `/full`, `/deep` and `/ipv6`.
- Logs are kept in `%ProgramData%\AIDNS\logs`, and a rollback also writes one.

### Fixed

- Disable now turns IPv6 back on where Enable turned it off; previously it stayed off unless `/ipv6`
  was given.
- `%ProgramData%\AIDNS` is restricted to administrators. Before, a standard user could plant the
  compiled engine or a backup there and have the elevated script load or apply it.
- Backups are validated before use: only the browser policies this tool manages can be restored.
- The rollback recognised a hard-coded address list that had drifted from the one Enable used; both
  now derive it from the catalog and the recorded state.
- `hosts` entries are matched by host name instead of a substring, so `notchatgpt.com` is no longer
  disabled, and the file keeps its encoding and line endings.
- Native commands no longer turn their stderr output into script errors.

### Migration from 2.x

Machines enabled by 2.x can be rolled back by 3.0: the backup format is read as before. IPv6 that
2.x left disabled is reported, and `-EnableIPv6` turns it back on.

[3.0.0]: https://github.com/Mahiron-hq/ai-dns/releases/tag/v3.0.0
