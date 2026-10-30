#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Actions Tests
# ==================================================================================================

use std/assert

use ./actions.nu [column-statements]

def "test a colliding destination row wins" [] {
  let setup = (
    "CREATE TABLE t (id INTEGER PRIMARY KEY, c TEXT UNIQUE); "
    + "INSERT INTO t (c) VALUES ('/work/app'); "
    + "INSERT INTO t (c) VALUES ('/work/new');"
  )
  let statements = (column-statements t c "/work/app" "/work/new" --collide)
  let remaining = (
    ^sqlite3 -json :memory: (
      $setup + " " + ($statements | each {|statement| $statement + ";" } | str join " ")
      + " SELECT c FROM t;"
    )
    | complete
    | get stdout
    | from json
    | get c
  )

  assert equal $remaining ["/work/new"]
}
