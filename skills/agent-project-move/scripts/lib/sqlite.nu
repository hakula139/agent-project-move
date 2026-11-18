# ==================================================================================================
# Agent Project Move: SQLite
# ==================================================================================================
# Queries and row statements over the assistants' SQLite databases.
# ==================================================================================================

use ./paths.nu [glob-under]

def sql-identifier [name: string]: nothing -> string {
  let escaped = ($name | str replace --all '"' '""')
  $'"($escaped)"'
}

export def sql-quote [value: any]: nothing -> string {
  let kind = ($value | describe)
  if $value == null {
    "NULL"
  } else if ($kind | str starts-with "int") or ($kind | str starts-with "float") {
    $value | into string
  } else if $kind == "bool" {
    if $value { "1" } else { "0" }
  } else {
    let escaped = (
      $value
      | into string
      | str replace --all "'" "''"
    )
    $"'($escaped)'"
  }
}

export def sql-list [values: list]: nothing -> string {
  $values
  | each {|value| sql-quote $value }
  | str join ", "
}

export def sqlite-rows [db: string, query: string]: nothing -> list {
  let run = (
    $query
    | ^sqlite3 $db
        -readonly
        -json
    | complete
  )
  if $run.exit_code != 0 {
    error make --unspanned {
      msg: $"sqlite3 failed on ($db): ($run.stderr | str trim)"
      help: $"Close the assistant that uses ($db) and rerun the same command."
    }
  }

  let output = ($run.stdout | str trim)
  if $output == "" {
    []
  } else {
    $output | from json
  }
}

def sqlite-columns [db: string, table: string]: nothing -> list<string> {
  sqlite-rows $db $"PRAGMA table_info\((sql-identifier $table)\)" | get name
}

def sqlite-has-table [db: string, table: string]: nothing -> bool {
  let query = $"SELECT name FROM sqlite_master WHERE type = 'table' AND name = (sql-quote $table)"
  sqlite-rows $db $query | is-not-empty
}

# The highest-numbered database of one family that carries any expected table.
export def latest-db [dir: string, pattern: string, tables: list<string>]: nothing -> any {
  let candidates = (
    glob-under $dir $pattern
    | each {|db|
      let version = (
        $db
        | path basename
        | parse --regex '_(?<n>\d+)\.sqlite$'
        | get -o 0.n
        | default "0"
        | into int
      )
      {
        db: $db
        version: $version
      }
    }
    | where {|entry| $tables | any {|table| sqlite-has-table $entry.db $table } }
    | sort-by version
  )

  if ($candidates | is-empty) {
    null
  } else {
    $candidates
    | last
    | get db
  }
}

# SQL for a column equal to a path or under it. `substr` counts characters, so non-ASCII paths,
# `_`, and `%` stay literal. `LIKE` would fold case and treat both as wildcards.
export def path-condition [
  column: string
  paths: list<string>
]: nothing -> string {
  $paths
  | each {|path|
    let value = (sql-quote $path)
    if $path == "/" {
      $"substr\(($column), 1, length\(($value)\)\) = ($value)"
    } else {
      $"($column) = ($value) OR substr\(($column), 1, length\(($value)\) + 1\) = ($value) || '/'"
    }
  }
  | each {|clause| $"\(($clause)\)" }
  | str join " OR "
}

export def table-columns [db: string, table: string]: nothing -> list<string> {
  if not ($db | path exists) { return [] }
  if not (sqlite-has-table $db $table) { return [] }
  sqlite-columns $db $table
}

export def sqlite-encoding [db: string]: nothing -> string {
  sqlite-rows $db "PRAGMA encoding" | get 0.encoding
}

# Refuse a bundle the target cannot load: a carried column the table lacks, or a NOT NULL column
# without a default that the bundle does not fill. Every other target column takes its default.
export def check-columns [
  db: string
  table: string
  columns: list<string>
  store: string
]: nothing -> nothing {
  let local = (table-columns $db $table)
  if ($local | is-empty) {
    error make --unspanned {
      msg: $"($store) is missing the ($table) table"
      help: $"Start ($store) once on this host, then rerun the import."
    }
  }

  let missing = ($columns | where {|column| $column not-in $local })
  if ($missing | is-not-empty) {
    let names = ($missing | str join ", ")
    let help = $"Update ($store) to the source host's version, start it, and rerun the import."
    error make --unspanned {
      msg: $"This host's ($store) has no column ($names) in ($table), which the bundle contains"
      help: $help
    }
  }

  let required = (
    sqlite-rows $db $"PRAGMA table_info\((sql-identifier $table)\)"
    | where {|row| $row.notnull == 1 and $row.dflt_value == null and $row.pk == 0 }
    | get name
    | where {|column| $column not-in $columns }
  )
  if ($required | is-not-empty) {
    let names = ($required | str join ", ")
    error make --unspanned {
      msg: $"($store) ($table) requires columns the bundle lacks ($names)"
      help: $"Update ($store) on the source host, export again, then rerun the import."
    }
  }
}

