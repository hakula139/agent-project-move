# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking changes

- Remove the `setup` subcommand. Install the Claude Code or Codex plugin, or link `skills/agent-project-move/` where each assistant reads skills, and the skill falls back to its bundled script and checks the tools it needs. An install that `setup` made keeps working after `git pull`, since its links name the launcher and the skill directory, which stay in place ([#14](https://github.com/hakula139/agent-project-move/pull/14))
- Drop OpenCode support ([#14](https://github.com/hakula139/agent-project-move/pull/14))

### Added

- Install as a Claude Code or Codex plugin from the repository's own marketplace ([#14](https://github.com/hakula139/agent-project-move/pull/14))

## [0.1.0] - 2026-11-02

### Added

- Move a project's recorded state to a new path. A merge into an existing project keeps the unique transcripts from both sides. Prune state whose directory is gone, keeping paths under an unmounted `/Volumes`, `/mnt`, `/media`, or `/run/media` drive. Dry runs print the plan and the command to apply it, and `--apply` backs up every edited or deleted file in a `0700` run directory with a `manifest.json` for restores ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2))
- Export a project's sessions, memory, and history into a bundle and import it on another host ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2))
- Scan the project paths that Claude Code, Codex, OpenCode, and OMP record, with each path's session count, last use, and existence, plus a suggested destination for a missing worktree or subdirectory ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2))
- Install through the flake's package, overlay, or Home Manager module, whose `skillDirectories` option chooses where the agent skill is linked ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2))
- Install without Nix through the POSIX `bin/agent-project-move` launcher, whose `setup` links the command into `~/.local/bin` and the skill where each assistant finds it ([#2](https://github.com/hakula139/agent-project-move/pull/2))

[0.1.0]: https://github.com/hakula139/agent-project-move/releases/tag/v0.1.0
