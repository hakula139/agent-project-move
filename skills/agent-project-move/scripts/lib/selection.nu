# ==================================================================================================
# Agent Project Move: Session Selection
# ==================================================================================================

use ./paths.nu [path-match]

export def select-sessions [
  rows: list<record>
  path: string
  --exact
  --session-ids: list<string> = []
]: nothing -> list<record> {
  if $exact and ($session_ids | is-not-empty) {
    error make --unspanned {msg: "--exact and --session-ids are mutually exclusive"}
  }
  mut ids = (
    $rows
    | where {|row|
      let matches = if $exact { $row.cwd == $path } else { path-match $path $row.cwd }
      $matches and (($session_ids | is-empty) or ($row.id in $session_ids))
    }
    | get -o id
    | uniq
  )
  loop {
    let descendants = (
      $rows
      | where {|row| ($row | get -o parent) in $ids }
      | get -o id
    )
    let parents = ($rows | where {|row| $row.id in $ids } | get -o parent | compact)
    let expanded = ($ids ++ $descendants ++ $parents | uniq)
    if ($expanded | length) == ($ids | length) { break }
    $ids = $expanded
  }
  $rows | where {|row| $row.id in $ids }
}
