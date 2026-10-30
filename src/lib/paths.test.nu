#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Paths Tests
# ==================================================================================================

use std/assert

use ./paths.nu *

def "test absent mount roots keep paths present" [] {
  let name = (random uuid)
  let cases = [
    {name: "an absent volume", path: $"/Volumes/($name)/work/app", missing: false}
    {name: "an absent mount", path: $"/mnt/($name)/app", missing: false}
    {name: "an absent media mount", path: $"/media/($name)/drive/app", missing: false}
    {name: "an absent run-media mount", path: $"/run/media/($name)/drive/app", missing: false}
    {name: "an absent directory", path: $"/home/($name)/app", missing: true}
  ]

  for case in $cases {
    assert equal (path-missing $case.path) $case.missing $case.name
  }
}

def "test a destination must be distinct and outside the source" [] {
  let cases = [
    {
      name: "the same path"
      old: "/work/app"
      new: "/work/app"
      error: "same path"
    }
    {
      name: "a case-only change"
      old: "/work/app"
      new: "/work/App"
      error: "letter case"
    }
    {
      name: "a child of the source"
      old: "/work/app"
      new: "/work/app/sub"
      error: "under the source"
    }
    {
      name: "a sibling"
      old: "/work/app"
      new: "/work/app-bar"
      error: ""
    }
  ]

  for case in $cases {
    let result = (try { check-destination $case.old $case.new; "" } catch {|error| $error.msg })
    if $case.error == "" {
      assert equal $result "" $case.name
    } else {
      assert str contains $result $case.error $case.name
    }
  }
}

def "test a path matches the exact base and its children but not a sibling" [] {
  let cases = [
    {
      name: "the exact base"
      path: "/work/app"
      matches: true
      mapped: "/opt/app"
    }
    {
      name: "a child"
      path: "/work/app/sub"
      matches: true
      mapped: "/opt/app/sub"
    }
    {
      name: "a deeper child"
      path: "/work/app/sub/deeper"
      matches: true
      mapped: "/opt/app/sub/deeper"
    }
    {
      name: "a hyphenated sibling"
      path: "/work/app-bar"
      matches: false
      mapped: ""
    }
    {
      name: "a prefixed sibling"
      path: "/work/application"
      matches: false
      mapped: ""
    }
    {
      name: "the parent"
      path: "/work"
      matches: false
      mapped: ""
    }
    {
      name: "a non-string"
      path: null
      matches: false
      mapped: ""
    }
  ]

  for case in $cases {
    assert equal (path-match "/work/app" $case.path) $case.matches $case.name
    if $case.matches {
      assert equal (path-map "/work/app" "/opt/app" $case.path) $case.mapped $case.name
    }
  }
}
