# agent-project-move

[![CI](https://github.com/hakula139/agent-project-move/actions/workflows/ci.yml/badge.svg)](https://github.com/hakula139/agent-project-move/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Repair the project paths recorded by [Claude Code](https://claude.com/claude-code), [Codex](https://openai.com/codex/), and [OMP](https://omp.sh) after a directory moves, transfer sessions between hosts, and retire selected session copies.

## The problem

Coding assistants record project paths in their session stores. Moving a project or removing a worktree can leave its sessions listed under the old path, and copying a repository to another host leaves its transcripts behind.

`agent-project-move` scans these stores, moves recorded paths, transfers selected sessions between hosts, and retires selected source copies. It prints a plan before changing assistant state, and writes only with `--apply`. Export writes a bundle without changing the source store. See [Assistant stores](docs/reference/stores.md) for the state each adapter handles.

## Install

The repository is a Claude Code and Codex plugin, and `skills/agent-project-move/` is an [Agent Skill](https://agentskills.io) that any skill installer can copy. Every route outside Nix runs the bundled Nushell script with the tools on your own `PATH`, so check the [requirements](#requirements) first.

### Requirements

Native Windows is unsupported. Outside Nix, the command needs the tools listed in the skill's [Requirements](skills/agent-project-move/SKILL.md#requirements), and the skill checks for them and names what is missing. Homebrew and Arch package Nushell, and other platforms install it from the [installation guide](https://www.nushell.sh/book/installation.html).

### Claude Code plugin

```bash
claude plugin marketplace add hakula139/agent-project-move
claude plugin install agent-project-move@agent-project-move
```

Pin a release with `hakula139/agent-project-move#vX.Y.Z`. The skill answers to `/agent-project-move` and `/agent-project-move:agent-project-move`.

### Codex plugin

```bash
codex plugin marketplace add hakula139/agent-project-move
codex plugin add agent-project-move@agent-project-move
```

Pin a release with `--ref vX.Y.Z` on `marketplace add`. Codex lists the skill as `agent-project-move:agent-project-move`.

### Skill directories

For OMP, or for any of the three assistants without a plugin, clone the repository and link the skill directory where each assistant reads skills:

```bash
git clone https://github.com/hakula139/agent-project-move ~/.local/share/agent-project-move
skill_dir=~/.local/share/agent-project-move/skills/agent-project-move
mkdir -p ~/.agents/skills ~/.claude/skills
ln -s "$skill_dir" ~/.agents/skills/agent-project-move
ln -s "$skill_dir" ~/.claude/skills/agent-project-move
```

| Directory                                                   | Read by          |
| ----------------------------------------------------------- | ---------------- |
| `~/.agents/skills`                                          | Codex, OMP       |
| `~/.claude/skills`, or `$CLAUDE_CONFIG_DIR/skills` when set | Claude Code, OMP |

Link the whole skill directory, never `SKILL.md` alone, because Codex skips a `SKILL.md` that is itself a symlink. `git pull` updates the clone, and `git checkout vX.Y.Z` pins a release.

Skill installers copy only the skill directory:

- `npx skills add hakula139/agent-project-move -g` installs it into `~/.agents/skills` and links it for Claude Code.
- Codex's `$skill-installer` takes `--repo hakula139/agent-project-move --path skills/agent-project-move`.

### Nix

Run it without installing:

```bash
nix run github:hakula139/agent-project-move -- scan
```

Or install it into your profile:

```bash
nix profile install github:hakula139/agent-project-move
```

The package wraps the command with `sqlite3`, `ripgrep`, `zstd`, and the coreutils, diffutils, and findutils it needs, so nothing else has to be on `PATH`. It covers `aarch64-darwin`, `aarch64-linux`, and `x86_64-linux`, while other Unix platforms use one of the routes above. Flakes must be enabled, as in `nix --extra-experimental-features 'nix-command flakes' run ...` on a stock install.

The first run may ask to allow the project's Cachix cache. Declining is fine, since the package builds from cache.nixos.org. The overlay and module use the Nushell from the consuming package set when it is 0.116 or later, and devkit's `nixpkgs-unstable` below that.

Home Manager users add the flake input and import the module:

```nix
inputs.agent-project-move.url = "github:hakula139/agent-project-move";

# In the Home Manager configuration
imports = [ inputs.agent-project-move.homeModules.default ];

programs.agent-project-move.enable = true;
```

The module installs the command and links the skill into `~/.agents/skills` and `~/.claude/skills`. Set `programs.agent-project-move.skillDirectories` to change the list, or use `overlays.default` to install the package through an overlay.

## Safety model

Before any `--apply`, exit every assistant session working in the affected projects, including your own. Concurrent writes can be lost. See [Concurrent sessions](skills/agent-project-move/SKILL.md#concurrent-sessions) for shared configuration and interrupted runs.

Applied changes create a backup under `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/<timestamp>-<pid>/` by default. It contains edited or deleted files, SQLite `.backup` copies, and an ordered `manifest.json`, with mode `0700` on the backup directory. Backups hold the same sensitive content as the stores. Keep them until the migrated sessions open successfully, then delete them. `--no-backup` explicitly skips recovery copies.

Each SQL action is one transaction. The tool operates locally, needs no credentials, opens no network connections, and runs no commands from assistant stores. Incorrect selection or rewriting can still delete state or leave sessions pointing at dead paths. Follow [Restore](skills/agent-project-move/SKILL.md#restore) after a file-phase failure.

## Usage

Move the project directory first, then preview and apply the recorded-path move:

```bash
agent-project-move scan
agent-project-move move ~/src/app ~/work/app
agent-project-move move ~/src/app ~/work/app --apply
```

Use `-a claude,codex` to select assistants, or omit it for all three. The [skill procedures](skills/agent-project-move/SKILL.md) cover path ordering, [cross-host transfers](skills/agent-project-move/SKILL.md#transfer-between-hosts), [selected source retirement](skills/agent-project-move/SKILL.md#retire), and verification. `agent-project-move --help` lists the commands and options.

## Tested with

Each assistant changes its local storage without notice. `agent-project-move` is tested on Linux against these versions:

| Assistant   | Tested  |
| ----------- | ------- |
| Claude Code | 2.1.312 |
| Codex       | 0.165.0 |
| OMP         | 18.13.2 |

A newer version can add a database, a table, or a path-bearing column this tool does not know about, and those paths then stay stale after a move. Path values in JSON transcripts are rewritten wherever they appear, so new record kinds are covered. If a move leaves sessions behind, open an issue with the release tag or commit you run and the assistant's version.

## Releases

Releases follow the [versioning policy](RELEASING.md#versioning), and stable releases keep the [stability surface](RELEASING.md#stability-surface) compatible within a minor version.

## Agent skill

The [skill](skills/agent-project-move/SKILL.md) surveys recorded paths, confirms the plan, applies it, and verifies the result. It uses the command on `PATH` or its bundled script. Start a new assistant session after installation, or run `/reload-plugins` in OMP.

| Assistant   | Explicit invocation                              |
| ----------- | ------------------------------------------------ |
| Claude Code | `/agent-project-move`                            |
| Codex       | `$agent-project-move`, or pick it from `/skills` |
| OMP         | `/skill:agent-project-move`                      |

## Documentation

| Document                                          | Description                                                  |
| ------------------------------------------------- | ------------------------------------------------------------ |
| [Agent skill](skills/agent-project-move/SKILL.md) | Procedures for moving, transferring, retiring, and restoring |
| [Design](docs/reference/design.md)                | Selection, rewriting, and apply-order constraints            |
| [Assistant stores](docs/reference/stores.md)      | What each assistant stores and how a move rewrites it        |

## Development

[`AGENTS.md`](AGENTS.md) is the contributor entry point for people and coding agents alike.

## License

Copyright (c) 2026 [Hakula](https://hakula.xyz). Licensed under the [MIT License](LICENSE).
