# Changelog

All notable changes to Codeg for iOS are recorded here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add changes under `## [Unreleased]` as you work. When you cut a release,
`scripts/release.sh` moves that section under a new version heading and reuses
the text as the git tag message and the GitHub Release notes.

## [Unreleased]

### Added

- iOS 26 continued-processing support for user-started live agent streams.
- Actionable background notifications for permission requests, agent questions,
  and plan approvals, including a second confirmation for Always Allow.
- GitHub Actions packaging for a verified unsigned device IPA.
- `docs/background-agent-ux.md` with the accepted background/recovery UX design.

### Changed

- Apple signing now uses an ignored local configuration instead of a committed
  development team identifier.
- Live event sockets transparently reconnect and re-attach with `since_seq`, so
  ordinary Wi-Fi/5G/VPN changes and short background interruptions no longer
  have to become visible chat reconnect state.
- Network restoration accelerates an already-pending reconnect without tearing
  down a still-healthy socket merely because the network path changed.
- iOS background coordination now starts only after the WebSocket server has
  completed the initial upgrade and the client begins its attach handshake.
- Continued-processing Live Activity updates are now state-based and minute-
  granularity, showing elapsed time instead of continuously advancing a fake
  completion percentage.
- Tapping the system Live Activity now restores the owning server/session using
  lightweight persisted routing hints; ordinary app foregrounding remains unchanged.
- Native iOS WebSocket upgrades now authenticate with the same
  `Authorization: Bearer <token>` header used by normal Codeg API requests and
  advertise only the `codeg-events` application subprotocol. The browser-only
  `codeg-token.*` authentication subprotocol is no longer used by iOS.
- WebSocket tokens are trimmed before the upgrade request, matching the web
  client's normalization behavior.

### Fixed

- Returning from another app no longer needs to treat the foreground transition
  itself as a connection failure.
- Pending interactive requests are restored from an authoritative re-attach
  snapshot and can be surfaced as background actions after a transient drop.
- Restored the upstream-equivalent initial WebSocket handshake path after the
  first tapaixx background build could fail before attach with iOS reporting
  "the server returned an invalid response". Handshake failures now include the
  HTTP status code when URLSession exposes it, to distinguish auth/route/proxy
  failures from transport recovery failures.
- Fixed WebSocket HTTP 403 failures behind CDNs/WAFs that require the normal
  bearer token during the HTTP Upgrade request rather than accepting an encoded
  token hidden in `Sec-WebSocket-Protocol`.

## [1.0.1] - 2026-07-07

### Added

- **New agent types** — CodeBuddy, Kimi Code, and Pi.
- One-command release automation: `scripts/release.sh` bumps the version, files
  the release notes, tags, pushes, and creates a GitHub Release (with an
  optional `--archive` App Store Connect upload leg).
- This `CHANGELOG.md` as the home for version notes.

### Changed

- The app version is now single-sourced from `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION` in `project.yml`.

### Fixed

- Streaming no longer rebuilds the entire transcript on every token, keeping
  long sessions smooth.
- The pending approval card is restored after a mid-turn stream reconnect.
- `Info.plist` no longer hardcodes `CFBundleShortVersionString`, which had
  silently overridden `MARKETING_VERSION` so version bumps didn't take effect.

## [1.0.0] - 2026-06-07

### Added

- Initial Codeg for iOS release.
