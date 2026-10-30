# ==================================================================================================
# Agent Project Move: Output
# ==================================================================================================
# Table printing and plural wording for the command's output. A table keeps every column readable
# when stdout is not a terminal, which is how an agent runs the command.
# ==================================================================================================

export def plural [count: int, singular: string, plural: string]: nothing -> string {
  if $count == 1 { $singular } else { $plural }
}

export def print-table []: table -> nothing {
  if (is-terminal --stdout) {
    print ($in | table)
  } else {
    print ($in | table --width 1000)
  }
}
