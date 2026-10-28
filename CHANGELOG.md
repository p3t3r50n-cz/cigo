# Changelog

All notable changes to cigo are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the version
numbers follow [Semantic Versioning](https://semver.org/). While the major
version is 0, a minor bump marks a breaking change.

## [0.2.1] — 2026-10-28

### Fixed

- Confirmation prompts displayed `[Y/n]` but an empty answer cancelled. Enter
  now accepts the displayed default; a closed stdin still cancels, so
  `cigo.sh ... < /dev/null` never proceeds by accident.

## [0.2.0] — 2026-10-28

### Breaking changes

- `create` now refuses an existing container. Reapplying a template to a
  container that already exists is `redeploy`.
- `--image`, `--from`, `--profile`, `--timeout`, `--log`, and
  `--dump-user-data` are rejected by verbs where they cannot apply, instead
  of being ignored with a warning.

### Added

- `redeploy` verb: config, declared devices, and pipeline actions.
- `configure` verb: LXD config and declared devices only, no actions, no
  cloud-init. Works without a template as a pure imperative update.
- `adopt` verb: take over an existing container cigo did not create.
- `--unset KEY` and `--remove-device NAME` for `configure` and `redeploy`.
- `--check` on an existing container is now a drift report with exit code 1
  when the container differs from the declared state.
- `--dry-run` on an existing container prints the same plan and changes
  nothing.
- Container metadata in LXD's `user.cigo.*` namespace: version, template,
  creation or adoption time, and the list of managed keys.
- Declarative cleanup: `configure --template` and `redeploy` remove config
  keys cigo wrote earlier and the template no longer declares. Keys set by
  hand are never touched.
- `CHANGELOG.md`.

### Changed

- `--from` no longer inherits `user.cigo.*` metadata.
- Documentation rewritten around the four verbs.

## [0.1.0] — 2026-10-27

Initial release: `create`, templates as cloud-config, host-side Jinja2
rendering, declared disk and proxy devices, render-only secrets, `--check`,
`--dry-run`, `--dump-user-data`, and eleven example templates.
