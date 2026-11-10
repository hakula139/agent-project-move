# AGENTS.md: agent-project-move

`agent-project-move` is a Nushell command and an agent skill that repair the project paths recorded by Claude Code, Codex, and OMP after a directory moves, transfer sessions between hosts, and prune state whose directory is gone.

## Read before you edit

| When the change touches                        | Read                                                                        |
| ---------------------------------------------- | --------------------------------------------------------------------------- |
| A `.nu` file or a `.test.nu` file              | [Nushell](docs/conventions/nushell.md)                                      |
| CI or a workflow                               | [devkit's CI guide](https://github.com/hakula139/devkit/blob/v3/docs/ci.md) |
| A store module or an assistant's on-disk state | [Assistant stores](docs/reference/stores.md)                                |
| Move, transfer, prune, or backup behavior      | [Design](docs/reference/design.md)                                          |
| A release                                      | [RELEASING.md](RELEASING.md)                                                |

## Rules for every change

- Run the pre-commit hooks on every commit. In each new checkout or worktree, run `nix develop -c true` once to install them. Never bypass the hooks with `--no-verify` or `PRE_COMMIT_ALLOW_NO_CONFIG`, and fix the cause whenever a hook, test, or CI job fails.
- Wrap code and comments at 100 columns, counting the indent, end section banners at column 100, and keep a single-line string literal whole at any length.
- Update whatever the change makes stale: the README's usage, tested versions, and safety model, the reference pages, the skill under `skills/`, and the Home Manager module in `nix/home-manager.nix` when the command or its skill changes what it installs.
- Keep `skills/agent-project-move/` self-contained, because skill installers copy only that directory and its `SKILL.md` falls back to the bundled `scripts/` inside it. Leave `${CLAUDE_SKILL_DIR}` out of `SKILL.md`, since Codex and OMP read it literally.
- The store formats in [Assistant stores](docs/reference/stores.md) are the ones the modules read, and a release of any assistant can change them, so check a store claim against a run.
- Issues, pull requests, and their comments link only public material. Never reference local working notes, private paths, or private repositories.

## Verification

```bash
nix flake check --all-systems
nix develop -c run-hooks
nix run . -- scan
```

## Documentation maintenance

Each rule has one home, which other pages link to. Add to this file or `docs/` only a constraint that is invisible, destructive, or already cost someone a debugging session, and leave out whatever a model can read off the flake, a module, or the tests.

- `README.md` is for a user evaluating or running the tool: the problem it solves, prerequisites, install, usage, safety, and the assistant versions it is tested with. Keep internal progress out.
- `AGENTS.md` and `docs/` are for whoever changes the code.
- `docs/reference/` explains how the tool and each store behave, while `skills/agent-project-move/SKILL.md` follows a reader through a move, transfer, prune, or restore. The skill restates only what an agent needs to run and recover a procedure, since skill installers copy only its directory.

## Code review

Review the change and its affected callers against the convention docs, and check in particular that functions answering the same question across the three stores share shape, naming, and return type, and that logic two stores need lives in `lib/`.
