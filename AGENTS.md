# AGENTS.md: agent-project-move

`agent-project-move` is a Nushell command and an agent skill that repair the project paths recorded by Claude Code, Codex, and OMP after a directory moves, transfer sessions between hosts, and prune state whose directory is gone.

## Read before you edit

| When the change touches                        | Read                                                                        |
| ---------------------------------------------- | --------------------------------------------------------------------------- |
| CI or a workflow                               | [devkit's CI guide](https://github.com/hakula139/devkit/blob/v3/docs/ci.md) |
| A store module or an assistant's on-disk state | [Assistant stores](docs/reference/stores.md)                                |
| Move, transfer, prune, or backup behavior      | [Design](docs/reference/design.md)                                          |
| A release                                      | [RELEASING.md](RELEASING.md)                                                |

## Code layout

Wrap code and comments at 100 columns, counting the indent.

## Verification

```bash
nix flake check --all-systems
nix develop -c run-hooks
nix run . -- scan
```

## Documentation

- `README.md` covers the problem the tool solves, prerequisites, install, usage, the safety model, and the assistant versions it is tested with.
- `docs/reference/` explains how the tool and each store behave, while `skills/agent-project-move/SKILL.md` follows a reader through a move, transfer, prune, or restore and restates only what an agent needs to run and recover a procedure.
- Skill installers copy only `skills/agent-project-move/`, and its `SKILL.md` falls back to the bundled `scripts/`, so keep that directory self-contained. Leave `${CLAUDE_SKILL_DIR}` out of `SKILL.md`, since Codex and OMP read it literally.
