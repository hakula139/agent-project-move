# Nushell

The command and its tests are Nushell.

- **Entry point**: `def main` with typed parameters, so Nushell checks arity and types.
- **Script-relative resources**: bind `const SCRIPT_DIR = path self .` after the header and imports. It resolves at parse time from the defining file, so the package must ship those resources beside the script.
- **Help**: keep the script header to its purpose and operating constraints, and document usage at each command and parameter so `--help` carries it. Point to it with `Run with --help for usage.` only when the header says something else.
- **Multiline strings**: indent the literal with the code, with the opening quote, content, and closing quote at one column, then `| str dedent` from `std-rfc/str` on the next line and any enclosing parenthesis on its own line.

## Project layout

`src/` holds the entry at its root, `lib/` holds helpers shared across modules, and `stores/` holds one interchangeable module per assistant behind a shared interface.

- **Entry**: `<name>.nu` holds the header, the imports, and `main` with its subcommands, and nothing else. Modules are `<module>.nu` files named by their noun. A module's test sits beside it as `<module>.test.nu`.
- **Modules**: export only what another module or the module's test calls. Layer modules so dependencies point one way: generic helpers, then stores, then orchestration, then the entry.
- **Imports**: import a module by name when its commands share verbs with siblings, so calls read `claude plan-move`. Otherwise list the imported commands (`use ./paths.nu [path-map path-match]`), so a reader sees where each name comes from. Tests may `use ./<module>.nu *`.
- **Packaging**: `nix/agent-project-move.nix` copies `src/`'s `.nu` files, excluding `*.test.nu`, to `$out/share/agent-project-move/`, installs the entry without its extension so `--help` names the command, installs the skill under `$out/share/skills/`, and wraps `nu --no-config-file $out/share/agent-project-move/agent-project-move` as `$out/bin/agent-project-move` with its runtime tools on `PATH`.

## Traps

These traps assume the Nushell Book's [Thinking in Nu](https://www.nushell.sh/book/thinking_in_nu.html) and [Coming from Bash](https://www.nushell.sh/book/coming_from_bash.html). Reproduce a trap on the pinned Nushell before adding it.

### Parsing and data

- **`from json` accepts some plain text, so `try` cannot validate JSON.**

  - `open` on an empty JSON, YAML, or NUON file returns null, while truncated JSON raises.
  - Check the shape (`$j | describe | str starts-with "record"`) before reading a field.

- **`get -o` raises on rows that are not records.** It tolerates a missing column but fails on a list of strings or a scalar, so wrap it in `try` when the shape is unverified.

- **Return annotations do not validate dynamic output.** A `-> record` function can return a list from an untyped helper, and `get -o` on an empty list returns `[]`, which `default` keeps.

- **A `mut` or a defaulted closure parameter takes the type of its initial value.** Each later value is checked against that type, at parse time when its type is known and at runtime otherwise, so `mut current = null` rejects a string, `mut n = 0` rejects a float, and `generate {|row, acc = null| ... }` raises `Can't convert to nothing` once it passes `acc` a value. Annotate the union, as in `mut current: oneof<string, nothing> = null`, because `nu-check` misses the runtime case.

- **`math sum` errors on an empty list.** Use `| append 0 | math sum`.

- **`open --raw` yields a byte stream, which collects to `binary` on invalid UTF-8.** A `: string` parameter or a `string ->` input then raises a type error. To require UTF-8, pipe the stream itself into `into string` inside `try`, which raises `Non-UTF8 string` on invalid bytes and on a UTF-16 BOM.

### Strings and arguments

- **Bare words depend on context.** `if $x { green }` calls a command named `green`, `where after != before` compares the `after` column with the string `"before"` (write `where after != $it.before`), and an untyped `1min` arrives as a duration while a `: string` parameter coerces it.

- **A binary operator continues an expression only inside parentheses.** In a closure body, `($a)` followed by a line starting `and ($b)` calls a command named `and`, so wrap the whole expression in parentheses. A list element splits on `+` the same way even on one line, so `["a" + $x]` holds three elements and needs parentheses or interpolation.

- **List elements containing commas need quotes.** `[--sort=a,b]` passes two arguments.

- **Dynamic regexes need single-quoted pieces.** Parentheses interpolate in both `$"..."` and `$'...'`, and double quotes consume backslashes, so concatenate: `($label + ' (?<n>\d+)')`.

- **`url encode` encodes more than a URL path keeps.** It writes `-`, `_`, and `~` as `%2D`, `%5F`, and `%7E`, while the url crate's file-path encoding keeps them literal, so encode a path segment character by character against that set to match Codex's `file://` URIs.

### External commands

- **A nonzero external exit ends the script with that code and prints nothing.** Tolerate it with `try` or `| complete` and `.exit_code`.

## Testing

Give a script a `<script>.test.nu` beside it when its output is easy to get subtly wrong, such as a path encoding, a rewrite, or a SQL condition.

- **Tests**: commands named `test <behavior>` in plain words, asserting with `std/assert`.

- **Structured inputs**: write JSON and JSONL test inputs as Nushell records and lists, serialized with `to json --raw` and joined with `"\n"` for JSONL.

- **Fixtures**: when several cases differ only in document-like or byte-sensitive inputs, make them golden files under `stores/fixtures/<group>/<case>/`.

  - A `case.nuon` holds what the files cannot express, laid out as Nushell source.
  - Copy each input into a `mktemp` directory before running the script, so the script never writes to a fixture.

- **Record lists**: a list of records shares one layout, so when an item wraps, break every item one field per line, including inline case tables and action or column specs.

- **Running**: `nu scripts/nu-test.nu <file>...` runs each test in its own process, and exits nonzero when a test fails or a file holds none.

- **Test data**: use invented names such as `/home/u/src/app`, never a path from a real machine.
