#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Claude Code Tests
# ==================================================================================================

use std/assert

use ./claude.nu *

const SCRIPT_DIR = path self .

const FIXTURES = ($SCRIPT_DIR | path join fixtures claude-encoding)

def "test Claude encodes project directory names" [] {
  for case in (glob ($FIXTURES | path join "*/case.nuon") | sort) {
    let expected = (open $case)

    let name = ($case | path dirname | path basename)
    assert equal (encode-path $expected.path) $expected.encoded $name
  }
}

def "test a config move rewrites github repository paths" [] {
  let config = {
    projects: {"/work/app": {hasTrustDialogAccepted: true}, "/work/other": {}}
    githubRepoPaths: {"me/app": ["/work/app" "/work/app/sub"], "me/other": ["/work/other"]}
  }

  let moved = (move-config $config "/work/app" "/work/new")

  assert equal ($moved.projects | columns | sort) ["/work/new" "/work/other"]
  assert equal $moved.githubRepoPaths {
    "me/app": ["/work/new" "/work/new/sub"]
    "me/other": ["/work/other"]
  }
}

def "test a config prune drops missing projects and emptied repos" [] {
  let config = {
    projects: {"/work/gone": {}, "/work/live": {}}
    githubRepoPaths: {"me/gone": ["/work/gone"], "me/live": ["/work/live"]}
  }

  let pruned = (prune-config $config ["/work/gone"])

  assert equal ($pruned.projects | columns) ["/work/live"]
  assert equal $pruned.githubRepoPaths {"me/live": ["/work/live"]}
}
