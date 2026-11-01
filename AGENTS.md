# AGENTS.md: agent-project-move

`agent-project-move` is a Nushell command and an agent skill that repair the project paths recorded by Claude Code, Codex, OpenCode, and OMP after a directory moves, transfer sessions between hosts, and prune state whose directory is gone.

## Read before you edit

| When the change touches                        | Read                                             |
| ---------------------------------------------- | ------------------------------------------------ |
| A `.nu` file or a `.test.nu` file              | [Nushell](docs/conventions/nushell.md)           |
| CI or a workflow                               | [CI](docs/reference/ci.md)                       |
| Commits, branches, pull requests, or issues    | [GitHub](docs/conventions/github.md)             |
| A store module or an assistant's on-disk state | [Assistant stores](docs/reference/stores.md)     |
| Move, transfer, prune, or backup behavior      | [Design](docs/reference/design.md)               |
| A release                                      | [Release skill](.agents/skills/release/SKILL.md) |

## Layout

```text
.
├── .agents/                # Agent skills, linked from `.claude/`
├── .cspell/                # Project spelling dictionary
├── .github/                # CI and release workflows, issue forms, shared setup action
├── bin/                    # POSIX shell launcher for a plain install
├── docs/
│   ├── conventions/        # GitHub and Nushell conventions
│   └── reference/          # CI, design, and assistant stores
├── nix/                    # Package, Home Manager module, and module tests
├── scripts/                # Vendored Nushell test runner and diagnostic check
├── skills/                 # Agent Skill directories installed by the package
└── src/                    # The command, orchestration, helpers, and one module per store
```

## Rules for every change

- Run the pre-commit hooks on every commit. In each new checkout or worktree, run `nix develop -c true` once to generate the hook config. Never bypass the hooks with `--no-verify` or `PRE_COMMIT_ALLOW_NO_CONFIG`. When a hook, test, or CI job fails, fix its cause, and keep a skip, ignore entry, or retry only where it is the design, such as the excluded fixtures.
- Wrap code and comments at 100 columns, counting the indent, end section banners at column 100, and keep a single-line string literal whole at any length.
- Add new words to `.cspell/words.txt` in alphabetical order. `cspell` scans Nushell sources too, so a new word in a comment fails the same way as one in `README.md`.
- Update whatever the change makes stale: the README's usage, tested versions, and safety model, the reference pages, the skill under `skills/`, and the Home Manager module in `nix/home-manager.nix` when the command or its skill changes what it installs.
- The store formats in [Assistant stores](docs/reference/stores.md) are the ones the modules read, and a release of any assistant can change them, so check a store claim against a run.
- Issues, pull requests, and their comments link only public material. Never reference local working notes, private paths, or private repositories.

## Verification

Run after implementation and before review:

```bash
nix flake check                                  # Hooks, the Home Manager module tests, and every Nushell test
nix build                                        # Build the command, its wrapper, and the installed skill
nix develop -c nu scripts/nu-test.nu <file>...   # Run one or more test files directly
nix run . -- scan                                # Exercise a subcommand through the packaged wrapper
```

[CI](docs/reference/ci.md) describes the CI jobs and what gates a merge.

## Documentation maintenance

Each rule has one home, which other pages link to. Add to this file or `docs/` only a constraint that is invisible, destructive, or already cost someone a debugging session, and leave out whatever a model can read off the flake, a module, or the tests.

- `README.md` is for a user evaluating or running the tool: the problem it solves, prerequisites, install, usage, safety, and the assistant versions it is tested with. Keep internal progress out.
- `AGENTS.md` and `docs/` are for whoever changes the code.
- `docs/reference/` explains how the tool and each store behave, while `skills/agent-project-move/SKILL.md` follows a reader through a move, transfer, prune, or restore. The skill restates only what an agent needs to run and recover a procedure, since only its directory is installed.
- Keep the layout tree accurate at its current depth.

## Code review

Review the change and its affected callers against the convention docs, and check in particular that functions answering the same question across the four stores share shape, naming, and return type, and that logic two stores need lives in `lib/`.
