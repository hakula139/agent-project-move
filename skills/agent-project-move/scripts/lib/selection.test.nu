#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Selection Tests
# ==================================================================================================

use std/assert

use ./selection.nu *

def "test selection scopes roots and follows only their descendants" [] {
  let rows = [
    {id: "parent", cwd: "/work/app", parent: null}
    {id: "child", cwd: "/other/agent", parent: "parent"}
    {id: "grandchild", cwd: "/other/deep", parent: "child"}
    {id: "other-child", cwd: "/another/worker", parent: "parent"}
    {id: "retained", cwd: "/work/app", parent: null}
    {id: "nested", cwd: "/work/app/sub", parent: null}
    {id: "sibling", cwd: "/work/app-other", parent: null}
  ]
  let cases = [
    {name: "prefix", exact: false, ids: [], expected: ["parent" "child" "grandchild" "other-child" "retained" "nested"]}
    {name: "exact", exact: true, ids: [], expected: ["parent" "child" "grandchild" "other-child" "retained"]}
    {name: "one parent", exact: false, ids: ["parent"], expected: ["parent" "child" "grandchild" "other-child"]}
    {name: "a child outside scope", exact: false, ids: ["child"], expected: []}
    {name: "retained peer", exact: false, ids: ["retained"], expected: ["retained"]}
    {name: "a similarly named sibling", exact: false, ids: ["sibling"], expected: []}
  ]

  for case in $cases {
    let selected = (
      select-sessions $rows "/work/app" --exact=$case.exact --session-ids $case.ids
    )

    assert equal ($selected | get -o id) $case.expected $case.name
  }

  let selected_child = (select-sessions $rows "/other" --session-ids ["child"])

  assert equal ($selected_child | get id) ["child" "grandchild"]
}

def "test records without session ids cannot select unrelated roots" [] {
  let rows = [
    {id: null, cwd: "/work/app", parent: null}
    {id: "", cwd: "/work/app", parent: null}
    {id: 7, cwd: "/work/app", parent: null}
    {id: "retained", cwd: "/work/other", parent: null}
  ]

  let selected = (select-sessions $rows "/work/app" --exact)

  assert equal $selected []
}

def "test exact root selection leaves absolute child projects unselected" [] {
  let rows = [
    {id: "root", cwd: "/", parent: null}
    {id: "child", cwd: "/work/app", parent: null}
    {id: "relative", cwd: "work/app", parent: null}
  ]
  let cases = [
    {exact: false, expected: ["root" "child"]}
    {exact: true, expected: ["root"]}
  ]

  for case in $cases {
    let selected = (select-sessions $rows "/" --exact=$case.exact)

    assert equal ($selected | get id) $case.expected
  }
}
