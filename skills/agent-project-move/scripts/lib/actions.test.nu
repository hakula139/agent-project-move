#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Actions Tests
# ==================================================================================================

use std/assert

use ./actions.nu [column-statements]
use ./sqlite.nu [sql-quote]

def "test column rewrites preserve root suffixes" [] {
  let values = ["/work/app" "/work/app/sub" "/work/app-peer" "/work/app//sub"]
  let rows = (
    $values
    | each {|value| $"INSERT INTO t \(c\) VALUES \((sql-quote $value)\);" }
    | str join " "
  )
  let setup = $"CREATE TABLE t \(id INTEGER PRIMARY KEY, c TEXT\); ($rows)"

  let sql = (
    column-statements "t" "c" "/work/app" "/"
    | each {|statement| $statement + ";" }
    | str join " "
  )
  let remaining = (
    ^sqlite3 -json ":memory:" $"($setup) ($sql) SELECT c FROM t ORDER BY id;"
    | complete
    | get stdout
    | from json
    | get c
  )

  assert equal $remaining ["/" "/sub" "/work/app-peer" "//sub"]
}
