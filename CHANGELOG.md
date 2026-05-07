# Changelog

All notable changes to FlareOps are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each module is versioned together with the repository: a tag of `v1.2.3`
applies to every module under this repo. Floating major tags (`v1`) point at
the latest release in their major series — pin to those for automatic patch
updates, or pin to a full SHA for reproducible builds.

## [Unreleased]

### Added

- (placeholder for next release)

## [v1.0.0] — 2026-05-07

### Added

- `purge-cache` action with support for:
  - `purge_everything`
  - `files` (URL list, with optional per-file headers)
  - `hostnames`
  - `tags` (cache-tags)
  - `prefixes`
  - multi-zone purges via `zone_ids`
- Bearer token (recommended) and Global API Key + Email auth.
- Exponential backoff with jitter; honors Cloudflare `Retry-After`.
- `dry_run`, `debug`, configurable `timeout`/`retries`.
- Outputs: `success`, `response_code`, `request_id`, `purge_type`,
  `zones_processed`, `failed_zones`.
- Job summary written to `$GITHUB_STEP_SUMMARY` for at-a-glance run review.
- CI: shellcheck, action-metadata validation, smoke tests on Ubuntu and macOS.
- Release workflow with floating major tag (`v1`) management.

[Unreleased]: https://github.com/amitsdalal/FlareOps/compare/v1.0.0...HEAD
[v1.0.0]: https://github.com/amitsdalal/FlareOps/releases/tag/v1.0.0
