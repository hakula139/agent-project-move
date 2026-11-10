# Nushell

The command and its tests are Nushell. General Nushell conventions and traps live in the [`nushell` skill](https://github.com/hakula139/plugins/blob/main/plugins/hakula-languages/skills/nushell/SKILL.md) in hakula139/plugins, and this page covers the module layout and the rules specific to agent-project-move.

## Modules

- **Exports**: export only what another module or the module's test calls. Layer modules so dependencies point one way: generic helpers, then stores, then orchestration, then the entry.
- **Imports**: import a module by name when its commands share verbs with siblings, so calls read `claude plan-move`. Otherwise list the imported commands (`use ./paths.nu [path-map path-match]`), so a reader sees where each name comes from. Tests may `use ./<module>.nu *`.

## Traps

- **`edit-file` refuses a file that `open --raw` collects to `binary`.** `lib/actions.nu` checks the content's shape with `describe` before rewriting a file.
- **`url encode` escapes characters a file URI keeps.** To match the `file://` URIs Codex builds with the url crate, pass only non-ASCII characters and the crate's escape set (controls, space, `"#%<>?{}`, the backtick, and `\`) through `url encode --all`.
- **Read `$env.HOME` at call time.** Every `$env.HOME` read in the scripts happens then, in the stores, the entry, and the backup base in `lib/actions.nu`, which lets a test swap `HOME` with `with-env`. This overrides the skill's advice to build home paths from `$nu.home-dir`.

## Testing

Path encodings, rewrites, and SQL conditions are easy to get subtly wrong, so cover them with tests.

- **Test data**: use invented paths, never one from a real machine.
