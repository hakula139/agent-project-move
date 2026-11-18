# ==================================================================================================
# Agent Project Move: Paths
# ==================================================================================================
# Path parsing, normalization, matching, and mapping, and the file walks over recorded state.
# ==================================================================================================

export def home-dir []: nothing -> string {
  $env.HOME? | default --empty $nu.home-dir
}

export def valid-path [path: any]: nothing -> bool {
  ($path | describe) == "string" and ($path | str starts-with "/")
}

export def safe-relative-path [path: any]: nothing -> bool {
  if ($path | describe) != "string" or $path == "" or ($path | str starts-with "/") {
    return false
  }
  $path
  | split row "/"
  | all {|part| $part not-in ["" "." ".."] }
}

export def normalize-path [
  path: string
  --physical # Resolve symlinks, so state records the spelling the working directory reports
]: nothing -> string {
  let expanded = if $physical {
    $path | path expand
  } else {
    $path | path expand --no-symlink
  }
  let trimmed = ($expanded | str replace --regex "/+$" "")
  if $trimmed == "" { "/" } else { $trimmed }
}

export def path-match [base: string, path: any]: nothing -> bool {
  if ($path | describe) != "string" { return false }
  if $base == "/" { return ($path | str starts-with "/") }
  $path == $base or ($path | str starts-with ($base + "/"))
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
      help: (
        $"Rename the directory to ($old).tmp and run 'move ($old) ($old).tmp'."
        + $" Then rename it to ($new) and run 'move ($old).tmp ($new)'."
      )
    }
  }
  if (path-match $old $new) {
    error make --unspanned {
      msg: $"Destination ($new) is under the source ($old)"
      help: "Choose a destination outside the source tree. Nothing was written."
    }
  }
}

export def path-map [old: string, new: string, path: string]: nothing -> string {
  if not (path-match $old $path) { return $path }
  if $path == $old {
    $new
  } else {
    let offset = if $old == "/" {
      0
    } else {
      $old | str length
    }
    let base = ($new | str trim --right --char "/")
    $"($base)($path | str substring $offset..)"
  }
}

export def outermost-paths [paths: list<string>]: nothing -> list<string> {
  let unique = ($paths | uniq)
  $unique
  | where {|path|
    not ($unique | any {|other| $other != $path and (path-match $other $path) })
  }
}

export def jsonl-stem []: string -> string {
  $in | str replace --regex '\.jsonl$' ""
}

export def max-mtime [files: list<string>]: nothing -> datetime {
  let run = (
    $files
    | append ""
    | str join (char nul)
    | ^xargs -0 stat -L -c "%Y" --
    | complete
  )
  if $run.exit_code != 0 {
    error make --unspanned {msg: $"Cannot read file modification times: ($run.stderr | str trim)"}
  }
  $run.stdout
  | lines
  | into int
  | math max
  | into datetime --format "%s"
}

export def files-under [dir: string]: nothing -> list<string> {
  if not ($dir | path exists) { return [] }
  if ($dir | path type) != "dir" { return [$dir] }
  let safe = if (
    ($dir | str starts-with "/")
    or ($dir | str starts-with "./")
    or ($dir | str starts-with "../")
  ) {
    $dir
  } else {
    $"./($dir)"
  }
  ^find -- $safe -type "f"
  | lines
  | each {|line|
    if $safe == $dir {
      $line
    } else {
      $line | str replace --regex '^\./' ""
    }
  }
  | sort
}

export def glob-under [dir: string, pattern: string]: nothing -> list<string> {
  if not ($dir | path exists) { return [] }
  let resolved = ($dir | path expand)
  if ($resolved | path type) != "dir" { return [] }
  do {
    cd $resolved
    glob $pattern
    | each {|match| $dir | path join ($match | path relative-to $resolved) }
  }
}
