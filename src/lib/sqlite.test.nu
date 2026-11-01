#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: SQLite Tests
# ==================================================================================================

use std/assert

use ./sqlite.nu [path-condition sql-quote]

const VALUES = [
  "/work/app"
  "/work/app/sub"
  "/work/apple"
  "/work/axb/sub"
  "/work/a%b"
  "/work/App"
  "/work/café"
  "global:/work/app"
]

def rows [table: string, values: list<string>]: nothing -> string {
  $values
  | each {|value| "INSERT INTO " + $table + " (c) VALUES (" + (sql-quote $value) + ");" }
  | str join " "
}

def "test SQL path conditions select the path and its children" [] {
  let setup = "CREATE TABLE t (id INTEGER PRIMARY KEY, c TEXT); " + (rows t $VALUES)
  let cases = [
    {name: "exact and children", path: "/work/app", prefix: "", expected: [1 2]}
    {name: "a sibling with an underscore", path: "/work/a_b", prefix: "", expected: []}
    {name: "a sibling with a percent", path: "/work/a", prefix: "", expected: []}
    {name: "a literal percent", path: "/work/a%b", prefix: "", expected: [5]}
    {name: "a case difference", path: "/work/App", prefix: "", expected: [6]}
    {name: "non-ASCII", path: "/work/café", prefix: "", expected: [7]}
    {name: "a prefixed job key", path: "/work/app", prefix: "global:", expected: [8]}
  ]

  for case in $cases {
    let condition = (path-condition c [$case.path] --prefix $case.prefix)
    let output = (
      ^sqlite3 -json :memory: ($setup + " SELECT id FROM t WHERE " + $condition + " ORDER BY id;")
      | complete
      | get stdout
      | str trim
    )
    let ids = if $output == "" { [] } else { $output | from json | get id | sort }
    assert equal $ids $case.expected $case.name
  }
}
