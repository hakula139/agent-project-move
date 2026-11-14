# ==================================================================================================
# Agent Project Move: Claude Code
# ==================================================================================================
# Claude state, including its project directory encoding.
# ==================================================================================================

use ../lib/actions.nu [
  action
  copy-action
  edit-action
  merge-actions
  same-content
]
use ../lib/paths.nu [files-under outermost-paths path-map path-match valid-path]
use ../lib/rewrite.nu [files-with-path json-value rewrite-text rg-lines]
use ../lib/selection.nu [select-sessions]

const ENCODED_MAX = 200

# --------------------------------------------------------------------------------------------------
# Locations
# --------------------------------------------------------------------------------------------------

def root []: nothing -> string {
  $env.CLAUDE_CONFIG_DIR? | default --empty ($env.HOME | path join ".claude")
}

def global-config []: nothing -> string {
  ($env.CLAUDE_CONFIG_DIR? | default --empty $env.HOME) | path join ".claude.json"
}

def projects-dir []: nothing -> string { root | path join "projects" }

def project-dirs []: nothing -> list<string> {
  let dir = (projects-dir)
  if not ($dir | path exists) { return [] }
  ls $dir
  | where type == "dir"
  | get name
  | sort
}

def file-mtime [file: string]: nothing -> datetime {
  (^stat
    -L
    -c "%Y"
    -- $file)
  | str trim
  | into datetime --format "%s"
}

# --------------------------------------------------------------------------------------------------
# Encodings
# --------------------------------------------------------------------------------------------------
# Mirrors Claude Code: a project directory name replaces each character outside `[a-zA-Z0-9]` with
# one `-` per UTF-16 code unit, truncating to 200 characters and appending a base36 hash of the
# whole path when it overflows.

def utf8-codepoint [bytes: list<int>]: nothing -> int {
  if ($bytes | length) == 1 {
    $bytes.0
  } else if ($bytes | length) == 2 {
    let high = (($bytes.0 | bits and 0x1F) | bits shl --number-bytes 8 6)
    $high | bits or ($bytes.1 | bits and 0x3F)
  } else if ($bytes | length) == 3 {
    let high = (($bytes.0 | bits and 0x0F) | bits shl --number-bytes 8 12)
    let middle = (($bytes.1 | bits and 0x3F) | bits shl --number-bytes 8 6)
    $high | bits or ($middle | bits or ($bytes.2 | bits and 0x3F))
  } else {
    let high = (($bytes.0 | bits and 0x07) | bits shl --number-bytes 8 18)
    let middle = (($bytes.1 | bits and 0x3F) | bits shl --number-bytes 8 12)
    let low = (($bytes.2 | bits and 0x3F) | bits shl --number-bytes 8 6)
    $high | bits or ($middle | bits or ($low | bits or ($bytes.3 | bits and 0x3F)))
  }
}

def utf16-units [text: string]: nothing -> list<int> {
  $text
  | split chars
  | each {|char|
    let bytes = (
      $char
      | encode utf-8
      | to json --raw
      | from json
    )

    let codepoint = (utf8-codepoint $bytes)
    if $codepoint <= 0xFFFF {
      [$codepoint]
    } else {
      let value = ($codepoint - 0x10000)
      [
        (0xD800 | bits or ($value | bits shr --number-bytes 8 10))
        (0xDC00 | bits or ($value | bits and 0x3FF))
      ]
    }
  }
  | flatten
}

def wrap32 [value: int]: nothing -> int {
  let masked = ($value mod 0x100000000)
  if $masked >= 0x80000000 {
    $masked - 0x100000000
  } else {
    $masked
  }
}

def hash [text: string]: nothing -> int {
  mut hash = 0
  for unit in (utf16-units $text) {
    $hash = (wrap32 ($hash * 31 + $unit))
  }
  $hash
}

