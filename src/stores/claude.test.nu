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
