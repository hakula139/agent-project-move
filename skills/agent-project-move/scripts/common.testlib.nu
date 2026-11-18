#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Shared Test Helpers
# ==================================================================================================

const SCRIPT = path self "agent-project-move.nu"

export def fixture-env [root: string]: nothing -> record {
  {
    CLAUDE_CONFIG_DIR: ($root | path join "claude")
    CODEX_HOME: ($root | path join "codex")
    PI_CODING_AGENT_DIR: ($root | path join "omp")
    TZ: "UTC"
    XDG_STATE_HOME: ($root | path join "state")
  }
}

export def write-jsonl [file: string, rows: list<record>] {
  mkdir ($file | path dirname)
  $rows
  | each {|row| $row | to json --raw }
  | str join "\n"
  | save $file
}

export def --wrapped run-cli [...args: string]: nothing -> record {
  ^$nu.current-exe $SCRIPT ...$args | complete
}
