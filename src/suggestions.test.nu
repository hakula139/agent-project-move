#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Suggestions Tests
# ==================================================================================================

use std/assert

use ./suggestions.nu *

def "test missing paths suggest their existing repository" [] {
  let temp = ["/tmp" "/private/tmp" "/var/folders/t/T"]
  let app = "/work/app"
  let repo_app = "/home/me/src/app"
  let codex_worktree = "/home/me/.codex/worktrees/abc/app"
  let cases = [
    {
      name: "a sibling worktree"
      path: "/work/app__worktrees/feat-x"
      roots: [$app]
      expected: $app
    }
    {
      name: "a nested sibling worktree path"
      path: "/work/app__worktrees/feat-x/src"
      roots: [$app]
      expected: $app
    }
    {
      name: "a sibling worktree of an unknown repo"
      path: "/work/gone__worktrees/feat-x"
      roots: [$app]
      expected: ""
    }
    {
      name: "a Codex worktree matching one repo"
      path: $codex_worktree
      roots: [$repo_app "/home/me/work/other"]
      expected: $repo_app
    }
    {
      name: "a Codex worktree ignoring worktree checkouts"
      path: "/home/me/.codex/worktrees/def/app"
      roots: [$repo_app "/home/me/.codex/worktrees/abc/app"]
      expected: $repo_app
    }
    {
      name: "a nested Codex worktree path"
      path: "/home/me/.codex/worktrees/abc/app/src"
      roots: [$repo_app]
      expected: $repo_app
    }
    {
      name: "a Codex worktree matching two repos"
      path: $codex_worktree
      roots: [$repo_app "/home/me/work/app"]
      expected: ""
    }
    {
      name: "a Codex worktree matching no repo"
      path: $codex_worktree
      roots: ["/home/me/repos/other"]
      expected: ""
    }
    {
      name: "a Codex worktree under another home"
      path: "/Users/me/.codex/worktrees/abc/app"
      roots: [$repo_app]
      expected: ""
    }
    {
      name: "a subpath of a repo"
      path: "/work/app/src/gone"
      roots: [$app]
      expected: $app
    }
    {
      name: "a subpath of the nearest nested repo"
      path: "/work/app/sub/src/gone"
      roots: [$app "/work/app/sub"]
      expected: "/work/app/sub"
    }
    {
      name: "a missing repo"
      path: "/work/gone"
      roots: [$app]
      expected: ""
    }
    {
      name: "a path under a temp root"
      path: "/tmp/app/.claude/worktrees/feat-x"
      roots: ["/tmp/app"]
      expected: ""
    }
    {
      name: "a repo at home"
      path: "/home/me/src/gone"
      roots: ["/home/me"]
      expected: ""
    }
    {
      name: "a repo below home"
      path: "/home/me/src/gone"
      roots: ["/home/me" "/home/me/src"]
      expected: "/home/me/src"
    }
    {
      name: "a worktree marker without a name"
      path: "/work/app__worktrees"
      roots: [$app]
      expected: ""
    }
    {
      name: "a sibling worktree of a repo that moved"
      path: "/home/me/src/my-app__worktrees/x"
      roots: ["/home/me/work/my-app"]
      expected: "/home/me/work/my-app"
    }
    {
      name: "a sibling worktree with two matching repos"
      path: "/home/me/src/app__worktrees/x"
      roots: ["/home/me/work/app" "/home/me/other/app"]
      expected: ""
    }
  ]

  for case in $cases {
    assert equal (suggested-move $case.path $case.roots "/home/me" $temp) $case.expected $case.name
  }
}
