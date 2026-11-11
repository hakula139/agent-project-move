# AGENTS.md: agent-project-move

`agent-project-move` is a Nushell command and an agent skill that repair the project paths recorded by Claude Code, Codex, and OMP after a directory moves, transfer sessions between hosts, and prune state whose directory is gone.

## Read before you edit

| When the change touches                        | Read                                                                        |
| ---------------------------------------------- | --------------------------------------------------------------------------- |
| CI or a workflow                               | [devkit's CI guide](https://github.com/hakula139/devkit/blob/v3/docs/ci.md) |
| A store module or an assistant's on-disk state | [Assistant stores](docs/reference/stores.md)                                |
| Move, transfer, prune, or backup behavior      | [Design](docs/reference/design.md)                                          |
| A release                                      | [RELEASING.md](RELEASING.md)                                                |

## Code

- Wrap code and comments at 100 columns, counting the indent.
- Build home paths from `$env.HOME`, read when the command runs, so a test can swap `HOME` with `with-env`. This overrides the `nushell` skill's advice to use `$nu.home-dir`, which Nushell fixes at startup.

## Skill directory

Skill installers copy only `skills/agent-project-move/`, and its `SKILL.md` falls back to the bundled `scripts/`, so keep that directory self-contained. `SKILL.md` restates only what an agent needs to run and recover a procedure, and leaves out `${CLAUDE_SKILL_DIR}`, since Codex and OMP read it literally.

## Verification

In each new checkout or worktree, run `nix develop -c true` once to install the pre-commit hooks and link their config, and never bypass them with `--no-verify` or `PREK_ALLOW_NO_CONFIG`.

```bash
nix flake check --all-systems
nix develop -c run-hooks
nix run . -- scan
```
