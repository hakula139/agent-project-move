# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-11-15

### Breaking changes

- Remove `prune` and automatic collection of state for missing directories. Review `scan` and use `retire --exact` or `retire --session-ids` to remove selected session copies. Investigate orphaned metadata separately ([#25](https://github.com/hakula139/agent-project-move/pull/25))
- Remove the `suggested` column from `scan`. The skill determines migration targets from the user's intent and local repositories ([#22](https://github.com/hakula139/agent-project-move/pull/22))
- _(claude)_ Transfer and retire only selected transcripts, their owned artifacts, and file history. Project memory, global configuration, and prompt history stay in place. Moves rewrite canonical session and subagent transcripts, leave other artifact bytes unchanged, and merge memory and stale indexes as ordinary files. Handle shared state separately and review differing files when directory merges stop ([#30](https://github.com/hakula139/agent-project-move/pull/30))
- _(omp)_ Limit every operation to session files and their owned artifacts, leaving memory, `history.db`, and `agent.db` unchanged. Re-export older bundles that carry auxiliary state before importing ([#28](https://github.com/hakula139/agent-project-move/pull/28))
- _(codex)_ Leave project trust configuration unchanged. Codex can ask for trust again after migration ([#23](https://github.com/hakula139/agent-project-move/pull/23))

### Added

- Select exports by exact cwd with `--exact` or by session ID with `--session-ids`, including dependent descendants and owned artifacts. Use `retire` with either selector to preview and remove source copies after verifying a transfer, preserving unrelated sessions and shared metadata still in use ([#20](https://github.com/hakula139/agent-project-move/pull/20))
- Map incoming project paths with `import --target`, including descendant suffixes and Codex project roots, while preserving unrelated local sessions. Imports reject differing transcripts for reused session IDs and complete missing dependent records for identical sessions. Exported files include `origin_path` provenance without changing import destinations ([#20](https://github.com/hakula139/agent-project-move/pull/20))
- Skip recovery backups explicitly with `--no-backup` on move, import, and retirement. Backups remain enabled by default, and dry runs report the selected behavior ([#20](https://github.com/hakula139/agent-project-move/pull/20))

### Changed

- _(codex)_ Invalidate history projections whenever a rollout is rewritten, including equal-length path changes. Resume rebuilds the projection, so previews stay empty until then. Unarchive archived sessions before resuming. Desktop workspace paths in `.codex-global-state.json` stay unchanged and can be updated separately ([#26](https://github.com/hakula139/agent-project-move/pull/26))

### Fixed

- _(omp)_ Keep absolute `parentSession` references pointing at relocated session files after a local move, including references from sessions whose cwd stays elsewhere. Previously moved copies may still need separate repair ([#31](https://github.com/hakula139/agent-project-move/pull/31))

[0.3.0]: https://github.com/hakula139/agent-project-move/compare/v0.2.0...v0.3.0

## [0.2.0] - 2026-11-11

### Breaking changes

- Remove the `bin/agent-project-move` launcher and its `setup` subcommand. Install the plugin, copy `skills/agent-project-move/` with a skill installer, or use the flake, and delete the `~/.local/bin/agent-project-move` link that `setup` left behind ([#14](https://github.com/hakula139/agent-project-move/pull/14))
- Drop OpenCode support, so `scan`, moves, prunes, and transfers cover Claude Code, Codex, and OMP ([#14](https://github.com/hakula139/agent-project-move/pull/14))
- _(devkit)_ The Home Manager module links the skill into `.agents/skills` and `.claude/skills` by default, without `.codex/skills`, so set `programs.agent-project-move.skillDirectories` to keep the old list. The flake no longer exposes its `nixpkgs-unstable`, `git-hooks-nix`, or `home-manager` inputs, so remove any `follows` on them ([#7](https://github.com/hakula139/agent-project-move/pull/7))

### Added

- Install as a Claude Code or Codex plugin from the repository's marketplace, pinned to a release tag, or copy `skills/agent-project-move/` with any skill installer. Without the command on `PATH`, the skill runs its bundled scripts, and on macOS the command puts Homebrew's GNU coreutils first on its own `PATH` ([#14](https://github.com/hakula139/agent-project-move/pull/14))

### Changed

- Clarify that the command needs no credentials, opens no network connections, and runs no commands from the assistant stores. Exports select state by project path, so credential files and tables stay out of a bundle. Delete each backup directory once you no longer need it ([#19](https://github.com/hakula139/agent-project-move/pull/19))

[0.2.0]: https://github.com/hakula139/agent-project-move/compare/v0.1.0...v0.2.0

## [0.1.0] - 2026-11-02

### Added

- Move a project's recorded state to a new path. A merge into an existing project keeps the unique transcripts from both sides. Prune state whose directory is gone, keeping paths under an unmounted `/Volumes`, `/mnt`, `/media`, or `/run/media` drive. Dry runs print the plan and the command to apply it, and `--apply` backs up every edited or deleted file in a `0700` run directory with a `manifest.json` for restores ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2))
- Export a project's sessions, memory, and history into a bundle and import it on another host ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2))
- Scan the project paths that Claude Code, Codex, OpenCode, and OMP record, with each path's session count, last use, and existence, plus a suggested destination for a missing worktree or subdirectory ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2))
- Install through the flake's package, overlay, or Home Manager module, whose `skillDirectories` option chooses where the agent skill is linked ([#1](https://github.com/hakula139/agent-project-move/pull/1), [#2](https://github.com/hakula139/agent-project-move/pull/2))
- Install without Nix through the POSIX `bin/agent-project-move` launcher, whose `setup` links the command into `~/.local/bin` and the skill where each assistant finds it ([#2](https://github.com/hakula139/agent-project-move/pull/2))

[0.1.0]: https://github.com/hakula139/agent-project-move/releases/tag/v0.1.0
