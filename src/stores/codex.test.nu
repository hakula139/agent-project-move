#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Codex Tests
# ==================================================================================================

use std/assert

use ./codex.nu *

def "test a moved trust block follows its path" [] {
  let config = ([
    '[projects."/work/app"]'
    'trust_level = "trusted"'
    '[projects."/work/app/sub"]'
    'trust_level = "trusted"'
    '[projects."/work/other"]'
    'trust_level = "trusted"'
  ] | str join "\n")

  let cases = [
    {
      name: "a parent and its child"
      old: "/work/app"
      new: "/work/new"
      expected: [
        '[projects."/work/other"]'
        'trust_level = "trusted"'
        '[projects."/work/new"]'
        'trust_level = "trusted"'
        '[projects."/work/new/sub"]'
        'trust_level = "trusted"'
      ]
    }
    {
      name: "a child alone"
      old: "/work/app/sub"
      new: "/work/new/sub"
      expected: [
        '[projects."/work/app"]'
        'trust_level = "trusted"'
        '[projects."/work/other"]'
        'trust_level = "trusted"'
        '[projects."/work/new/sub"]'
        'trust_level = "trusted"'
      ]
    }
    {
      name: "a destination that already trusts the path"
      old: "/work/app"
      new: "/work/other"
      expected: [
        '[projects."/work/other"]'
        'trust_level = "trusted"'
        '[projects."/work/other/sub"]'
        'trust_level = "trusted"'
      ]
    }
  ]

  for case in $cases {
    let expected = ($case.expected | str join "\n") + "\n"
    assert equal (move-trust $config $case.old $case.new) $expected $case.name
  }
}
