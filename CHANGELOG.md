# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-02

### Added

- Move, prune, and transfer the project state recorded by Claude Code, Codex, OpenCode, and OMP, with a dry-run plan, per-run backups, and a restore manifest ([#1](https://github.com/hakula139/agent-project-move/pull/1)).
- Export a project's sessions, memory, and history into a bundle and import it on another host ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2)).
- Install without Nix through the POSIX `bin/agent-project-move` launcher and `setup`, which links the command into `~/.local/bin` and the skill into each assistant's skills directory ([#2](https://github.com/hakula139/agent-project-move/pull/2)).
- Install through the flake's package, overlay, and Home Manager module, whose `skillDirectories` option chooses where the skill is linked ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2)).

### Fixed

- Scan reports the real last use for Claude and OMP, handles OMP paths containing glob characters, and keeps paths under `/media/<user>/<name>` and `/run/media/<user>/<name>` when the disk is detached ([#2](https://github.com/hakula139/agent-project-move/pull/2)).
- Export refuses a path with no recorded state, so it no longer writes an empty bundle. Every edited or deleted file stays under a `0700` backup root ([#2](https://github.com/hakula139/agent-project-move/pull/2)).
- Dry runs and errors name the next command to run, and an empty move prints `No changes.` and exits 0 ([#2](https://github.com/hakula139/agent-project-move/pull/2)).
- An empty `-a` value or an unknown assistant fails with the valid list ([#2](https://github.com/hakula139/agent-project-move/pull/2)).

[0.1.0]: https://github.com/hakula139/agent-project-move/releases/tag/v0.1.0
