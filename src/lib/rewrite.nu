# ==================================================================================================
# Agent Project Move: Rewrites
# ==================================================================================================
# JSON string tokens that hold a recorded path, file selection, and byte-offset stability.
# ==================================================================================================

# Codex records some path fields as file URIs. Mirrors the url crate's Unix `from_file_path` set
# (`SPECIAL_PATH_SEGMENT`) behind Codex's PathUri, which keeps `-`, `_`, `~`, and the
# sub-delimiters literal and escapes `\`.
export def file-uri [path: string]: nothing -> string {
  let encoded = (
    $path
    | split chars
    | each {|ch|
      if ($ch =~ '^[A-Za-z0-9/!$&''()*+,.:;=@\[\]^_~|-]$') {
        $ch
      } else {
        $ch | url encode --all
      }
    }
    | str join
  )
  "file://" + $encoded
}

export def json-escape [text: string]: nothing -> string {
  ($text | to json) | str substring 1..<(-1)
}

def regex-escape [text: string]: nothing -> string {
  $text
  | split chars
  | each {|ch| if ($ch =~ '^[\\^$.*+?()\[\]{}|/-]$') { "\\" + $ch } else { $ch } }
  | str join
}

def escape-replacement [text: string]: nothing -> string {
  $text | str replace --all '$' '$$'
}

# A JSON string token equal to a path or under it, plain or as a file URI.
def path-pattern [old: string]: nothing -> string {
  let plain = (regex-escape (json-escape $old))
  let uri = (regex-escape (json-escape (file-uri $old)))
  '(?<!\\)"(' + $plain + '|' + $uri + ')(?=["/])'
}

# The lines ripgrep matched. Exit status 1 means no match.
export def rg-lines [args: list<string>]: nothing -> list<string> {
  let run = (^rg ...$args | complete)
  if $run.exit_code > 1 {
    error make --unspanned {
      msg: $"rg failed: ($run.stderr | str trim)"
      help: "Check that ripgrep can read the searched directories."
    }
  }
  $run.stdout | lines | where {|line| $line != "" }
}

# The path a matched `"key":"<value>"` token holds, decoded from its JSON escapes.
export def json-value [value: string]: nothing -> string {
  $"\"($value)\"" | from json
}

# The files holding a string token for the path, compressed ones included.
export def files-with-path [
  old: string
  roots: list<string>
  --glob (-g): list<string> = []
]: nothing -> list<string> {
  let existing = ($roots | where {|root| $root | path exists })
  if ($existing | is-empty) { return [] }

  let globs = ($glob | each {|pattern| ["-g" $pattern] } | flatten)
  rg-lines [-z -P -l --hidden --no-ignore ...$globs -e (path-pattern $old) -- ...$existing]
  | sort
}

export def rewrite-text [content: string, old: string, new: string]: nothing -> string {
  # Lookbehinds over a multi-megabyte transcript line exceed the regex engine's backtrack limit,
  # so the preceding character and the delimiter are captured.
  let plain = (regex-escape (json-escape $old))
  let uri = (regex-escape (json-escape (file-uri $old)))
  let plain_new = ('$1"' + (escape-replacement (json-escape $new)) + '$3')
  let uri_new = ('$1"' + (escape-replacement (json-escape (file-uri $new))) + '$3')
  let plain_pattern = '(^|[^\\])"(' + $plain + ')(["/])'
  let uri_pattern = '(^|[^\\])"(' + $uri + ')(["/])'
  $content | str replace --all --regex $plain_pattern $plain_new
  | str replace --all --regex $uri_pattern $uri_new
}

# Whether both spellings keep the byte length of their JSON-escaped form, so JSON Lines offsets
# stay valid. A URI carries no JSON escapes.
export def offsets-kept [old: string, new: string]: nothing -> bool {
  (
    ((json-escape $old | str length -b) == (json-escape $new | str length -b))
    and ((file-uri $old | str length -b) == (file-uri $new | str length -b))
  )
}
