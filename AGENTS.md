# AGENTS.md: agent-project-move

`agent-project-move` is a Nushell command and an agent skill that repair the project paths recorded by Claude Code, Codex, OpenCode, and OMP after a directory moves, transfer sessions between hosts, and prune state whose directory is gone.

This file holds the rules for every change and points to the conventions for each area. [`README.md`](README.md) covers what the tool does and how to install and use it, and `docs/` holds the reference and the conventions.

## Read before you edit

| When the change touches                          | Read                                             |
| ------------------------------------------------ | ------------------------------------------------ |
| A `.nu` file or a `.test.nu` file                | [Nushell](docs/conventions/nushell.md)           |
| The flake, the package, the module, hooks, or CI | [Development](docs/conventions/development.md)   |
| Commits, branches, pull requests, or issues      | [GitHub](docs/conventions/github.md)             |
| A store module or an assistant's on-disk state   | [Assistant stores](docs/reference/stores.md)     |
| Move, transfer, prune, or backup behavior        | [Design](docs/reference/design.md)               |
| A release                                        | [Release skill](.agents/skills/release/SKILL.md) |

## Layout

```text
.
├── .agents/                # Agent skills, linked from `.claude/`
├── .cspell/                # Project spelling dictionary
├── .github/                # CI and release workflows, issue forms, shared setup action
├── docs/
│   ├── conventions/        # Development, GitHub, and Nushell conventions
│   └── reference/          # Design and assistant stores
├── nix/                    # Package, Home Manager module, and module tests
├── scripts/                # Vendored Nushell test runner and diagnostic check
├── skills/                 # Agent Skill directories installed by the package
└── src/                    # The command, orchestration, helpers, and one module per store
```

`src/` keeps the command in `<name>.nu` at its root, shared helpers in `lib/`, and one interchangeable module per assistant in `stores/`. A test sits beside its module as `<module>.test.nu`, and byte-exact inputs live under `stores/fixtures/`.

## Rules for every change

- Run the pre-commit hooks on every commit. In each new checkout or worktree, run `nix develop -c true` once to generate the hook config. Never bypass the hooks with `--no-verify` or `PRE_COMMIT_ALLOW_NO_CONFIG`.
- Run the [verification](#verification) block before review.
- Add new words to `.cspell/words.txt` in alphabetical order. `cspell` scans Nushell sources too, so a new word in a comment fails the same way as one in `README.md`.
- Update whatever the change makes stale: the README's usage, tested versions, and safety model, the reference pages, the skill under `skills/`, and the Home Manager module in `nix/home-manager.nix` when the command or its skill changes what it installs.
- Cross-check every claim in a document against the code or a run before writing it. The store formats described in [Assistant stores](docs/reference/stores.md) are the ones the modules read, and a release of any assistant can change them.
- Keep a path change and its two representations in sync: `<old>` matches as an exact, case-sensitive string prefix, while a rewritten value keeps the spelling the working directory reports at the destination.
- Issues, pull requests, and their comments link only public material. Never reference local working notes, private paths, or private repositories.

## Verification

Run after implementation and before review:

```bash
nix flake check                                # Hooks, the module tests, and every Nushell test
nix build                                      # Build the command, its wrapper, and the installed skill
nix develop -c nu scripts/nu-test.nu <file>... # Run one or more test files directly
nix run . -- scan                              # Exercise a subcommand through the packaged wrapper
```

[Development](docs/conventions/development.md#ci) describes the CI jobs and what gates a merge.

## Documentation maintenance

Each rule has one home, which other pages link to. Add to this file or `docs/` only a constraint that is invisible, destructive, or already cost someone a debugging session, and leave out whatever a model can read off the flake, a module, or the tests.

- `README.md` is for a user evaluating or running the tool: the problem it solves, prerequisites, install, usage, safety, and the assistant versions it is tested with. Keep internal progress out.
- `AGENTS.md` and `docs/` are for whoever changes the code.
- `docs/reference/` explains how the tool and each store behave, while `skills/agent-project-move/SKILL.md` follows a reader through a move, transfer, prune, or restore.
- Keep the layout tree accurate at its current depth.
- Describe current behavior and usage, and put change summaries and comparisons with removed approaches in the PR description.

## Code review

Review the complete change, its affected callers, and the adjacent code it touches against the convention docs. Check in particular:

- Cross-file consistency: functions that answer the same question across the four stores have the same shape, naming, and return type.
- Comment hygiene: no comment repeats the code, and each non-obvious constraint keeps its reason.
- One direction of dependency: helpers, then stores, then orchestration, then the entry.
- Duplicated logic that a shared helper already owns.
- Test data with invented names such as `/home/u/src/app`, never a path from a real machine.
