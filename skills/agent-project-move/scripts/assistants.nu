# ==================================================================================================
# Agent Project Move: Assistants
# ==================================================================================================
# Per-assistant dispatch and shared argument parsing.
# ==================================================================================================

use ./stores/claude.nu
use ./stores/codex.nu
use ./stores/omp.nu

const ASSISTANTS = ["claude" "codex" "omp"]
export const ALL_ASSISTANTS = ($ASSISTANTS | str join ",")

export def parse-assistants [value: string]: nothing -> list<string> {
  let names = (
    $value
    | split row ","
    | str trim
    | where {|name| $name != "" }
    | uniq
  )
  if ($names | is-empty) {
    error make --unspanned {
      msg: "No assistant selected"
      help: $"Pass a comma-separated list such as ($ASSISTANTS | str join ',')."
    }
  }

  let unknown = ($names | where {|name| $name not-in $ASSISTANTS })
  if ($unknown | is-not-empty) {
    error make --unspanned {
      msg: $"Unknown assistant: ($unknown | str join ', ')"
      help: $"Choose from ($ASSISTANTS | str join ', ')."
    }
  }
  $names
}

export def scan-all [selected: list<string>]: nothing -> list<record> {
  $selected
  | each {|assistant|
    match $assistant {
      "claude" => { claude scan }
      "codex" => { codex scan }
      "omp" => { omp scan }
    }
  }
  | flatten
}

export def plan-move [
  selected: list<string>
  old: string
  new: string
  --exact
  --session-ids: list<string> = []
]: nothing -> list<record> {
  $selected
  | each {|assistant|
    match $assistant {
      "claude" => { claude plan-move $old $new --exact=$exact --session-ids $session_ids }
      "codex" => { codex plan-move $old $new --exact=$exact --session-ids $session_ids }
      "omp" => { omp plan-move $old $new --exact=$exact --session-ids $session_ids }
    }
  }
  | flatten
}

export def assistant-export-bundle [
  assistant: string
  old: string
  --exact
  --session-ids: list<string> = []
]: nothing -> record {
  match $assistant {
    "claude" => { claude export-bundle $old --exact=$exact --session-ids $session_ids }
    "codex" => { codex export-bundle $old --exact=$exact --session-ids $session_ids }
    "omp" => { omp export-bundle $old --exact=$exact --session-ids $session_ids }
  }
}

export def assistant-plan-import [
  assistant: string
  bundle: record
  --target: string
]: nothing -> list<record> {
  match $assistant {
    "claude" => { claude plan-import $bundle --target $target }
    "codex" => { codex plan-import $bundle --target $target }
    "omp" => { omp plan-import $bundle --target $target }
  }
}

export def plan-retire [
  selected: list<string>
  path: string
  --exact
  --session-ids: list<string> = []
]: nothing -> list<record> {
  $selected
  | each {|assistant|
    match $assistant {
      "claude" => { claude plan-retire $path --exact=$exact --session-ids $session_ids }
      "codex" => { codex plan-retire $path --exact=$exact --session-ids $session_ids }
      "omp" => { omp plan-retire $path --exact=$exact --session-ids $session_ids }
    }
  }
  | flatten
}
