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
  session-merge-actions
  session-move-targets
]
use ../lib/paths.nu [
  files-under
  glob-under
  home-dir
  jsonl-stem
  outermost-paths
  path-map
  path-match
  valid-path
]
use ../lib/rewrite.nu [files-with-path json-value rewrite-text rg-lines]
use ../lib/selection.nu [scan-sessions select-sessions]

const ENCODED_MAX = 200
const TRANSCRIPT_NAME = '^(?:[^/]+|[^/]+/subagents/agent-[^/]+)\.jsonl$'

# --------------------------------------------------------------------------------------------------
# Locations
# --------------------------------------------------------------------------------------------------

def root []: nothing -> string {
  $env.CLAUDE_CONFIG_DIR? | default --empty (home-dir | path join ".claude")
}

def global-config []: nothing -> string {
  ($env.CLAUDE_CONFIG_DIR? | default --empty (home-dir)) | path join ".claude.json"
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
  let config = try {
    open --raw $file
    | into string
    | from json
  } catch {
    return []
  }
  if not ($config | describe | str starts-with "record") { return [] }
  let projects = ($config | get -o projects)
  if not ($projects | describe | str starts-with "record") { return [] }
  $projects | columns
}

def subagent-parent [file: string, fallback: string]: nothing -> string {
  let meta_file = $"($file | jsonl-stem).meta.json"
  if not ($meta_file | path exists) or ($meta_file | path type) != "file" {
    return $fallback
  }
  let meta = try {
    open --raw $meta_file
    | into string
    | from json
  } catch {
    return $fallback
  }
  if not ($meta | describe | str starts-with "record") {
    return $fallback
  }
  let parent_id = ($meta | get -o parentAgentId)
  if ($parent_id | describe) == "string" and $parent_id != "" {
    $parent_id
  } else {
    $fallback
  }
}

def session-sidecars [file: string]: nothing -> list<string> {
  let meta = $"($file | jsonl-stem).meta.json"
  if ($meta | path exists) and ($meta | path type) == "file" {
    [$meta]
  } else {
    []
  }
}

def session-records [owner_hint?: string]: nothing -> list<record> {
  mut rows = []
  for dir in (project-dirs) {
    let files = (
      (glob-under $dir "*.jsonl")
      ++ (glob-under $dir "*/subagents/agent-*.jsonl")
      | sort
    )
    for file in $files {
      let cwds = (
        rg-lines ["-a" "-o" "--no-messages" '"cwd":"(?:\\.|[^"\\])*"' "--" $file]
        | parse --regex '^"cwd":"(?<cwd>(?:\\.|[^"\\])*)"$'
        | each {|entry|
          try {
            json-value $entry.cwd
          } catch {
            null
          }
        }
        | compact
        | uniq
      )

      let relative = (
        $file
        | path relative-to $dir
        | split row "/"
      )

      let parent = if ($relative | length) > 1 {
        subagent-parent $file ($relative | first)
      } else {
        null
      }

      let id = (
        $file
        | path basename
        | jsonl-stem
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
    | each {|cwd|
      {
        cwd: $cwd
        name: (encode-path $cwd)
      }
    }
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

export def scan []: nothing -> list<record> {
  session-records | scan-sessions "claude"
}

def session-project-files [records: list<record>]: nothing -> list<record> {
  $records
  | each {|record|
    let subtree = ($record.file | jsonl-stem)
    [$record.file] ++ (session-sidecars $record.file) ++ (files-under $subtree)
    | each {|file|
      {
        file: $file
        directory: $record.directory
        owner: $record.owner
      }
    }
  }
  | flatten
  | uniq
}

# --------------------------------------------------------------------------------------------------
# Move
# --------------------------------------------------------------------------------------------------

export def plan-move [
  old: string
  new: string
  --exact
  --session-ids: list<string> = []
]: nothing -> list<record> {
  let inventory = (session-records $old)
  let selective = $exact or ($session_ids | is-not-empty)
  let rows = if $selective {
    select-sessions $inventory $old --exact=$exact --session-ids $session_ids
  } else {
    $inventory
  }
  let unknown = (
    $rows
    | where {|row| $row.owner == null and ($selective or (path-match $old $row.cwd)) }
    | first
  )
  if $unknown != null {
    error make --unspanned {msg: $"Cannot locate the project owner of ($unknown.file)"}
  }
  let rewrite = {|content| rewrite-text $content $old $new }
  let edits = (
    $rows
    | get -o file
    | uniq
    | files-with-path $old $in --glob ["*.jsonl"]
    | each {|file| edit-action "claude" "projects" $file $rewrite "rewrite paths" }
  )

  let moves = if $selective {
    let encode = {|path| encode-path $path }
    let targets = (session-move-targets $rows $old $new $encode --sidecars [".meta.json"])
    session-merge-actions "claude" "projects" $targets
  } else {
    $rows
    | where {|row| path-match $old $row.owner }
    | select directory owner
    | uniq
    | each {|item|
      let target = (projects-dir | path join (encode-path (path-map $old $new $item.owner)))
      merge-actions "claude" "projects" $item.directory $target "merge project directory"
    }
    | flatten
  }
  $edits ++ $moves
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

  let sidecars = (
    $files
    | each {|file| session-sidecars $file }
    | flatten
  )

  let subtrees = (
    $files
    | each {|file| $file | jsonl-stem }
    | where {|path| $path | path exists }
  )

  let history = (
    $records
    | get -o id
    | uniq
    | each {|id| root | path join "file-history" $id }
    | where {|path| $path | path exists }
  )

  $files ++ $sidecars ++ $subtrees ++ $history
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
  let selected = (
    select-sessions (session-records $old) $old --exact=$exact --session-ids $session_ids
  )
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

def owns-project-entry [transcript: string, entry: string]: nothing -> bool {
  let stem = ($transcript | jsonl-stem)
  (
    $entry == $transcript
    or $entry == $"($stem).meta.json"
    or (path-match $stem $entry)
  )
}

export def plan-import [bundle: record, --target: string]: nothing -> list<record> {
  let root = (root)
  let projects = (project-dirs)
  let transcripts = (
    $bundle.files
    | where {|file| $file.kind == "projects" and ($file.name =~ $TRANSCRIPT_NAME) }
  )
  let carried = (
    $bundle.files
    | where {|file|
      $file.kind == "file-history" or (
        $file.kind == "projects" and ($transcripts | any {|session|
          $session.project == $file.project and (owns-project-entry $session.name $file.name)
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
      $file | merge {
        project: $project
        expected: $expected
        transform: $transform
      }
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
            $session.kind == "projects"
            and $session.project == $file.project
            and ($session.name =~ $TRANSCRIPT_NAME)
            and (owns-project-entry $session.name $file.name)
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
        help: (
          "Compare the two files. If you want the bundle's copy, remove or rename the local file."
          + " Then rerun the import."
        )
      }
    }
    let description = "import session file"
    copy-action "claude" $file.kind $file.bundle $target $description --transform $file.transform
  }
  | compact
}
