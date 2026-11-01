# Nushell

The command and its tests are Nushell.

## Project layout

`src/` holds the entry at its root, `lib/` holds helpers shared across modules, and `stores/` holds one interchangeable module per assistant behind a shared interface.

- **Modules**: the entry is `<name>.nu` and holds `main` with its subcommands. Modules are `<module>.nu` files named by their noun, a module's test sits beside it as `<module>.test.nu`, and byte-exact inputs live under `stores/fixtures/<group>/<case>/`.
- **Exports**: export only what another module or the module's test calls. Layer modules so dependencies point one way: generic helpers, then stores, then orchestration, then the entry.
- **Imports**: import a module by name when its commands share verbs with siblings, so calls read `claude plan-move`. Otherwise list the imported commands (`use ./paths.nu [path-map path-match]`), so a reader sees where each name comes from. Tests may `use ./<module>.nu *`.

## Linting

`nu-check` fails only on diagnostics with severity `Error`, because `nu --ide-check` exits 0 even when it finds one. It passes a mistyped command as an external call, so run changed code through its tests, and read the deprecation warnings when the pinned Nushell changes.

## Traps

These traps assume the Nushell Book's [Thinking in Nu](https://www.nushell.sh/book/thinking_in_nu.html) and [Coming from Bash](https://www.nushell.sh/book/coming_from_bash.html). Reproduce a trap on the pinned Nushell before adding it.

- **`from json` accepts some plain text, so `try` cannot validate JSON.** `open` on an empty JSON, YAML, or NUON file returns null, while truncated JSON raises, so check the shape (`$j | describe | str starts-with "record"`) before reading a field.
- **`get -o` raises on rows that are not records.** It tolerates a missing column but fails on a list of strings or a scalar, so wrap it in `try` when the shape is unverified.
- **Return annotations do not validate dynamic output.** A `-> record` function can return a list from an untyped helper, and `get -o` on an empty list returns `[]`, which `default` keeps.
- **A `mut` or a defaulted closure parameter takes the type of its initial value.** Each later value is checked against that type, at parse time when its type is known and at runtime otherwise, so `mut current = null` rejects a string, `mut n = 0` rejects a float, and `generate {|row, acc = null| ...}` raises `Can't convert to nothing` once it passes `acc` a value. Annotate the union, as in `mut current: oneof<string, nothing> = null`, because `nu-check` misses the runtime case.
- **`math sum` errors on an empty list.** Use `| append 0 | math sum`.
- **`into datetime` reads a bare integer as nanoseconds.** A Unix timestamp in seconds needs `into datetime --format '%s'`.
- **`update` binds a named closure parameter to the row, not the cell.** Read the cell value from `$in`, as in `update body { $in | append $line }`.
- **`open --raw` yields a byte stream, which collects to `binary` on invalid UTF-8.** A `: string` parameter or a `string ->` input then raises a type error, so `edit-file` checks the shape before rewriting a file.
- **A binary operator continues an expression only inside parentheses.** In a closure body, `($a)` followed by a line starting `and ($b)` calls a command named `and`, so wrap the whole expression in parentheses. A list element splits on `+` the same way even on one line, so `["a" + $x]` holds three elements and needs parentheses or interpolation.
- **`url encode` escapes characters a file URI keeps.** To match the `file://` URIs Codex builds with the url crate, pass only non-ASCII characters and the crate's escape set (controls, space, `"#%<>?{}`, the backtick, and `\`) through `url encode --all`.
- **Dynamic regexes need single-quoted pieces.** Parentheses interpolate in both `$"..."` and `$'...'`, and double quotes consume backslashes, so concatenate: `($label + ' (?<n>\d+)')`.
- **A nonzero external exit ends the script with that code and prints nothing.** Tolerate it with `try` or `| complete` and `.exit_code`.

## Testing

Give a script a `<script>.test.nu` beside it when its output is easy to get subtly wrong, such as a path encoding, a rewrite, or a SQL condition.

- **Tests**: commands named `test <behavior>` in plain words, asserting with `std/assert`.
- **Structured inputs**: write JSON and JSONL test inputs as Nushell records and lists, serialized with `to json --raw` and joined with `"\n"` for JSONL.
- **Fixtures**: when several cases differ only in document-like or byte-sensitive inputs, make them golden files under `stores/fixtures/<group>/<case>/`, where a `case.nuon` holds what the files cannot express. Copy each input into a `mktemp` directory before running the script, so the script never writes to a fixture.
- **Test data**: use invented names such as `/home/u/src/app`, never a path from a real machine.
