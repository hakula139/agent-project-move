#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Selection Tests
# ==================================================================================================

use std/assert

use ./selection.nu *

def "test selection scopes matches and carries complete parent trees" [] {
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

  assert equal ($selected_child | get id) ["parent" "child" "grandchild" "other-child"]
}
