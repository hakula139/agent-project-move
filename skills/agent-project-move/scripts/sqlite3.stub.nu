#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: SQLite Test Stub
# ==================================================================================================

def --wrapped main [...args: string] {
  let input = (^cat | into binary)
  if ($args | any {|arg| $arg | str starts-with ".backup " }) {
    $"($args | to json --raw)\n" | save --append $env.APM_SQLITE_BACKUP_LOG
  }

  $input | ^$env.APM_SQLITE ...$args
}
