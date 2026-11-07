# Nushell

The command and its tests are Nushell. General Nushell conventions and traps live in the [`nushell` skill](https://github.com/hakula139/nixos-config/blob/main/home/modules/llm-assistants/shared/skills/nushell/SKILL.md) that nixos-config installs, and this page covers the module layout and the rules specific to agent-project-move.

## Modules

- **Exports**: export only what another module or the module's test calls. Layer modules so dependencies point one way: generic helpers, then stores, then orchestration, then the entry.
- **Imports**: import a module by name when its commands share verbs with siblings, so calls read `claude plan-move`. Otherwise list the imported commands (`use ./paths.nu [path-map path-match]`), so a reader sees where each name comes from. Tests may `use ./<module>.nu *`.

## Linting

`nu-check` fails only on diagnostics with severity `Error`. Read the deprecation warnings when the pinned Nushell changes.

## Traps

- **`edit-file` refuses a file that `open --raw` collects to `binary`.** `src/lib/actions.nu` checks the content's shape with `describe` before rewriting a file.
- **`url encode` escapes characters a file URI keeps.** To match the `file://` URIs Codex builds with the url crate, pass only non-ASCII characters and the crate's escape set (controls, space, `"#%<>?{}`, the backtick, and `\`) through `url encode --all`.
- **Read `$env.HOME` at call time.** Every `$env.HOME` read in `src/` happens then, in the stores, the entry, the backup base in `src/lib/actions.nu`, and `src/install.nu`, which lets a test swap `HOME` with `with-env`. This overrides the skill's advice to build home paths from `$nu.home-dir`.

## Testing

Path encodings, rewrites, and SQL conditions are easy to get subtly wrong, so cover them with tests.

- **Test data**: use invented names such as `/home/u/src/app`, never a path from a real machine.
