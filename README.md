# agent-project-move

[![CI](https://github.com/hakula139/agent-project-move/actions/workflows/ci.yml/badge.svg)](https://github.com/hakula139/agent-project-move/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Repair the project paths recorded by [Claude Code](https://claude.com/claude-code), [Codex](https://openai.com/codex/), and [OMP](https://omp.sh) after a directory moves, transfer sessions between hosts, and retire selected session copies.

Moving a project can leave sessions under its old path, and copying a repository to another host leaves transcripts behind. `agent-project-move` previews state changes and applies them only with `--apply`. Export creates a bundle without changing the source store.

## Install

Choose a plugin, a standalone [Agent Skill](https://agentskills.io), or the Nix package. Native Windows is unsupported. Outside Nix, install the skill's [required tools](skills/agent-project-move/SKILL.md#requirements), including [Nushell](https://www.nushell.sh/book/installation.html).

### Claude Code plugin

```bash
claude plugin marketplace add hakula139/agent-project-move
claude plugin install agent-project-move@agent-project-move
```

Pin a release with `hakula139/agent-project-move#vX.Y.Z`.

### Codex plugin

```bash
codex plugin marketplace add hakula139/agent-project-move
codex plugin add agent-project-move@agent-project-move
```

Pin a release with `--ref vX.Y.Z` on `marketplace add`.

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

The package includes its runtime tools and supports `aarch64-darwin`, `aarch64-linux`, and `x86_64-linux`. Enable Nix flakes before using it. The optional Cachix cache can speed up the first build.

Home Manager users add the flake input and import the module:

```nix
inputs.agent-project-move.url = "github:hakula139/agent-project-move";

# In the Home Manager configuration
imports = [ inputs.agent-project-move.homeModules.default ];

programs.agent-project-move.enable = true;
```

The module installs the command and links the skill into `~/.agents/skills` and `~/.claude/skills`. Set `programs.agent-project-move.skillDirectories` to change the list, or use `overlays.default` to install the package through an overlay.

## Agent skill

Start a new assistant session after installation, or run `/reload-plugins` in OMP.

| Assistant   | Explicit invocation                              |
| ----------- | ------------------------------------------------ |
| Claude Code | `/agent-project-move`                            |
| Codex       | `$agent-project-move`, or pick it from `/skills` |
| OMP         | `/skill:agent-project-move`                      |

## Usage

With the command installed, move the project directory first, then preview and apply the recorded-path move:

```bash
agent-project-move scan
agent-project-move move ~/src/app ~/work/app
agent-project-move move ~/src/app ~/work/app --apply
```

Use `-a claude,codex` to select assistants, or omit it for all three. The [skill procedures](skills/agent-project-move/SKILL.md) cover path ordering, [cross-host transfers](skills/agent-project-move/SKILL.md#transfer-between-hosts), [selected source retirement](skills/agent-project-move/SKILL.md#retire), and verification. `agent-project-move --help` lists the commands and options.

Before applying, close affected assistant sessions, including your own, to avoid losing concurrent writes. Applied changes create private recovery backups by default. Keep them until the migrated sessions open successfully. Read the skill's [concurrency and recovery guidance](skills/agent-project-move/SKILL.md#concurrent-sessions) before changing live stores.

## Tested with

Each assistant changes its local storage without notice. `agent-project-move` is tested on Linux against these versions:

| Assistant   | Tested  |
| ----------- | ------- |
| Claude Code | 2.1.312 |
| Codex       | 0.165.0 |
| OMP         | 18.13.2 |

A newer version can add a database, a table, or a path-bearing column this tool does not know about, and those paths then stay stale after a move. Path values in JSON transcripts are rewritten wherever they appear, so new record kinds are covered. If a move leaves sessions behind, open an issue with the release tag or commit you run and the assistant's version.

## Documentation

| Document                                          | Description                                                  |
| ------------------------------------------------- | ------------------------------------------------------------ |
| [Agent skill](skills/agent-project-move/SKILL.md) | Procedures for moving, transferring, retiring, and restoring |
| [Design](docs/reference/design.md)                | Selection, rewriting, and apply-order constraints            |
| [Assistant stores](docs/reference/stores.md)      | What each assistant stores and how a move rewrites it        |

Contributors start with [`AGENTS.md`](AGENTS.md). Releases follow the [versioning policy](RELEASING.md#versioning) and [stability surface](RELEASING.md#stability-surface).

## License

Copyright (c) 2026 [Hakula](https://hakula.xyz). Licensed under the [MIT License](LICENSE).
