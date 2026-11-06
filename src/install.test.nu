#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Install Tests
# ==================================================================================================

use std/assert

use ./install.nu [install-line skill-links]

def "test setup links the skill for the agent directories" [] {
  with-env { HOME: "/home/u" } {
    assert equal (skill-links) [
      "/home/u/.agents/skills/agent-project-move"
      "/home/u/.claude/skills/agent-project-move"
    ]
  }
}

def "test setup picks the install line for the platform" [] {
  for case in [
    {
      os: "macos"
      tools: [ripgrep sqlite zstd coreutils]
      expected: "brew install ripgrep sqlite zstd coreutils"
    }
    { os: "arch", tools: [nushell zstd], expected: "sudo pacman -S --needed nushell zstd" }
    { os: "debian", tools: [sqlite coreutils], expected: "sudo apt install sqlite3 coreutils" }
    { os: "fedora", tools: [ripgrep], expected: "sudo dnf install ripgrep" }
    {
      os: "linux"
      tools: [ripgrep zstd]
      expected: "Install ripgrep, zstd with your package manager."
    }
  ] {
    assert equal (install-line $case.os $case.tools) $case.expected $case.os
  }
}
