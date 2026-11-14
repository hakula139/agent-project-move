#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Actions Tests
# ==================================================================================================

use std/assert

use ./actions.nu [column-statements]
use ./sqlite.nu [sql-quote]

def "test column rewrites preserve root suffixes and colliding destination rows" [] {
  let cases = [
    {
      name: "a colliding destination wins"
      new: "/work/new"
      prefix: ""
      collide: true
      values: ["/work/app" "/work/new"]
      expected: ["/work/new"]
    }
    {
      name: "the destination root preserves child suffixes"
      new: "/"
      prefix: ""
      collide: false
      values: ["/work/app" "/work/app/sub" "/work/app-peer" "/work/app//sub"]
      expected: ["/" "/sub" "/work/app-peer" "//sub"]
    }
    {
      name: "a prefixed destination root preserves child suffixes"
      new: "/"
      prefix: "global:"
      collide: false
      values: ["global:/work/app" "global:/work/app/sub" "/work/app/sub" "global:/work/app//sub"]
      expected: ["global:/" "global:/sub" "/work/app/sub" "global://sub"]
    }
  ]

  for case in $cases {
    let rows = (
      $case.values
      | each {|value| $"INSERT INTO t \(c\) VALUES \((sql-quote $value)\);" }
      | str join " "
    )
    let setup = $"CREATE TABLE t \(id INTEGER PRIMARY KEY, c TEXT UNIQUE\); ($rows)"

    let statements = (
      column-statements "t" "c" "/work/app" $case.new --prefix $case.prefix --collide=$case.collide
    )
    let sql = (
      $statements
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

    assert equal $remaining $case.expected $case.name
  }
}
