#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Codex Tests
# ==================================================================================================

use std/assert
use std-rfc/str

use ./codex.nu *

def "test a moved trust block follows its path" [] {
  let trusted = (
    '
    [projects."/work/app"]
    trust_level = "trusted"
    [projects."/work/app/sub"]
    trust_level = "trusted"
    [projects."/work/other"]
    trust_level = "trusted"
    '
    | str dedent
  )
  let untrusted = (
    '
    [projects."/work/app"]
    trust_level = "untrusted"
    [projects."/work/other"]
    trust_level = "trusted"
    '
    | str dedent
  )
  let empty = (
    '
    [projects."/work/app"]
    [projects."/work/other"]
    trust_level = "trusted"
    '
    | str dedent
  )
  let commented = (
    '
    [projects."/work/app"]
    trust_level = "trusted"

    # tui notes
    [tui]
    theme = "dark"
    '
    | str dedent
  )
  let noted = (
    '
    # app notes
    [projects."/work/app"]
    trust_level = "trusted"
    [projects."/work/other"]
    trust_level = "trusted"
    '
    | str dedent
  )

  let cases = [
    {
      name: "a parent and its child"
      config: $trusted
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
      config: $trusted
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
      config: $trusted
      old: "/work/app"
      new: "/work/other"
      expected: [
        '[projects."/work/other"]'
        'trust_level = "trusted"'
        '[projects."/work/other/sub"]'
        'trust_level = "trusted"'
      ]
    }
    {
      name: "an untrusted block keeps its body"
      config: $untrusted
      old: "/work/app"
      new: "/work/new"
      expected: [
        '[projects."/work/other"]'
        'trust_level = "trusted"'
        '[projects."/work/new"]'
        'trust_level = "untrusted"'
      ]
    }
    {
      name: "an empty block stays empty"
      config: $empty
      old: "/work/app"
      new: "/work/new"
      expected: [
        '[projects."/work/other"]'
        'trust_level = "trusted"'
        '[projects."/work/new"]'
      ]
    }
    {
      name: "a comment above the next table stays with it"
      config: $commented
      old: "/work/app"
      new: "/work/new"
      expected: [
        '# tui notes'
        '[tui]'
        'theme = "dark"'
        '[projects."/work/new"]'
        'trust_level = "trusted"'
        ''
      ]
    }
    {
      name: "a comment above a moved block travels with it"
      config: $noted
      old: "/work/app"
      new: "/work/new"
      expected: [
        '[projects."/work/other"]'
        'trust_level = "trusted"'
        '# app notes'
        '[projects."/work/new"]'
        'trust_level = "trusted"'
      ]
    }
  ]

  for case in $cases {
    let expected = ($case.expected | str join "\n") + "\n"
    assert equal (move-trust $case.config $case.old $case.new) $expected $case.name
  }
}

def "test a pruned trust block drops its path" [] {
  let trusted = (
    '
    [projects."/work/app"]
    trust_level = "trusted"
    [projects."/work/other"]
    trust_level = "trusted"
    '
    | str dedent
  )
  let expected = ('[projects."/work/other"]' + "\n" + 'trust_level = "trusted"' + "\n")

  assert equal (prune-trust $trusted ["/work/app"]) $expected
}