def base36 [value: int]: nothing -> string {
  let digits = ("0123456789abcdefghijklmnopqrstuvwxyz" | split chars)
  mut number: int = ($value | math abs)
  if $number == 0 { return "0" }

  mut encoded = []
  while $number > 0 {
    $encoded = ($encoded | append ($digits | get ($number mod 36)))
    $number = ($number // 36)
  }
  $encoded
  | reverse
  | str join
}

def sanitize [text: string]: nothing -> string {
  $text
  | split chars
  | each {|ch|
    if ($ch =~ "^[a-zA-Z0-9]$") {
      $ch
    } else {
      "-" | fill --character "-" --width (utf16-units $ch | length)
    }
  }
  | str join
}

export def encode-path [path: string]: nothing -> string {
  let sanitized = (sanitize $path)
  if ($sanitized | str length) <= $ENCODED_MAX {
    $sanitized
  } else {
    let head = ($sanitized | str substring 0..<$ENCODED_MAX)
    $"($head)-(base36 (hash $path))"
  }
}

# --------------------------------------------------------------------------------------------------
# Scan
# --------------------------------------------------------------------------------------------------

def config-paths []: nothing -> list<string> {
  let file = (global-config)
  if not ($file | path exists) { return [] }
  open $file
  | get -o projects
  | default {}
  | columns
}

def session-records [owner_hint?: string]: nothing -> list<record> {
  mut rows = []
  for dir in (project-dirs) {
    let files = (
      (glob ($dir | path join "*.jsonl"))
      ++ (glob ($dir | path join "*/subagents/agent-*.jsonl"))
      | sort
    )
    for file in $files {
      let cwds = (
        rg-lines ["-o" "--no-messages" '"cwd":"[^"]*"' $file]
        | parse --regex '^"cwd":"(?<cwd>[^"]*)"$'
        | each {|entry| json-value $entry.cwd }
        | uniq
      )

      let relative = (
        $file
        | path relative-to $dir
        | split row "/"
      )

      let parent = if ($relative | length) > 1 {
        $relative | first
      } else {
        null
      }

      let id = (
        $file
        | path basename
        | str replace --regex '\.jsonl$' ""
        | str replace --regex "^agent-" ""
      )

      for cwd in (if ($cwds | is-empty) { [null] } else { $cwds }) {
        $rows = ($rows | append {
          id: $id
          cwd: $cwd
          parent: $parent
          file: $file
          directory: $dir
        })
      }
    }
  }
  let candidates = (
    ($rows | get -o cwd) ++ (config-paths) ++ [$owner_hint]
    | where {|cwd| valid-path $cwd }
    | uniq
    | each {|cwd| {cwd: $cwd, name: (encode-path $cwd)}}
  )

  $rows
  | each {|record|
    let name = ($record.directory | path basename)
    let owners = ($candidates | where name == $name)
    let owner = if ($owners | length) == 1 { $owners | first | get cwd } else { null }
    $record
    | upsert owner $owner
    | update cwd ($record.cwd | default $owner)
  }
}

export def recorded-paths []: nothing -> list<string> {
  session-records
  | get -o cwd
  | where {|cwd| valid-path $cwd }
  | uniq
}

export def scan []: nothing -> list<record> {
  session-records
  | where {|record| valid-path $record.cwd }
  | group-by cwd
  | transpose cwd items
  | each {|group|
    let files = ($group.items | get file | uniq)
    let timestamps = ($files | each {|file| file-mtime $file } | sort)
    {
      assistant: "claude"
      path: $group.cwd
      sessions: ($files | length)
      last_used: ($timestamps | last)
    }
  }
  | sort-by path
}

def session-project-files [records: list<record>]: nothing -> list<record> {
  $records
  | each {|record|
    let subtree = ($record.file | str replace --regex '\.jsonl$' "")
    [$record.file] ++ (files-under $subtree)
    | each {|file| {file: $file, directory: $record.directory, owner: $record.owner}}
  }
  | flatten
  | uniq
}

# --------------------------------------------------------------------------------------------------
# Move
# --------------------------------------------------------------------------------------------------

export def plan-move [old: string, new: string]: nothing -> list<record> {
  let inventory = (session-records $old)
  let unknown = (
    $inventory
    | where {|record| $record.owner == null and (path-match $old $record.cwd) }
    | first
  )
  if $unknown != null {
    error make --unspanned {msg: $"Cannot locate the project owner of ($unknown.file)"}
  }
  let selected = (
    $inventory
    | where {|record| $record.owner != null and (path-match $old $record.owner) }
    | select directory owner
    | uniq
  )
  let rewrite = {|content| rewrite-text $content $old $new }
  let project_files = (
    $inventory
    | get -o file
    | uniq
    | files-with-path $old $in --glob ["*.jsonl"]
  )
  mut actions = (
    $project_files
    | each {|file| edit-action "claude" "projects" $file $rewrite "rewrite paths" }
  )

  for item in $selected {
    let target = (projects-dir | path join (encode-path (path-map $old $new $item.owner)))
    $actions = ($actions ++ (
      merge-actions "claude" "projects" $item.directory $target "merge project directory"
    ))
  }
  $actions
}

# --------------------------------------------------------------------------------------------------
# Retirement
# --------------------------------------------------------------------------------------------------

def session-deletions [records: list<record>]: nothing -> list<record> {
  let files = (
    $records
    | get -o file
    | uniq
  )

  let subtrees = (
    $files
    | each {|file| $file | str replace --regex '\.jsonl$' "" }
    | where {|path| $path | path exists }
  )

  let history = (
    $records
    | get -o id
    | uniq
    | each {|id| root | path join "file-history" $id }
    | where {|path| $path | path exists }
  )

  $files ++ $subtrees ++ $history
  | outermost-paths $in
  | each {|path| action "claude" "sessions" "delete" $path "session state" }
}

export def plan-retire [
  old: string
  --exact
  --session-ids: list<string> = []
]: nothing -> list<record> {
  select-sessions (session-records $old) $old --exact=$exact --session-ids $session_ids
  | session-deletions $in
}

# --------------------------------------------------------------------------------------------------
# Transfer
# --------------------------------------------------------------------------------------------------

export def export-bundle [
  old: string
  --exact
  --session-ids: list<string> = []
]: nothing -> record {
  let selected = (select-sessions (session-records $old) $old --exact=$exact --session-ids $session_ids)
  mut files = (
    session-project-files $selected
    | each {|item|
      if $item.owner == null {
        error make --unspanned {msg: $"Cannot locate the project owner of ($item.file)"}
      }
      {
        kind: "projects"
        project: $item.owner
        name: ($item.file | path relative-to $item.directory)
        source: $item.file
      }
    }
  )

  for session in ($selected | get -o id | uniq) {
    let history = (root | path join "file-history" $session)
    for file in (files-under $history) {
      $files = ($files | append {
        kind: "file-history"
        project: $session
        session: $session
        name: ($file | path relative-to $history)
        source: $file
      })
    }
  }

  {
    assistant: "claude"
    old: $old
    files: $files
    tables: []
  }
}

def matches-import [file: record, target: string]: nothing -> bool {
  if $file.expected == null {
    same-content $file.bundle $target
  } else {
    (open --raw $target) == $file.expected
  }
}

def imported-elsewhere [projects: list<string>, file: record]: nothing -> bool {
  $projects
  | any {|project|
    let candidate = ($project | path join $file.name)
    if not ($candidate | path exists) { return false }
    if not (matches-import $file $candidate) {
      error make --unspanned {msg: $"Existing session ($file.name) differs from the bundle"}
    }
    true
  }
}

export def plan-import [bundle: record, --target: string]: nothing -> list<record> {
  let root = (root)
  let projects = (project-dirs)
  let transcripts = (
    $bundle.files
    | where {|file|
      (
        $file.kind == "projects"
        and ($file.name =~ '^(?:[^/]+|[^/]+/subagents/agent-[^/]+)\.jsonl$')
      )
    }
  )
  let carried = (
    $bundle.files
    | where {|file|
      $file.kind == "file-history" or (
        $file.kind == "projects" and ($transcripts | any {|session|
          $session.project == $file.project and (
            $session.name == $file.name
            or (path-match ($session.name | str replace --regex '\.jsonl$' "") $file.name)
          )
        })
      )
    }
  )
  let rewritten = if $target == null {
    []
  } else {
    let sources = ($transcripts | get -o bundle)
    files-with-path $bundle.old $sources --glob ["*.jsonl"]
  }

  let files = (
    $carried
    | each {|file|
      let content = if $file.bundle in $rewritten { open --raw $file.bundle } else { null }
      let transform = if ($content | describe) == "string" {
        {|content| rewrite-text $content $bundle.old $target }
      } else {
        null
      }
      let expected = if $transform == null { null } else { do $transform $content }
      let project = if $target != null and $file.kind == "projects" {
        path-map $bundle.old $target $file.project
      } else {
        $file.project
      }
      $file | merge {project: $project, expected: $expected, transform: $transform}
    }
  )

  $files
  | each {|file|
    let target = if $file.kind == "file-history" {
      $root | path join "file-history" $file.session $file.name
    } else {
      if (imported-elsewhere $projects $file) { return null }
      let directory = ($root | path join "projects" (encode-path $file.project))
      let separated = (
        $files
        | where {|session|
          (
            $session.kind == "projects" and $session.project == $file.project
            and ($session.name =~ '^(?:[^/]+|[^/]+/subagents/agent-[^/]+)\.jsonl$')
            and (path-match ($session.name | str replace --regex '\.jsonl$' "") $file.name)
          )
        }
        | any {|session|
          (
            not ($directory | path join $session.name | path exists)
            and (imported-elsewhere $projects $session)
          )
        }
      )
      if $separated {
        error make --unspanned {
          msg: $"The session for ($file.name) already exists in another project directory"
          help: "Reconcile the transcript and its artifacts before importing. Nothing was written."
        }
      }
      $directory | path join $file.name
    }

    if ($target | path exists) {
      if (matches-import $file $target) { return null }
      error make --unspanned {
        msg: $"($target) already exists with content that differs from the bundle's copy"
        help: "Compare the two files. Delete or rename the local file if the bundle's copy should win, then rerun the import."
      }
    }
    copy-action "claude" $file.kind $file.bundle $target "import session file" --transform $file.transform
  }
  | compact
}
