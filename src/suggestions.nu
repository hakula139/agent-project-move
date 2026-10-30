# ==================================================================================================
# Agent Project Move: Suggestions
# ==================================================================================================
# Repository roots and the suggested destination for a missing project path.
# ==================================================================================================

use ./lib/paths.nu [match-any path-match path-missing valid-path]

def is-worktree-path [path: string]: nothing -> bool {
  let claude = ($path | str contains "/.claude/worktrees/")
  let codex = ($path | str contains "/.codex/worktrees/")
  let sibling = ($path | split row "/" | any {|part| $part | str ends-with "__worktrees" })
  $claude or $codex or $sibling
}

# A worktree checkout is never a move target because its state belongs to the checkout's repository.
def repo-target [root: string, home: string, temp_roots: list<string>]: nothing -> bool {
  ($root != $home) and (not (match-any $temp_roots $root)) and (not (is-worktree-path $root))
}

def unique-repo [
  repo_roots: list<string>
  name: string
  home: string
  temp_roots: list<string>
]: nothing -> string {
  let candidates = (
    $repo_roots
    | where {|root| (($root | path basename) == $name) and (repo-target $root $home $temp_roots) }
  )
  if ($candidates | length) == 1 { $candidates | get 0 } else { "" }
}

# Suggest where state for a missing path belongs, from the path and existing repo roots.
export def suggested-move [
  path: string
  repo_roots: list<string>
  home: string
  temp_roots: list<string>
]: nothing -> string {
  if not (valid-path $path) { return "" }

  let claude = ($path | parse --regex '^(?P<repo>.+)/\.claude/worktrees/[^/]+(?:/.*)?$')
  if ($claude | is-not-empty) {
    let repo = ($claude | get 0.repo)
    if ($repo in $repo_roots) and (repo-target $repo $home $temp_roots) { return $repo }
  }

  let sibling = ($path | parse --regex '^(?P<repo>.+?)__worktrees/[^/]+(?:/.*)?$')
  if ($sibling | is-not-empty) {
    let repo = ($sibling | get 0.repo)
    if ($repo in $repo_roots) and (repo-target $repo $home $temp_roots) { return $repo }
    if (path-missing $repo) {
      let found = (unique-repo $repo_roots ($repo | path basename) $home $temp_roots)
      if $found != "" { return $found }
    }
  }

  if ($home != "") and ($path | str starts-with ($home + "/.codex/worktrees/")) {
    let parts = ($path | str replace ($home + "/.codex/worktrees/") "" | split row "/")
    if ($parts | length) >= 2 {
      let name = ($parts | get 1)
      let found = (unique-repo $repo_roots $name $home $temp_roots)
      if $found != "" { return $found }
    }
    return ""
  }

  let ancestors = (
    $repo_roots
    | where {|root| (path-match $root $path) and (repo-target $root $home $temp_roots) }
    | sort-by {|root| $root | str length }
  )
  if ($ancestors | is-empty) { return "" }
  $ancestors | last
}

def repo-ancestors [path: string]: nothing -> list<string> {
  mut roots = []
  mut current = ($path | path dirname)
  while $current != "/" and $current != "" {
    if ($current | path join ".git" | path exists) {
      $roots = ($roots | append $current)
    }
    $current = ($current | path dirname)
  }
  $roots
}

def repo-roots-for [
  paths: list<string>
  home: string
  temp_roots: list<string>
]: nothing -> list<string> {
  let recorded = (
    $paths
    | where {|path| (not (path-missing $path)) and ($path | path join .git | path exists) }
  )
  let ancestors = (
    $paths
    | where {|path| path-missing $path }
    | each {|path| repo-ancestors $path }
    | flatten
  )

  $recorded
  | append $ancestors
  | uniq
  | where {|root| ($root != $home) and (not (match-any $temp_roots $root)) }
  | sort
}

export def scan-suggestions [
  rows: list<record>
  home: string
  temp_roots: list<string>
]: nothing -> list<record> {
  let paths = ($rows | get -o path | where {|path| valid-path $path } | uniq)
  let roots = (repo-roots-for $paths $home $temp_roots)

  $paths
  | where {|path| path-missing $path }
  | each {|path|
    let suggested = if $home == "" { "" } else { suggested-move $path $roots $home $temp_roots }
    {path: $path, suggested: $suggested}
  }
}
