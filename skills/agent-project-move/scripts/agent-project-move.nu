#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move
# ==================================================================================================
# Repairs project paths and transfers or retires Claude Code, Codex, and OMP session state.
# Paths match case-sensitively. Run with --help for usage.
# ==================================================================================================

use ./lib/actions.nu [apply-all]
use ./lib/bundle.nu [read-bundle require-empty-directory write-bundle]
use ./lib/output.nu [plural print-table]
use ./lib/paths.nu [
  check-destination
  normalize-path
]
use ./assistants.nu [
  ALL_ASSISTANTS
  assistant-export-bundle
  assistant-plan-import
  parse-assistants
  plan-move
  plan-retire
  scan-all
]

def has-gnu-stat []: nothing -> bool {
  let stat = (which stat | first | get -o path)
  if $stat == null { return false }
  # The Nix wrapper prepends the coreutils bin directory.
  if $stat =~ '^/nix/store/[^/]+-coreutils-[^/]+/bin/stat$' { return true }
  (^stat --version | complete).stdout | str starts-with "stat (GNU coreutils)"
}

def homebrew-gnubin []: nothing -> any {
  let standard = (
    [
      "/opt/homebrew/opt/coreutils/libexec/gnubin"
      "/usr/local/opt/coreutils/libexec/gnubin"
    ]
    | where {|dir| $dir | path exists }
    | first
  )
  if $standard != null { return $standard }
  if (which brew | is-empty) { return null }

  let prefix = (^brew --prefix coreutils | complete)
  if $prefix.exit_code == 0 {
    $prefix.stdout | str trim | path join "libexec/gnubin"
  }
}

# Homebrew keeps the unprefixed GNU tools in gnubin.
if $nu.os-info.name == "macos" and (not (has-gnu-stat)) {
  let gnubin = (homebrew-gnubin)
  if $gnubin != null and ($gnubin | path exists) {
    $env.PATH = ($env.PATH | prepend $gnubin)
  }
}

# Move, export, import, and retire assistant state recorded for project paths.
#
# Move, import, and retire preview changes by default and write only with --apply.
# Applied changes create a backup under `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/`,
# unless `--no-backup` is given.
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

# Move state under <old> to <new>. Prints the plan, and writes only with --apply.
@example "Preview a move, then apply it" {
  agent-project-move move ~/src/app ~/work/app
  agent-project-move move ~/src/app ~/work/app --apply
}
def "main move" [
  old: string # Recorded project path, or a parent of it
  new: string # New project path
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to move
  --exact # Select exact-cwd sessions and their descendants
  --session-ids: string # Session IDs under <old>, with their descendants
  --apply # Write the planned changes
  --no-backup # Skip creating recovery backups
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let ids = (selection-ids $exact $session_ids)
  # `<old>` keeps the given spelling, because matching is an exact case-sensitive string test.
  # `<new>` is canonicalized, so state records the spelling the working directory reports.
  let old = (normalize-path $old)
  let new = (normalize-path $new --physical)

  check-destination $old $new
  if not ($new | path exists) {
    print $"($new) does not exist. Move the directory first so sessions can resume there."
  }
  let actions = (plan-move $selected $old $new --exact=$exact --session-ids $ids)
  apply-all $actions --apply=$apply --no-backup=$no_backup
}

# Write the state recorded for <path> as a bundle directory, unchanged.
@example "Export a project's state to a bundle" {
  agent-project-move export ~/src/app ~/agent-project-move-bundle
}
def "main export" [
  path: string # Project path to export, or a parent of it
  dir: string # New or empty bundle directory, with one subdirectory per assistant
  --assistant (-a): string = $ALL_ASSISTANTS # Comma-separated assistants to export
  --exact # Select exact-cwd sessions and their descendants
  --session-ids: string # Session IDs under the path, with their descendants
]: nothing -> nothing {
  let selected = (parse-assistants $assistant)
  let old = (normalize-path $path)
  let ids = (selection-ids $exact $session_ids)
  require-empty-directory $dir

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
    let files_label = $"($count.files) (plural $count.files 'file' 'files')"
    let rows_label = $"($count.rows) (plural $count.rows 'row' 'rows')"
    print $"($count.assistant): ($files_label), ($rows_label)"
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
      help: (
        "Pass the directory you gave to 'export'."
        + $" It holds one subdirectory per assistant, such as ($dir)/claude/entries.json."
      )
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
