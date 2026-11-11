# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-11-11

### Breaking changes

- Remove the `bin/agent-project-move` launcher and its `setup` subcommand. Install the plugin, copy `skills/agent-project-move/` with a skill installer, or use the flake, and delete the `~/.local/bin/agent-project-move` link that `setup` left behind ([#14](https://github.com/hakula139/agent-project-move/pull/14))
- Drop OpenCode support, so `scan`, moves, prunes, and transfers cover Claude Code, Codex, and OMP ([#14](https://github.com/hakula139/agent-project-move/pull/14))
- _(devkit)_ The Home Manager module links the skill into `.agents/skills` and `.claude/skills` by default, without `.codex/skills`, so set `programs.agent-project-move.skillDirectories` to keep the old list. The flake no longer exposes its `nixpkgs-unstable`, `git-hooks-nix`, or `home-manager` inputs, so remove any `follows` on them ([#7](https://github.com/hakula139/agent-project-move/pull/7))

### Added

- Install as a Claude Code or Codex plugin from the repository's marketplace, pinned to a release tag, or copy `skills/agent-project-move/` with any skill installer. Without the command on `PATH`, the skill runs its bundled scripts, and on macOS the command puts Homebrew's GNU coreutils first on its own `PATH` ([#14](https://github.com/hakula139/agent-project-move/pull/14))

[0.2.0]: https://github.com/hakula139/agent-project-move/compare/v0.1.0...v0.2.0

## [0.1.0] - 2026-11-02

### Added

- Move a project's recorded state to a new path. A merge into an existing project keeps the unique transcripts from both sides. Prune state whose directory is gone, keeping paths under an unmounted `/Volumes`, `/mnt`, `/media`, or `/run/media` drive. Dry runs print the plan and the command to apply it, and `--apply` backs up every edited or deleted file in a `0700` run directory with a `manifest.json` for restores ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2))
- Export a project's sessions, memory, and history into a bundle and import it on another host ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2))
- Scan the project paths that Claude Code, Codex, OpenCode, and OMP record, with each path's session count, last use, and existence, plus a suggested destination for a missing worktree or subdirectory ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2))
- Install through the flake's package, overlay, or Home Manager module, whose `skillDirectories` option chooses where the agent skill is linked ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2))
- Install without Nix through the POSIX `bin/agent-project-move` launcher, whose `setup` links the command into `~/.local/bin` and the skill where each assistant finds it ([#2](https://github.com/hakula139/agent-project-move/pull/2))

[0.1.0]: https://github.com/hakula139/agent-project-move/releases/tag/v0.1.0
