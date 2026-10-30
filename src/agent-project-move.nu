#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move
# ==================================================================================================
# Moves, exports, imports, and prunes Claude Code, Codex, OpenCode, and OMP state after a project
# directory moves. Paths match by exact string prefix, case-sensitively. A move rewrites state in
# place, while export and import transfer state between hosts. Run with --help for usage.
# ==================================================================================================

use ./lib/actions.nu [apply-all]
use ./lib/bundle.nu [read-bundle write-bundle]
use ./lib/paths.nu [
  check-destination
  match-any
  normalize-path
  parse-paths
]
use ./assistants.nu [
  ALL_ASSISTANTS
  assistant-export-bundle
  assistant-plan-import
  parse-assistants
  plan-move
  plan-prune
  prune-missing-paths
  scan-all
]
use ./suggestions.nu [scan-suggestions]

# Move, export, import, and prune assistant state recorded for project paths.
def main [] {
  help main
}

# List every recorded project path with its session count, last use, and suggested move target.
def "main scan" [
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to scan
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let home = ($env.HOME? | default "")
  let temp_roots = (
    ["/tmp" "/private/tmp" ($env.TMPDIR? | default "")]
    | where {|root| $root != "" }
    | uniq
  )

  let rows = (scan-all $selected)
  let suggestions = (scan-suggestions $rows $home $temp_roots)
  let rows = (
    $rows
    | each {|row|
      let hits = ($suggestions | where path == $row.path)
      $row | upsert suggested ($hits | get -o 0.suggested | default "")
    }
    | sort-by assistant path
  )

  if ($rows | is-empty) {
    print "No recorded project paths."
  } else {
    print ($rows | select assistant path sessions last_used suggested | table)
  }
}

# Move state under <old> to <new>. Prints the plan, and writes only with --apply.
def "main move" [
  old: string # Recorded project path, or a parent of it
  new: string # New project path
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to move
  --apply # Write the planned changes
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  # `<old>` keeps the given spelling, because matching is an exact case-sensitive string test.
  # `<new>` is canonicalized, so state records the spelling the working directory reports.
  let old = (normalize-path $old)
  let new = (normalize-path $new --physical)

  check-destination $old $new
  apply-all (plan-move $selected $old $new) --apply=$apply
}

# Delete state recorded for missing project paths. Prints the plan, and writes only with --apply.
def "main prune" [
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to prune
  --keep (-k): string = "" # Comma-separated path prefixes to leave alone
  --apply # Write the planned changes
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let keep = (parse-paths $keep)
  let missing = (prune-missing-paths $selected)
  let excluded = ($missing | where {|path| match-any $keep $path })
  if ($excluded | is-not-empty) {
    print "Excluded by --keep:"
    print ($excluded | table)
  }

  apply-all (plan-prune $selected $keep --paths=$missing) --apply=$apply
}

# Write the state recorded for <old> as a bundle directory, unchanged.
def "main export" [
  old: string # Recorded project path, or a parent of it
  dir: string # Directory receiving one subdirectory per assistant
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to export
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let old = (normalize-path $old)

  mkdir $dir
  for assistant in $selected {
    write-bundle $dir (assistant-export-bundle $assistant $old)
  }
  print $"Exported ($selected | str join ', ') to ($dir)"
}

# Merge a bundle directory into local state. Prints the plan, and writes only with --apply.
def "main import" [
  dir: string # Directory written by export
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to import
  --apply # Write the planned changes
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let bundles = (
    $selected
    | each {|assistant| read-bundle $dir $assistant }
    | compact
  )
  if ($bundles | is-empty) {
    error make {msg: $"No bundle found under ($dir) for ($selected | str join ', ')"}
  }

  let actions = (
    $bundles
    | each {|bundle| assistant-plan-import $bundle.assistant $bundle }
    | flatten
  )
  apply-all $actions --apply=$apply
}
