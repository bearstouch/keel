# Changelog

All notable changes to Keel are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Swift package scaffold with the Keel targets, an empty Keel window, launch arguments `--state-directory`,
  `--no-mcp` and `--fixture`, owner-only state folder, release manifest, formatter config and CI (KEEL-001).
- Vendored Trellis code in `ThirdParty/TrellisShared` with `PROVENANCE.md`: SSH host library and `~/.ssh/config`
  discovery, the askpass broker and `keel-askpass` helper, owner-only file storage, rebindable shortcut rules and the
  MCP HTTP parser and listener, all under Keel names (`Keel SSH Host`, `SSH_ASKPASS_KEEL_*`) (KEEL-002).
- Owner-only versioned persistence for the state files: atomic 0600 writes in a 0700 folder, last-known-good
  backups, sequence-gated 300 ms debounced saves, corrupt files preserved before **Recover backup** / **Start empty**,
  and files from a newer Keel opened read-only (KEEL-003).
