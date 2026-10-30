# agent-project-move

[![CI](https://github.com/hakula139/agent-project-move/actions/workflows/ci.yml/badge.svg)](https://github.com/hakula139/agent-project-move/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Repair the project paths recorded by Claude Code, Codex, OpenCode, and OMP after a directory moves, transfer sessions between hosts, and prune state whose directory is gone.

## The problem

Coding assistants key their sessions, memory, and history by absolute directory path. The path is part of the storage key, so moving a project silently detaches everything recorded under it:

- After you move or rename a project, `/resume` and `codex resume` no longer list its sessions under the new path, Claude and OMP memory is orphaned, and Codex history projections point at dead paths.
- Removing a worktree leaves its sessions stranded under the worktree's path, where the project no longer lists them.
- State for directories you deleted keeps piling up in every assistant's store.
- Moving work to another machine loses the sessions, memory, and history, because none of it travels with the repository.

`agent-project-move` reads the state each assistant stores, plans the changes a move needs, and applies them in place:

- **`scan`** lists every recorded path with its session count and last use, and suggests where a missing worktree or subdirectory belongs.
- **`move`** rewrites and relocates the state under an old path so the sessions belong to the new one, and a merge into an existing project keeps the unique transcripts from both sides.
- **`prune`** deletes state whose directory exists nowhere, after you move anything worth keeping.
- **`export`** and **`import`** carry a project's sessions, memory, and history in a bundle between hosts, and a normal `move` on the target then points them at its own path.

Every run plans first and writes only with `--apply`, and an applied run copies everything it edits or deletes to a backup with a manifest, so a mistake is reversible.

## Prerequisites

The command runs on Nushell, `sqlite3`, `ripgrep`, and `zstd`. A Nix install supplies all of them. A plain install reads your own `PATH` and also needs GNU coreutils.

| Tool          | Requirement                                                                |
| ------------- | -------------------------------------------------------------------------- |
| Nushell       | 0.116 or later, the version CI runs                                        |
| GNU coreutils | GNU `stat`, `cp`, and `sha1sum` options, required only for a plain install |
| `sqlite3` CLI | 3.33 or later, for `-json` output                                          |
| `ripgrep`     | Built with PCRE2, for `rg -P` (`rg --pcre2-version` succeeds)              |
| `zstd`        | Any 1.x, used only when Codex keeps a compressed rollout                   |

Install them per platform:

```bash
# macOS
brew install nushell ripgrep sqlite zstd

# macOS, for a plain install
brew install coreutils

# Arch
sudo pacman -S nushell ripgrep sqlite zstd

# Any platform with a Rust toolchain
cargo install nu --locked

# Nix
nix profile install nixpkgs#nushell nixpkgs#ripgrep nixpkgs#sqlite nixpkgs#zstd
```

Every other distribution installs `ripgrep`, `sqlite3`, and `zstd` through its package manager, and Nushell from the [installation guide](https://www.nushell.sh/book/installation.html), which also covers prebuilt binaries. Check the setup with:

```bash
nu --version      # 0.116 or later
sqlite3 --version
rg --version
```

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

The package wraps the command with `sqlite3`, `ripgrep`, `zstd`, and the coreutils, diffutils, and findutils it needs, so nothing else has to be on `PATH`.

The package takes Nushell from `nixpkgs-unstable`, because 0.116 is newer than nixos-26.05 ships. Keep `nixpkgs-unstable` on its own pin when composing flakes, since following a 26.05 `nixpkgs` would drop the command back to 0.112.

Home Manager users can import `homeModules.default` and set:

```nix
programs.agent-project-move = {
  enable = true;
  skillDirectories = [ ".claude/skills" ".codex/skills" ];
};
```

Each `skillDirectories` entry receives a link to the skill directory. The module also exposes `programs.agent-project-move.skill` for a consumer that installs the skill itself.

### Plain install

Clone the repository and run the entry directly:

```bash
git clone https://github.com/hakula139/agent-project-move
nu --no-config-file agent-project-move/src/agent-project-move.nu scan
```

For a command on `PATH`, write a wrapper that keeps your Nushell config out of the run:

```bash
printf '#!/bin/sh\nexec nu --no-config-file %s "$@"\n' \
  "$PWD/agent-project-move/src/agent-project-move.nu" > ~/.local/bin/agent-project-move
chmod +x ~/.local/bin/agent-project-move
```

The wrapper runs `nu` from `PATH` and needs the tools from [Prerequisites](#prerequisites) there. A plain install is tested on Linux with GNU coreutils. On macOS, put the `coreutils` `gnubin` directory first on `PATH`, because the command uses GNU `stat`, `cp`, and `sha1sum` options.

## Usage

Every subcommand prints its plan and writes only with `--apply`. `-a` takes a comma-separated list of `claude`, `codex`, `opencode`, and `omp`, and leaving it out selects all four.

### Scan

```bash
agent-project-move scan
agent-project-move scan -a claude,codex
```

The table lists each recorded path, its session count, the last use, and a `suggested` target for a missing path. A suggestion comes from a repository that still exists or from a known worktree layout, such as `<repo>/.claude/worktrees/<name>` or a sibling `<repo>__worktrees/<name>`, and stays empty when no unique target exists.

### Move

```bash
agent-project-move move ~/src/app ~/work/app
agent-project-move move ~/src/app ~/work/app --apply
```

Move the directory in your file manager or with `mv` first, so the recorded path is the only stale reference, then run the state move. Paths match as exact, case-sensitive prefixes, so `~/src/app-v2` is untouched by a move of `~/src/app`, and a move whose paths differ only in case is refused.

Split a move when only part of a tree changes, and move the diverging child first. To keep the app checkout while its `assets` directory moves elsewhere, run `move ~/src/app/assets ~/media/assets` and then `move ~/src/app ~/work/app`. Reversed, the parent move would carry `assets` to `~/work/app/assets`.

A move is in place, so a rerun after a failure plans from what is still on disk and reports `No changes.` once nothing remains.

### Prune

```bash
agent-project-move prune
agent-project-move prune --keep ~/archive,/tmp/scratch
agent-project-move prune --apply
```

`prune` deletes state recorded for paths that do not exist. Run it after every move and transfer, and apply it once the plan names only abandoned sessions. `--keep` takes comma-separated prefixes and leaves every missing path that equals one or falls under one, and the dry run lists the excluded paths.

### Transfer between hosts

```bash
# Source host
agent-project-move export ~/src/app /tmp/agent-project-move-bundle
rsync -a /tmp/agent-project-move-bundle target:/tmp/

# Target host
agent-project-move import /tmp/agent-project-move-bundle
agent-project-move import /tmp/agent-project-move-bundle --apply
agent-project-move move ~/src/app ~/work/app --apply   # When the path differs
```

`export` copies the files and rows recorded for the path, unchanged, and needs no `--apply`. `import` writes them where the target's assistant keeps the same path, never overwrites state the target already holds, and aborts before writing when a target table lacks a carried column. Once the target reports its import, delete the project directory on the source, then prune the source host.

## Safety model

- **Dry runs by default.** `scan`, `export`, and every plan print what they would do. Only `--apply` writes.
- **One backup per applied run.** Files are copied and databases backed up with `sqlite3 .backup` under `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/<timestamp>-<pid>/`, mode 0700, with a `manifest.json` listing every action in order, including the destination of each rename.
- **Each SQL action is one transaction.** Databases load with `sqlite3 -bail`, once per path column on a move and once per database on an import. Shared documents are rewritten through a temporary file.
- **Renames keep the inode, edits do not.** An open session keeps appending to a renamed file, while an edit replaces the file through a temporary file, so a session writing at that moment loses those writes.
- **Close sessions first.** A running session can also rewrite a shared document such as `~/.claude.json` at the same moment.

[Restoring from a backup](skills/agent-project-move/SKILL.md#restore) walks through putting the previous state back from the manifest.

## Tested with

Each assistant changes its local storage without notice. `agent-project-move` is tested on Linux against these versions:

| Assistant   | Tested  |
| ----------- | ------- |
| Claude Code | 2.1.312 |
| Codex       | 0.165.0 |
| OpenCode    | 1.19.5  |
| OMP         | 18.13.2 |

A newer version can add a database, a table, or a path-bearing column this tool does not know about, and those paths then stay stale after a move. Path values in JSON transcripts are rewritten wherever they appear, so new record kinds are covered. Planning and `scan` only read, an import aborts before writing when the target lacks a column the bundle carries, and every applied run keeps a backup. If a move leaves sessions behind, open an issue with the release tag or commit you run and the assistant's version.

## Agent skill

The repository also ships an [Agent Skill](skills/agent-project-move/SKILL.md) that walks an agent through the same work: surveying recorded paths, confirming the plan with you, applying it, and verifying the result.

### Installing the skill

- **Nix users** set `programs.agent-project-move.skillDirectories` as shown in [Install](#install), which links the skill into each directory.
- **Plain installs** copy or link the whole skill directory, because Codex skips a skill whose `SKILL.md` is a symlink:

  ```bash
  ln -s "$PWD/agent-project-move/skills/agent-project-move" ~/.claude/skills/agent-project-move
  ln -s "$PWD/agent-project-move/skills/agent-project-move" "${CODEX_HOME:-$HOME/.codex}/skills/agent-project-move"
  ```

  `~/.claude/skills` reaches Claude Code, OpenCode, and OMP, while `$CODEX_HOME/skills` reaches Codex and OMP. Installing the skill in both places covers all four assistants.

### Triggering it

Invoke the skill as `/agent-project-move` in Claude Code, or ask in natural language, as in "I moved ~/src/app to ~/work/app, migrate my agent sessions". An agent that loaded the skill runs `agent-project-move scan`, shows you the dry-run plan, waits for your confirmation, applies it, and reports what moved.

Example prompts:

- **Move:** "I moved ~/src/app to ~/work/app. Move my Claude Code and Codex sessions over."
- **Worktree merge:** "I deleted the worktree ~/src/app/.claude/worktrees/feature-x. Bring its sessions into ~/src/app."
- **Host transfer:** "Export the sessions for ~/src/app, and then import them on my other machine."
- **Prune:** "Delete agent state for project directories that no longer exist, but keep anything under ~/archive."

### When to use the command directly

Run the subcommands yourself when you already know the exact old and new paths, when you want to read a plan without an agent in the loop, or in a script. The skill adds the survey, the confirmation step, and the verification that a whole migration needs.

## Documentation

| Document                                          | Description                                                 |
| ------------------------------------------------- | ----------------------------------------------------------- |
| [Agent skill](skills/agent-project-move/SKILL.md) | Procedures for moving, transferring, pruning, and restoring |
| [Design](docs/reference/design.md)                | Invariants, actions, apply order, and the backup layout     |
| [Assistant stores](docs/reference/stores.md)      | What each assistant stores and how a move rewrites it       |
| [Development](docs/conventions/development.md)    | Dev shell, hooks, Nix style, and CI                         |
| [GitHub](docs/conventions/github.md)              | Commits, pull requests, labels, review, and issues          |
| [Nushell](docs/conventions/nushell.md)            | Project layout, testing, and Nushell traps                  |

## Development

[`AGENTS.md`](AGENTS.md) is the contributor entry point for people and coding agents alike. It covers the verification checks and links the conventions.

## License

Copyright (c) 2026 [Hakula](https://hakula.xyz). Licensed under the [MIT License](LICENSE).
