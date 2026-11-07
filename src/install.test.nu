#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Install Tests
# ==================================================================================================

use std/assert

use ./install.nu [install-line]

def "test setup picks the install line for the platform" [] {
  for case in [
    {
      os: "macos"
      tools: [ripgrep sqlite zstd coreutils]
      expected: "brew install ripgrep sqlite zstd coreutils"
    }
    { os: "debian", tools: [sqlite coreutils], expected: "sudo apt install sqlite3 coreutils" }
    {
      os: "linux"
      tools: [ripgrep zstd]
      expected: "Install ripgrep, zstd with your package manager."
    }
  ] {
    assert equal (install-line $case.os $case.tools) $case.expected $case.os
  }
}
