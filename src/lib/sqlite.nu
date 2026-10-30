# ==================================================================================================
# Agent Project Move: SQLite
# ==================================================================================================
# Queries and row statements over the assistants' SQLite databases.
# ==================================================================================================

export def sql-quote [value: any]: nothing -> string {
  let kind = ($value | describe)
  if $value == null {
    "NULL"
  } else if ($kind | str starts-with "int") or ($kind | str starts-with "float") {
    $value | into string
  } else if $kind == "bool" {
    if $value { "1" } else { "0" }
  } else {
    "'" + ($value | into string | str replace --all "'" "''") + "'"
  }
}

export def sql-list [values: list]: nothing -> string {
  $values | each {|value| sql-quote $value } | str join ", "
}

export def sqlite-rows [db: string, query: string]: nothing -> list {
  let run = ($query | ^sqlite3 -readonly -json $db | complete)
  if $run.exit_code != 0 {
    error make --unspanned {
      msg: $"sqlite3 failed on ($db): ($run.stderr | str trim)"
      help: $"Close the assistant that uses ($db) and rerun the same command."
    }
  }
  let output = ($run.stdout | str trim)
  if $output == "" { [] } else { $output | from json }
}

export def sqlite-columns [db: string, table: string]: nothing -> list<string> {
  sqlite-rows $db $"PRAGMA table_info\(($table)\)" | get name
}

def sqlite-has-table [db: string, table: string]: nothing -> bool {
  let query = $"SELECT name FROM sqlite_master WHERE type = 'table' AND name = '($table)'"
  sqlite-rows $db $query | is-not-empty
}

# The highest-numbered database of one family that carries the expected table.
export def latest-db [pattern: string, table: string]: nothing -> any {
  let candidates = (
    glob $pattern
    | each {|db|
      let version = (
        ($db | path basename | parse --regex '_(?<n>\d+)\.sqlite$')
        | get -o 0.n
        | default "0"
        | into int
      )
      {db: $db, version: $version}
    }
    | where {|entry| sqlite-has-table $entry.db $table }
    | sort-by version
  )
  if ($candidates | is-empty) { null } else { $candidates | last | get db }
}

# SQL for a column equal to a path or under it. `substr` counts characters, so non-ASCII paths,
# `_`, and `%` stay literal. `LIKE` would fold case and treat both as wildcards.
export def path-condition [
  column: string
  paths: list<string>
  --prefix: string = ""
]: nothing -> string {
  $paths
  | each {|path|
    let value = (sql-quote ($prefix + $path))
    (
      $column + " = " + $value
      + " OR substr(" + $column + ", 1, length(" + $value + ") + 1) = " + $value + " || '/'"
    )
  }
  | each {|clause| "(" + $clause + ")" }
  | str join " OR "
}

export def table-columns [db: string, table: string]: nothing -> list<string> {
  if not ($db | path exists) { return [] }
  if not (sqlite-has-table $db $table) { return [] }
  sqlite-columns $db $table
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
    error make --unspanned {
      msg: $"This host's ($store) has no column ($missing | str join ', ') in ($table), which the bundle contains"
      help: $"Update ($store) on this host to the source host's version, start it once, then rerun the import."
    }
  }
  let required = (
    sqlite-rows $db $"PRAGMA table_info\(($table)\)"
    | where {|row| $row.notnull == 1 and $row.dflt_value == null and $row.pk == 0 }
    | get name
    | where {|column| $column not-in $columns }
  )
  if ($required | is-not-empty) {
    let names = ($required | str join ', ')
    error make --unspanned {
      msg: $"($store) ($table) requires columns the bundle lacks ($names)"
      help: $"Update ($store) on the source host, export again, then rerun the import."
    }
  }
}

def insert-parts [columns: list<string>, row: record]: nothing -> record {
  {
    names: ($columns | str join ", ")
    values: (
      $columns
      | each {|column| sql-quote ($row | get -o $column) }
      | str join ", "
    )
  }
}

# Insert a row unless a unique or primary key already holds it. Every other constraint failure
# aborts, so a row that violates NOT NULL or CHECK is never dropped silently.
export def sqlite-insert-if-new [
  table: string
  columns: list<string>
  row: record
]: nothing -> string {
  let parts = (insert-parts $columns $row)
  $"INSERT INTO ($table) \(($parts.names)\) VALUES \(($parts.values)\) ON CONFLICT DO NOTHING"
}

export def sqlite-insert-absent [
  table: string
  columns: list<string>
  natural: list<string>
  row: record
]: nothing -> string {
  let parts = (insert-parts $columns $row)
  let condition = (
    $natural
    | each {|column| $"($column) = (sql-quote ($row | get -o $column))" }
    | str join " AND "
  )
  let absent = $"NOT EXISTS \(SELECT 1 FROM ($table) WHERE ($condition)\)"
  $"INSERT INTO ($table) \(($parts.names)\) SELECT ($parts.values) WHERE ($absent)"
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
  let run = ($sql | ^sqlite3 -bail $db | complete)
  if $run.exit_code != 0 {
    error make --unspanned {
      msg: $"sqlite3 failed on ($db): ($run.stderr | str trim)"
      help: $"Close the assistant that uses ($db) and rerun the same command."
    }
  }
}
