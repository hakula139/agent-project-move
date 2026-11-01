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
use ./lib/output.nu [plural print-table]
use ./lib/paths.nu [
  check-destination
  match-any
  normalize-path
  parse-paths
]
use ./assistants.nu [
  ALL_ASSISTANTS
  all-recorded-paths
  assistant-export-bundle
  assistant-plan-import
  parse-assistants
  plan-move
  plan-prune
  prune-missing-paths
  scan-all
]
use ./install.nu [setup]
use ./suggestions.nu [scan-suggestions]

# Move, export, import, and prune assistant state recorded for project paths.
#
# Every plan is a dry run, and `--apply` writes it after a backup under
# `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/`.
def main [...rest: string] {
  if ($rest | is-empty) {
    help main
    return
  }
  error make --unspanned {
    msg: $"Unknown subcommand ($rest | first)"
    help: "Run 'agent-project-move --help' to list the commands."
  }
}

# One-time plain-install setup: check the tools, then link the command and the skill.
@example "Set up a plain install" { agent-project-move setup }
def "main setup" []: nothing -> nothing {
  setup
}

# List each recorded project path with its sessions, last use, existence, and suggested target.
@example "List every recorded project path" { agent-project-move scan }
def "main scan" [
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to scan
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let home = $env.HOME
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
      $row
      | upsert suggested ($hits | get -o 0.suggested | default "")
      | upsert exists (if ($row.path | path exists) { "yes" } else { "missing" })
    }
    | sort-by assistant path
  )

  if ($rows | is-empty) {
    print "No recorded project paths."
  } else {
    $rows | select assistant path exists sessions last_used suggested | print-table
  }
}

# Move state under <old> to <new>. Prints the plan, and writes only with --apply.
@example "Preview a move, then apply it" {
  agent-project-move move ~/src/app ~/work/app
  agent-project-move move ~/src/app ~/work/app --apply
}
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
  if not ($new | path exists) {
    print $"($new) does not exist. Move the directory first, or a later prune deletes this state."
  }
  let actions = (plan-move $selected $old $new)
  if ($actions | is-empty) {
    let recorded = (all-recorded-paths $selected)
    if not ($recorded | any {|candidate| match-any [$old] $candidate }) {
      print $"Nothing is recorded under ($old)"
    }
  }
  apply-all $actions --apply=$apply
}

# Delete state recorded for missing project paths. Prints the plan, and writes only with --apply.
@example "Preview a prune, then apply it" {
  agent-project-move prune
  agent-project-move prune --apply
}
def "main prune" [
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to prune
  --keep (-k): string = "" # Comma-separated path prefixes to leave alone
  --apply # Write the planned changes
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let keep = (parse-paths $keep)
  let missing = (prune-missing-paths $selected)
  let excluded = ($missing | where {|path| match-any $keep $path })
  let targets = ($missing | where {|path| not (match-any $keep $path) })
  if ($excluded | is-not-empty) {
    print "Excluded by --keep:"
    $excluded | wrap path | print-table
  }
  if not $apply and ($targets | is-not-empty) {
    let rows = (scan-all $selected | where {|row| $row.path in $targets })
    let count = ($targets | length)
    print $"Prune deletes state for ($count) (plural $count 'missing path' 'missing paths'):"
    $rows | select assistant path sessions last_used | print-table
  }

  apply-all (plan-prune $selected $targets) --apply=$apply
}

# Write the state recorded for <path> as a bundle directory, unchanged.
@example "Export a project's state to a bundle" {
  agent-project-move export ~/src/app ~/agent-project-move-bundle
}
def "main export" [
  path: string # Project path to export, or a parent of it
  dir: string # Directory receiving one subdirectory per assistant
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to export
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let old = (normalize-path $path)

  let bundles = ($selected | each {|assistant| assistant-export-bundle $assistant $old })
  let counts = (
    $bundles
    | each {|bundle|
      let files = ($bundle.files | length)
      let rows = ($bundle.tables | each {|table| $table.rows | length } | append 0 | math sum)
      {assistant: $bundle.assistant, files: $files, rows: $rows}
    }
  )
  for count in $counts {
    print $"($count.assistant): ($count.files) (plural $count.files 'file' 'files'), ($count.rows) (plural $count.rows 'row' 'rows')"
  }
  let carried = (
    $counts
    | where {|count| $count.files > 0 or $count.rows > 0 }
    | get assistant
  )
  if ($carried | is-empty) {
    error make --unspanned {
      msg: $"Nothing is recorded under ($old)"
      help: "Run 'agent-project-move scan' to list recorded paths."
    }
  }

  mkdir $dir
  for bundle in ($bundles | where {|bundle| $bundle.assistant in $carried }) {
    write-bundle $dir $bundle
  }
  print $"Exported to ($dir)"
}

# Merge a bundle directory into local state. Prints the plan, and writes only with --apply.
@example "Import a bundle, previewing the plan first" {
  agent-project-move import ~/agent-project-move-bundle
  agent-project-move import ~/agent-project-move-bundle --apply
}
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
    error make --unspanned {
      msg: $"No bundle found under ($dir) for ($selected | str join ', ')"
      help: $"Pass the directory you gave to 'export'. It holds one subdirectory per assistant, such as ($dir)/claude/entries.json."
    }
  }

  let plans = (
    $bundles
    | each {|bundle|
      {assistant: $bundle.assistant, actions: (assistant-plan-import $bundle.assistant $bundle)}
    }
  )
  for plan in $plans {
    if ($plan.actions | is-empty) {
      print $"Skipped: ($plan.assistant) already holds these sessions."
    }
  }
  apply-all ($plans | get actions | flatten) --apply=$apply
}
