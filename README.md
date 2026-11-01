# agent-project-move

[![CI](https://github.com/hakula139/agent-project-move/actions/workflows/ci.yml/badge.svg)](https://github.com/hakula139/agent-project-move/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Repair the project paths recorded by [Claude Code](https://claude.com/claude-code), [Codex](https://openai.com/codex/), [OpenCode](https://opencode.ai), and [OMP](https://omp.sh) after a directory moves, transfer sessions between hosts, and prune state whose directory is gone.

## The problem

Coding assistants key their sessions, memory, and history by absolute directory path. The path is part of the storage key, so moving a project silently detaches everything recorded under it:

- After you move or rename a project, `/resume` and `codex resume` no longer list its sessions under the new path, Claude and OMP memory is orphaned, and Codex's thread previews point at dead paths.
- Removing a worktree leaves its sessions stranded under the worktree's path, where the project no longer lists them.
- State for directories you deleted keeps piling up in every assistant's store.
- Moving work to another machine loses the sessions, memory, and history, because none of it travels with the repository.

`agent-project-move` reads the state each assistant stores, plans the changes a move needs, and applies them in place:

- **`scan`** lists every recorded path with its session count, last use, and whether the directory exists, and suggests where a missing worktree or subdirectory belongs.
- **`move`** rewrites and relocates the state under an old path so the sessions belong to the new one, and a merge into an existing project keeps the unique transcripts from both sides.
- **`prune`** deletes state whose directory exists nowhere, after you move anything worth keeping.
- **`export`** and **`import`** carry a project's sessions, memory, and history in a bundle between hosts, and a normal `move` on the target then points them at its own path.

`move`, `prune`, and `import` print a plan and change assistant state only with `--apply`. `scan` and `export` never change assistant state, and `export` writes only the bundle directory you name.

## Install

### Nix

Run it without installing:

```bash
nix run github:hakula139/agent-project-move -- scan
```

Or install it into your profile:

```bash
nix profile install github:hakula139/agent-project-move
```

The package wraps the command with `sqlite3`, `ripgrep`, `zstd`, and the coreutils, diffutils, and findutils it needs, so nothing else has to be on `PATH`. It covers `aarch64-darwin`, `aarch64-linux`, and `x86_64-linux`, while other Unix platforms use the plain install. Flakes must be enabled, as in `nix --extra-experimental-features 'nix-command flakes' run ...` on a stock install.

The first run may ask to allow the project's Cachix cache. Declining is fine, since the package builds from cache.nixos.org. The overlay and module use the consumer's Nushell when it is 0.116 or later, and fall back to `nixpkgs-unstable` below that, so keep `inputs.agent-project-move.inputs.nixpkgs-unstable` on its own pin.

Home Manager users add the flake input and import the module:

```nix
inputs.agent-project-move.url = "github:hakula139/agent-project-move";

# In the Home Manager configuration
imports = [ inputs.agent-project-move.homeModules.default ];

programs.agent-project-move.enable = true;
```

The module installs the command and links the skill into `~/.claude/skills` and `~/.codex/skills`. Set `programs.agent-project-move.skillDirectories` to change the list, or use `overlays.default` to install the package through an overlay.

### Plain install

Native Windows is unsupported. A plain install reads your own `PATH` and needs Nushell 0.116 or later, GNU coreutils, `sqlite3` 3.33 or later, `ripgrep` built with PCRE2, and `zstd`. `setup` prints the install line for anything missing. Homebrew and Arch package Nushell, and other platforms install it from the [installation guide](https://www.nushell.sh/book/installation.html). On macOS, the launcher puts Homebrew's coreutils `gnubin` directory first on `PATH` when it is installed.

Clone the repository to `~/.local/share/agent-project-move` and run its setup:

```bash
git clone https://github.com/hakula139/agent-project-move ~/.local/share/agent-project-move
~/.local/share/agent-project-move/bin/agent-project-move setup
```

`setup` links the launcher into `~/.local/bin` and the skill into `~/.claude/skills`, `${CODEX_HOME:-~/.codex}/skills`, and `$CLAUDE_CONFIG_DIR/skills` when that variable names a different directory. It warns when `~/.local/bin` is not on `PATH`, refuses to replace an entry it did not create, and is safe to rerun. `git pull` updates the clone, and rerun `setup` after moving the clone somewhere else.

## Safety model

Before any `--apply`, exit every assistant session working in the affected projects. A session that writes during the apply loses those writes, and a running Claude Code can rewrite `~/.claude.json` at the same moment. Your own agent session counts.

- **One backup per applied run.** Everything edited or deleted is copied, and each database is backed up with `sqlite3 .backup`, under `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/<timestamp>-<pid>/`, with a `manifest.json` listing every action in order, including each rename's destination.
- **Each SQL action is one transaction**, so a failed action leaves no partial rows.

If a run stops partway, rerun the same command. It plans from what is on disk and skips finished work. If it stopped while rewriting files, restore from the backup first. [Restore](skills/agent-project-move/SKILL.md#restore) walks through the manifest.

## Usage

`-a` takes a comma-separated list of `claude`, `codex`, `opencode`, and `omp`, and leaving it out selects all four.

### Scan

```bash
agent-project-move scan
agent-project-move scan -a claude,codex
```

The table lists each recorded path, its session count, the last use, whether the directory exists, and a `suggested` target for a missing path. A suggestion comes from a repository that still exists or from a known worktree layout: Claude Code's `--worktree` (`<repo>/.claude/worktrees/<name>`), the Codex app's `~/.codex/worktrees/<id>/<repo>`, or Workmux's sibling `<repo>__worktrees/<name>`. It stays empty when no unique target exists.

### Move

```bash
agent-project-move move ~/src/app ~/work/app
agent-project-move move ~/src/app ~/work/app --apply
```

Move the directory in your file manager or with `mv` first, so the recorded path is the only stale reference, then run the state move. Paths match as exact, case-sensitive prefixes, so `~/src/app-v2` is untouched by a move of `~/src/app`, and a move whose paths differ only in case is refused. A destination that does not exist draws a warning, because a later prune would delete the moved state.

When only part of a tree changes, move the diverging child first. If `~/src/app` moves to `~/work/app` but its `assets` subdirectory moves to `~/media/assets`, run `move ~/src/app/assets ~/media/assets` and then `move ~/src/app ~/work/app`. Reversed, the parent move carries `assets` to `~/work/app/assets`.

### Prune

```bash
agent-project-move prune
agent-project-move prune --keep ~/archive,/tmp/scratch
agent-project-move prune --apply
```

`prune` deletes state recorded for paths that do not exist. The dry run lists the missing paths that lose state, and `--keep` takes comma-separated prefixes that equal or contain a missing path. Apply it after every move and transfer, once the listed sessions are the abandoned ones.

Paths under an unmounted `/Volumes/<name>`, `/mnt/<name>`, `/media/<user>/<name>`, or `/run/media/<user>/<name>` stay, so a detached disk is not mistaken for a deleted project. For any other drive or network share, mount it before pruning or pass its path to `--keep`.

### Transfer between hosts

```bash
# Source host
agent-project-move export ~/src/app ~/agent-project-move-bundle
rsync -a ~/agent-project-move-bundle target:~/

# Target host
agent-project-move import ~/agent-project-move-bundle
agent-project-move import ~/agent-project-move-bundle --apply
agent-project-move move ~/src/app ~/work/app           # When the path differs
agent-project-move move ~/src/app ~/work/app --apply
```

`export` copies the files and rows recorded for the path, unchanged, and needs no `--apply`. `import` writes them where the target's assistant keeps the same path, never overwrites state the target already holds, and aborts before writing when a target table lacks a column the bundle contains. The bundle holds transcripts, so keep it in a private directory, transfer it over a trusted channel, and delete it on both hosts once the import is done. If you are retiring the source copy, delete its directory there once the target lists the sessions, then prune the source host.

## Tested with

Each assistant changes its local storage without notice. `agent-project-move` is tested on Linux against these versions:

| Assistant   | Tested  |
| ----------- | ------- |
| Claude Code | 2.1.312 |
| Codex       | 0.165.0 |
| OpenCode    | 1.19.5  |
| OMP         | 18.13.2 |

A newer version can add a database, a table, or a path-bearing column this tool does not know about, and those paths then stay stale after a move. Path values in JSON transcripts are rewritten wherever they appear, so new record kinds are covered. If a move leaves sessions behind, open an issue with the release tag or commit you run and the assistant's version.

## Agent skill

The repository ships an [Agent Skill](skills/agent-project-move/SKILL.md) that surveys recorded paths, confirms the plan with you, applies it, and verifies the result.

The skill runs `agent-project-move` from `PATH`. If the command is not installed, run `nix run github:hakula139/agent-project-move -- <args>` or install it first. Link the whole skill directory, never `SKILL.md` alone, because Codex skips a `SKILL.md` that is itself a symlink. Start a new assistant session after linking, or run `/reload-plugins` in OMP.

### Triggering it

| Assistant   | Explicit invocation                                        |
| ----------- | ---------------------------------------------------------- |
| Claude Code | `/agent-project-move`                                      |
| Codex       | `$agent-project-move`, or pick it from `/skills`           |
| OMP         | `/skill:agent-project-move`                                |
| OpenCode    | No command. Ask in natural language and it loads the skill |

When your own session's working directory is under the old or new path, or the plan edits `~/.claude.json`, the skill hands you the `--apply` command to run after you exit the assistant.

Example prompts:

- **Move**: "I moved ~/src/app to ~/work/app. Move my Claude Code and Codex sessions over."
- **Worktree merge**: "I deleted the worktree ~/src/app/.claude/worktrees/feature-x. Bring its sessions into ~/src/app."
- **Host transfer**: "Export my agent sessions for ~/src/app and import them on `laptop` over ssh, where the tool is installed and the project lives at ~/work/app."
- **Discovery**: "Some Codex sessions disappeared after I reorganized ~/src. Find where they belong and move them."
- **Prune**: "Delete agent state for project directories that no longer exist, but keep anything under ~/archive."

## Documentation

| Document                                          | Description                                                 |
| ------------------------------------------------- | ----------------------------------------------------------- |
| [Agent skill](skills/agent-project-move/SKILL.md) | Procedures for moving, transferring, pruning, and restoring |
| [Design](docs/reference/design.md)                | Invariants, actions, apply order, and the backup layout     |
| [Assistant stores](docs/reference/stores.md)      | What each assistant stores and how a move rewrites it       |

## Development

[`AGENTS.md`](AGENTS.md) is the contributor entry point for people and coding agents alike.

## License

Copyright (c) 2026 [Hakula](https://hakula.xyz). Licensed under the [MIT License](LICENSE).
