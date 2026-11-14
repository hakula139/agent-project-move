#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move
# ==================================================================================================
# Repairs project paths and transfers or retires Claude Code, Codex, and OMP session state.
# Paths match case-sensitively. Run with --help for usage.
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
  plan-retire
  prune-missing-paths
  scan-all
]

# The stores call GNU stat, realpath, mv, and cp, which Homebrew keeps unprefixed only in gnubin.
if $nu.os-info.name == "macos" and (which brew | is-not-empty) {
  let prefix = (^brew --prefix coreutils | complete)
  let gnubin = (
    $prefix.stdout
    | str trim
    | path join "libexec/gnubin"
  )
  if $prefix.exit_code == 0 and ($gnubin | path exists) {
    $env.PATH = ($env.PATH | prepend $gnubin)
  }
}

# Move, export, import, prune, and retire assistant state recorded for project paths.
#
# Every plan is a dry run. Applied changes create a backup under
# `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/`, unless `--no-backup` is given.
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

# List each recorded project path with its sessions, last use, and existence.
@example "List every recorded project path" { agent-project-move scan }
def "main scan" [
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to scan
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let rows = (
    scan-all $selected
    | each {|row|
      $row
      | upsert exists (if ($row.path | path exists) { "yes" } else { "missing" })
    }
    | sort-by assistant path
  )

  if ($rows | is-empty) {
    print "No recorded project paths."
  } else {
    $rows
    | select assistant path exists sessions last_used
    | print-table
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
  --no-backup # Skip creating recovery backups
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
  apply-all $actions --apply=$apply --no-backup=$no_backup
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
  --no-backup # Skip creating recovery backups
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let keep = (parse-paths $keep)
  let missing = (prune-missing-paths $selected)
  let excluded = ($missing | where {|path| match-any $keep $path })
  let targets = ($missing | where {|path| not (match-any $keep $path) })
  if ($excluded | is-not-empty) {
    print "Excluded by --keep:"
    $excluded
    | wrap path
    | print-table
  }

  if not $apply and ($targets | is-not-empty) {
    let rows = (scan-all $selected | where {|row| $row.path in $targets })
    let count = ($targets | length)
    print $"Prune deletes state for ($count) (plural $count 'missing path' 'missing paths'):"
    $rows
    | select assistant path sessions last_used
    | print-table
  }

  apply-all (plan-prune $selected $targets) --apply=$apply --no-backup=$no_backup
}

def selection-ids [exact: bool, value: any]: nothing -> list<string> {
  if $exact and $value != null {
    error make --unspanned {msg: "--exact and --session-ids are mutually exclusive"}
  }
  if $value == null { return [] }
  let ids = (
    $value
    | split row ","
    | str trim
    | where {|id| $id != "" }
    | uniq
  )

  if ($ids | is-empty) {
    error make --unspanned {msg: "--session-ids requires at least one session ID"}
  }
  $ids
}

# Write the state recorded for <path> as a bundle directory, unchanged.
@example "Export a project's state to a bundle" {
  agent-project-move export ~/src/app ~/agent-project-move-bundle
}
def "main export" [
  path: string # Project path to export, or a parent of it
  dir: string # Directory receiving one subdirectory per assistant
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to export
  --exact # Select exact-cwd sessions and their descendants
  --session-ids: string # Session IDs under the path, with their descendants
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let old = (normalize-path $path)
  let ids = (selection-ids $exact $session_ids)

  let bundles = ($selected | each {|assistant|
    assistant-export-bundle $assistant $old --exact=$exact --session-ids $ids
  })

  let counts = (
    $bundles
    | each {|bundle|
      let files = ($bundle.files | length)
      let rows = (
        $bundle.tables
        | each {|table| $table.rows | length }
        | append 0
        | math sum
      )
      {
        assistant: $bundle.assistant
        files: $files
        rows: $rows
      }
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

# Retire selected session trees even when their project directory still exists.
def "main retire" [
  path: string # Recorded project path, or a parent of selected sessions
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to retire
  --exact # Select exact-cwd sessions and their descendants
  --session-ids: string # Session IDs under the path, with their descendants
  --apply # Write the planned changes
  --no-backup # Skip creating recovery backups
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let old = (normalize-path $path)
  let ids = (selection-ids $exact $session_ids)
  if not $exact and ($ids | is-empty) {
    error make --unspanned {msg: "retire requires --exact or --session-ids"}
  }

  let actions = (plan-retire $selected $old --exact=$exact --session-ids $ids)
  apply-all $actions --apply=$apply --no-backup=$no_backup
}

# Merge a bundle directory into local state. Prints the plan, and writes only with --apply.
@example "Import a bundle, previewing the plan first" {
  agent-project-move import ~/agent-project-move-bundle
  agent-project-move import ~/agent-project-move-bundle --apply
}
def "main import" [
  dir: string # Directory written by export
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to import
  --target: string # Project path for incoming state, preserving descendant suffixes
  --apply # Write the planned changes
  --no-backup # Skip creating recovery backups
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let bundles = (
    $selected
    | each {|assistant| read-bundle $dir $assistant }
    | compact
  )
  let target = if $target == null {
    null
  } else {
    normalize-path $target --physical
  }
  if ($bundles | is-empty) {
    error make --unspanned {
      msg: $"No bundle found under ($dir) for ($selected | str join ', ')"
      help: $"Pass the directory you gave to 'export'. It holds one subdirectory per assistant, such as ($dir)/claude/entries.json."
    }
  }

  let plans = (
    $bundles
    | each {|bundle|
      {
        assistant: $bundle.assistant
        actions: (assistant-plan-import $bundle.assistant $bundle --target $target)
      }
    }
  )

  for plan in $plans {
    if ($plan.actions | is-empty) {
      print $"Skipped: ($plan.assistant) already holds these sessions."
    }
  }

  let actions = (
    $plans
    | get actions
    | flatten
  )
  apply-all $actions --apply=$apply --no-backup=$no_backup
}
