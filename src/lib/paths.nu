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
    error make --unspanned {
      msg: "Source and destination are the same path"
      help: "Nothing was written."
    }
  }
  if ($old | str lowercase) == ($new | str lowercase) {
    error make --unspanned {
      msg: "A move that changes only letter case is not supported"
      help: $"Go through a temporary name: rename the directory to ($old).tmp, run 'move ($old) ($old).tmp', then rename it to ($new) and run 'move ($old).tmp ($new)'."
    }
  }
  if (path-match $old $new) {
    error make --unspanned {
      msg: $"Destination ($new) is under the source ($old)"
      help: "Choose a destination outside the source tree. Nothing was written."
    }
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

# Whether a path is missing. A path under an unmounted drive root counts as present, so a prune
# does not delete state for a disk that is merely detached.
export def path-missing [path: string]: nothing -> bool {
  if ($path | path exists) { return false }
  let parts = ($path | str replace --regex '^/' '' | split row '/')
  if ($parts | length) < 2 { return true }
  let root = if ($parts | length) >= 4 and ($parts | first 2 | str join "/") == "run/media" {
    "/" + ($parts | take 4 | str join "/")
  } else if ($parts | length) >= 3 and ($parts | first 1 | first) == "media" {
    "/" + ($parts | take 3 | str join "/")
  } else {
    "/" + ($parts | take 2 | str join "/")
  }
  if (
    ($root | str starts-with "/Volumes/")
    or ($root | str starts-with "/mnt/")
    or ($root | str starts-with "/media/")
    or ($root | str starts-with "/run/media/")
  ) {
    $root | path exists
  } else {
    true
  }
}