def sqlite-insert [
  table: string
  columns: list<string>
  values: list<string>
]: nothing -> string {
  let table = (sql-identifier $table)
  let names = ($columns | each {|column| sql-identifier $column } | str join ", ")
  let values = ($values | str join ", ")
  $"INSERT INTO ($table) \(($names)\) VALUES \(($values)\)"
}

# Insert a row unless a unique or primary key already holds it. Every other constraint failure
# aborts, so a row that violates NOT NULL or CHECK is never dropped silently.
export def sqlite-insert-if-new [
  table: string
  columns: list<string>
  row: record
]: nothing -> string {
  let values = (
    $columns
    | each {|column| sql-quote ($row | get -o $column) }
  )
  (sqlite-insert $table $columns $values) + " ON CONFLICT DO NOTHING"
}

# SQLite's quote() truncates TEXT at NUL. A BLOB cast keeps those bytes and the SQLite type.
export def sqlite-literal-rows [
  db: string
  table: string
  columns: list<string>
  condition: string
]: nothing -> list {
  let table = (sql-identifier $table)
  let projection = (
    $columns
    | each {|name|
      let column = (sql-identifier $name)
      let text = $"'CAST\(' || quote\(CAST\(($column) AS BLOB\)\) || ' AS TEXT\)'"
      let quoted = $"CASE typeof\(($column)\) WHEN 'text' THEN ($text) ELSE quote\(($column)\) END"
      $"($quoted) AS ($column)"
    }
    | str join ", "
  )
  sqlite-rows $db $"SELECT ($projection) FROM ($table) WHERE ($condition)"
}

def sql-cell [value: any, legacy: bool]: nothing -> string {
  if $legacy {
    if ($value | describe) == "string" {
      return (
        $value
        | split row "\u{0}"
        | each {|part| sql-quote $part }
        | str join " || char(0) || "
      )
    }
    return (sql-quote $value)
  }

  # These expressions carry data only. Bundle input must match one whole supported literal.
  let numeric = '-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?'
  let blob = "X'(?:[0-9A-Fa-f]{2})*'"
  let pattern = (['\A(?:NULL|' $numeric "|" $blob '|CAST\(' $blob ' AS TEXT\))\z'] | str join)
  if ($value | describe) != "string" or $value !~ $pattern {
    error make --unspanned {msg: "Bundle contains an invalid SQLite literal"}
  }
  $value
}

# Compare keys using the destination schema and compare carried values by type and value.
export def sqlite-reconcile-literals [
  db: string
  table: string
  columns: list<string>
  key: string
  rows: list<record>
  --legacy
]: nothing -> list<string> {
  let references = (
    $columns
    | enumerate
    | each {|column|
      {
        name: $column.item
        local: $"local.(sql-identifier $column.item)"
        incoming: $"incoming.column($column.index + 2)"
      }
    }
  )
  let key_ref = ($references | where name == $key | first)
  if $key_ref == null {
    error make --unspanned {msg: $"Bundle ($table) is missing key column ($key)"}
  }
  let indexed = (
    $rows
    | each {|row| $columns | each {|column| sql-cell ($row | get $column) $legacy } }
    | enumerate
  )
  let values = (
    $indexed
    | each {|row| $" \(([$row.index] ++ $row.item | str join ', ')\)" }
    | str join ","
  )
  let comparisons = (
    $references
    | each {|r|
      let same_type = $"typeof\(($r.local)\) = typeof\(($r.incoming)\)"
      $"($same_type) AND ($r.local) IS ($r.incoming) COLLATE BINARY"
    }
    | str join " AND "
  )
  let query = (
    $"WITH incoming AS \(VALUES($values)\) "
    + $"SELECT incoming.column1 AS row_index, ($comparisons) AS same FROM incoming "
    + $"JOIN (sql-identifier $table) AS local ON ($key_ref.local) = ($key_ref.incoming)"
  )
  let matches = (sqlite-rows $db $query)
  let conflict = ($matches | where same == 0 | first)
  if $conflict != null {
    let row = ($rows | get $conflict.row_index)
    let id = ($row | get $key)
    error make --unspanned {
      msg: $"Existing ($table) row with ($key) ($id) differs from the bundle"
    }
  }
  let existing = ($matches | get -o row_index)
  $indexed
  | where {|row| $row.index not-in $existing }
  | each {|row| sqlite-insert $table $columns $row.item }
}

export def run-sql [
  db: string
  statements: list<string>
  --foreign-keys # Delete child rows through the schema's cascades
]: nothing -> nothing {
  if ($statements | is-empty) { return }
  let pragmas = if $foreign_keys { ["PRAGMA foreign_keys = ON;"] } else { [] }
  let sql = (
    $pragmas
    | append ["PRAGMA busy_timeout = 5000;" "BEGIN IMMEDIATE;"]
    | append ($statements | each {|statement| $statement + ";" })
    | append "COMMIT;"
    | str join "\n"
  )
  let run = (
    $sql
    | ^sqlite3 -bail $db
    | complete
  )
  if $run.exit_code != 0 {
    error make --unspanned {
      msg: $"sqlite3 failed on ($db): ($run.stderr | str trim)"
      help: $"Close the assistant that uses ($db) and rerun the same command."
    }
  }
}
