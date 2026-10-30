# ==================================================================================================
# Agent Project Move: Paths
# ==================================================================================================
# Path parsing, normalization, matching, and mapping, and the file walks over recorded state.
# ==================================================================================================

export def valid-path [path: any]: nothing -> bool {
  ($path | describe) == "string" and ($path | str starts-with "/")
}

export def normalize-path [
  path: string
  --physical # Resolve symlinks, so state records the spelling the working directory reports
]: nothing -> string {
  let expanded = if $physical { $path | path expand } else { $path | path expand --no-symlink }
  let trimmed = ($expanded | str replace --regex '/+$' '')
  if $trimmed == "" { "/" } else { $trimmed }
}

export def check-destination [old: string, new: string]: nothing -> nothing {
  if $old == $new {
    error make {msg: "Source and destination are the same path"}
  }
  if ($old | str lowercase) == ($new | str lowercase) {
    error make {msg: (
      "Case-only moves are not supported. "
      + "Rename the directory and move its state to a different path."
    )}
  }
  if (path-match $old $new) {
    error make {msg: $"Destination ($new) is under the source ($old)"}
  }
}

export def path-match [base: string, path: any]: nothing -> bool {
  if ($path | describe) != "string" { return false }
  $path == $base or ($path | str starts-with ($base + "/"))
}

export def path-map [old: string, new: string, path: string]: nothing -> string {
  if $path == $old { $new } else { $new + ($path | str substring ($old | str length)..) }
}

export def match-any [bases: list<string>, path: any]: nothing -> bool {
  $bases | any {|base| path-match $base $path }
}

export def parse-paths [value: string]: nothing -> list<string> {
  $value | split row "," | each {|path| $path | str trim } | where {|path| $path != "" }
}

export def files-under [dir: string]: nothing -> list<string> {
  if not ($dir | path exists) { return [] }
  if ($dir | path type) != "dir" { return [$dir] }
  (^find $dir -type f | lines | sort)
}

export def path-missing [path: string]: nothing -> bool {
  if ($path | path exists) { return false }
  let parts = ($path | str replace --regex '^/' '' | split row '/')
  if ($parts | length) < 2 { return true }
  let root = "/" + ($parts | take 2 | str join "/")
  if ($root | str starts-with "/Volumes/") or ($root | str starts-with "/mnt/") {
    $root | path exists
  } else {
    true
  }
}
