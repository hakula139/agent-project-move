# ==================================================================================================
# Agent Project Move: Assistants
# ==================================================================================================
# The per-assistant dispatch, the shared argument parser, and the scan, move, and prune
# orchestration over every store.
# ==================================================================================================

use ./lib/paths.nu [match-any path-missing valid-path]
use ./stores/claude.nu
use ./stores/codex.nu
use ./stores/omp.nu
use ./stores/opencode.nu

export const ASSISTANTS = [claude codex opencode omp]
export const ALL_ASSISTANTS = ($ASSISTANTS | str join ",")

export def parse-assistants [value: string]: nothing -> list<string> {
  let names = (
    $value
    | str replace --all --regex '[\[\]]' ''
    | split row --regex '[\s,]+'
    | where {|name| $name != "" }
    | uniq
  )
  if ($names | is-empty) { return $ASSISTANTS }

  let unknown = ($names | where {|name| $name not-in $ASSISTANTS })
  if ($unknown | is-not-empty) {
    error make {msg: $"Unknown assistant: ($unknown | str join ', '). Choose from ($ASSISTANTS | str join ', ')."}
  }
  $names
}

def assistant-scan [assistant: string]: nothing -> list<record> {
  match $assistant {
    'claude' => { claude scan }
    'codex' => { codex scan }
    'opencode' => { opencode scan }
    'omp' => { omp scan }
  }
}

def assistant-recorded-paths [assistant: string]: nothing -> list<string> {
  match $assistant {
    'claude' => { claude recorded-paths }
    'codex' => { codex recorded-paths }
    'opencode' => { opencode recorded-paths }
    'omp' => { omp recorded-paths }
  }
}

def assistant-plan-move [
  assistant: string
  old: string
  new: string
]: nothing -> list<record> {
  match $assistant {
    'claude' => { claude plan-move $old $new }
    'codex' => { codex plan-move $old $new }
    'opencode' => { opencode plan-move $old $new }
    'omp' => { omp plan-move $old $new }
  }
}

def assistant-plan-prune [
  assistant: string
  paths: list<string>
]: nothing -> list<record> {
  match $assistant {
    'claude' => { claude plan-prune $paths }
    'codex' => { codex plan-prune $paths }
    'opencode' => { opencode plan-prune $paths }
    'omp' => { omp plan-prune $paths }
  }
}

export def assistant-export-bundle [
  assistant: string
  old: string
]: nothing -> record {
  match $assistant {
    'claude' => { claude export-bundle $old }
    'codex' => { codex export-bundle $old }
    'opencode' => { opencode export-bundle $old }
    'omp' => { omp export-bundle $old }
  }
}

export def assistant-plan-import [
  assistant: string
  bundle: record
]: nothing -> list<record> {
  match $assistant {
    'claude' => { claude plan-import $bundle }
    'codex' => { codex plan-import $bundle }
    'opencode' => { opencode plan-import $bundle }
    'omp' => { omp plan-import $bundle }
  }
}

export def scan-all [selected: list<string>]: nothing -> list<record> {
  $selected | each {|assistant| assistant-scan $assistant } | flatten
}

export def plan-move [
  selected: list<string>
  old: string
  new: string
]: nothing -> list<record> {
  $selected | each {|assistant| assistant-plan-move $assistant $old $new } | flatten
}

export def prune-missing-paths [selected: list<string>]: nothing -> list<string> {
  let rows = (scan-all $selected)
  let recorded = ($selected | each {|assistant| assistant-recorded-paths $assistant } | flatten)
  $rows
  | get -o path
  | where {|path| valid-path $path }
  | append $recorded
  | uniq
  | where {|path| path-missing $path }
}

export def plan-prune [
  selected: list<string>
  keep: list<string> = []
  --paths: oneof<list<string>, nothing> = null
]: nothing -> list<record> {
  let missing = if $paths == null { prune-missing-paths $selected } else { $paths }
  let filtered = ($missing | where {|path| not (match-any $keep $path) })
  if ($filtered | is-empty) { return [] }
  $selected | each {|assistant| assistant-plan-prune $assistant $filtered } | flatten
}
