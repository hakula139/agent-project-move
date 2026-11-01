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
  rename-action
  same-content
  same-directory
]
use ../lib/paths.nu [files-under match-any path-map path-match valid-path]
use ../lib/rewrite.nu [files-with-path json-value rewrite-text rg-lines]

const ENCODED_MAX = 200

# --------------------------------------------------------------------------------------------------
# Locations
# --------------------------------------------------------------------------------------------------

def root []: nothing -> string {
  $env.CLAUDE_CONFIG_DIR? | default --empty ($env.HOME | path join .claude)
}

def global-config []: nothing -> string {
  ($env.CLAUDE_CONFIG_DIR? | default --empty $env.HOME) | path join .claude.json
}

def projects-dir []: nothing -> string { root | path join projects }

def project-dirs []: nothing -> list<string> {
  let dir = (projects-dir)
  if not ($dir | path exists) { return [] }
  ls $dir | where type == "dir" | get name | sort
}

def top-files [dir: string]: nothing -> list<string> {
  glob ($dir | path join '*.jsonl') | sort
}

def file-mtime [file: string]: nothing -> datetime {
  ^stat -L -c %Y -- $file | str trim | into datetime --format '%s'
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
    let bytes = ($char | encode utf-8 | to json --raw | from json)
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
  if $masked >= 0x80000000 { $masked - 0x100000000 } else { $masked }
}

def hash [text: string]: nothing -> int {
  mut hash = 0
  for unit in (utf16-units $text) {
    $hash = (wrap32 ($hash * 31 + $unit))
  }
  $hash
}

def base36 [value: int]: nothing -> string {
  let digits = ('0123456789abcdefghijklmnopqrstuvwxyz' | split chars)
  mut number: int = ($value | math abs)
  if $number == 0 { return "0" }

  mut encoded = []
  while $number > 0 {
    $encoded = ($encoded | append ($digits | get ($number mod 36)))
    $number = ($number // 36)
  }
  $encoded | reverse | str join
}

def sanitize [text: string]: nothing -> string {
  $text
  | split chars
  | each {|ch|
    if ($ch =~ '^[a-zA-Z0-9]$') {
      $ch
    } else {
      "-" | fill --character '-' --width (utf16-units $ch | length)
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

# Every `cwd` a top-level transcript records, as file and decoded path.
def transcript-cwds []: nothing -> list<record> {
  let dir = (projects-dir)
  if not ($dir | path exists) { return [] }

  rg-lines [-o --with-filename --no-messages --max-depth 2 -g '*.jsonl' '"cwd":"[^"]*"' $dir]
  | parse --regex '^(?<file>.+?):"cwd":"(?<cwd>[^"]*)"$'
  | each {|entry| $entry | upsert cwd (json-value $entry.cwd) }
}

# The cwds that name their own project directory, deduplicated by file and cwd. A cwd a session
# only visited owns no state, so it is neither listed nor pruned.
def identity-records [transcripts: list<record>]: nothing -> list<record> {
  let names = (
    $transcripts
    | get cwd
    | uniq
    | each {|cwd| {($cwd): (encode-path $cwd)}}
    | reduce --fold {} {|entry, names| $names | merge $entry}
  )
  $transcripts
  | uniq
  | where {|entry| ($names | get -o $entry.cwd) == ($entry.file | path dirname | path basename) }
}

def history-records []: nothing -> list<record> {
  let file = (root | path join history.jsonl)
  if not ($file | path exists) { return [] }

  open --raw $file
  | lines
  | each {|line| try { $line | from json } catch { null } }
  | where {|record| ($record | get -o project | describe) == "string" }
}

def global-config-data []: nothing -> record {
  let file = (global-config)
  if not ($file | path exists) { return {} }
  open $file
}

def global-projects []: nothing -> record {
  global-config-data | get -o projects | default {}
}

def repo-paths []: nothing -> record {
  global-config-data | get -o githubRepoPaths | default {}
}

def config-paths []: nothing -> list<string> {
  (global-projects | columns) ++ (repo-paths | values | flatten)
}

def recorded-from [transcripts: list<record>]: nothing -> list<string> {
  let transcript = ($transcripts | get -o cwd)
  let history = (history-records | get -o project)
  $transcript
  | append $history
  | append (config-paths)
  | where {|path| valid-path $path }
  | uniq
}

export def recorded-paths []: nothing -> list<string> {
  recorded-from (identity-records (transcript-cwds))
}

def selected-dirs [old: string]: nothing -> list<record> {
  let recorded = (recorded-paths)
  let owned = ($recorded | where {|path| path-match $old $path })
  let names = ($owned | each {|path| {name: (encode-path $path), owner: $path} })
  let old_name = (encode-path $old)

  project-dirs
  | each {|dir|
    let name = ($dir | path basename)
    let match = ($names | where name == $name | get -o 0)
    let owner = if $match != null {
      $match.owner
    } else if $name == $old_name {
      $old
    } else {
      null
    }
    if $owner == null { return null }

    let outside = (
      $recorded
      | where {|path| ((encode-path $path) == $name) and (not (path-match $old $path)) }
    )
    if ($outside | is-not-empty) {
      print $"Skipping ($dir): another recorded path encodes to the same name"
      return null
    }
    {dir: $dir, owner: $owner}
  }
  | compact
}

export def scan []: nothing -> list<record> {
  let identity = (
    identity-records (transcript-cwds)
    | where {|entry| valid-path $entry.cwd }
  )

  let stamps = (
    $identity
    | get file
    | uniq
    | each {|file| {file: $file, timestamp: (file-mtime $file)} }
  )

  let transcript = (
    $identity
    | group-by cwd
    | transpose cwd items
    | each {|group|
      let files = ($group.items | get file | uniq)
      let timestamps = ($stamps | where {|stamp| $stamp.file in $files } | get timestamp | sort)
      {
        assistant: claude
        path: $group.cwd
        sessions: ($files | length)
        last_used: ($timestamps | last)
      }
    }
  )

  let history = (
    history-records
    | get -o project
    | where {|path| valid-path $path }
    | uniq
    | where {|path| $path not-in ($transcript | get path) }
    | each {|path| {assistant: claude, path: $path, sessions: 0, last_used: null} }
  )
  let seen = (($transcript | get path) ++ ($history | get path))

  let config = (
    config-paths
    | where {|path| (valid-path $path) and ($path not-in $seen) }
    | uniq
    | each {|path| {assistant: claude, path: $path, sessions: 0, last_used: null} }
  )
  ($transcript ++ $history ++ $config) | sort-by path
}

# --------------------------------------------------------------------------------------------------
# Move
# --------------------------------------------------------------------------------------------------

export def move-config [config: record, old: string, new: string]: nothing -> record {
  let projects = ($config | get -o projects | default {})
  let updated_projects = (
    $projects
    | transpose key value
    | reduce --fold {} {|entry, result|
      if not (path-match $old $entry.key) {
        $result | upsert $entry.key $entry.value
      } else {
        let target = (path-map $old $new $entry.key)
        if $target not-in ($result | columns) {
          $result | upsert $target $entry.value
        } else {
          $result
        }
      }
    }
  )

  let repos = ($config | get -o githubRepoPaths | default {})
  let updated_repos = (
    $repos
    | update cells {
      $in
      | each --keep-empty {|path|
        if (path-match $old $path) { path-map $old $new $path } else { $path }
      }
      | uniq
    }
  )

  $config | upsert projects $updated_projects | upsert githubRepoPaths $updated_repos
}

def project-merge [source: string, target: string]: nothing -> list<record> {
  if (same-directory $source $target) { return [] }
  let index = ($source | path join sessions-index.json)
  let memory = ($source | path join memory)
  let target_memory = ($target | path join memory)
  mut skip = []
  mut actions = []

  if ($index | path exists) {
    let delete_index = (action claude projects delete $index "remove stale sessions index")
    $actions = ($actions | append $delete_index)
    $skip = ($skip | append $index)
  }

  if ($memory | path exists) and ($target_memory | path exists) {
    let staging = ($target_memory | path join incoming ($source | path basename))
    let stage = if ($staging | path exists) {
      merge-actions claude memory $memory $staging "stage memory for review"
    } else {
      [(rename-action claude memory $memory $staging "stage memory for review")]
    }
    $actions = ($actions ++ $stage)
    $skip = ($skip | append $memory)
  }

  let merged = (
    merge-actions claude projects $source $target "merge project directory" --skip $skip
  )
  $actions ++ $merged
}

export def plan-move [old: string, new: string]: nothing -> list<record> {
  let selected = (selected-dirs $old)
  let rewrite = {|content| rewrite-text $content $old $new }
  mut actions = []

  let project_files = (
    files-with-path $old [(projects-dir)] --glob ["*.jsonl" "*.json"]
    | where {|file| ($file | path basename) != sessions-index.json }
  )
  for file in $project_files {
    $actions = ($actions | append (edit-action claude projects $file $rewrite "rewrite paths"))
  }

  for file in (files-with-path $old [(root | path join teams)] --glob ["*.json"]) {
    $actions = ($actions | append (edit-action claude teams $file $rewrite "rewrite team cwd"))
  }

  for item in $selected {
    let target = (projects-dir | path join (encode-path (path-map $old $new $item.owner)))
    $actions = ($actions ++ (project-merge $item.dir $target))
  }

  let config = (global-config)
  let config_match = (config-paths | any {|path| path-match $old $path })
  if ($config | path exists) and $config_match {
    $actions = ($actions | append (edit-action claude global-config $config {|content|
      $content | from json | move-config $in $old $new | to json
    } "rewrite projects and githubRepoPaths"))
  }

  let history = (root | path join history.jsonl)
  for file in (files-with-path $old [$history]) {
    $actions = ($actions | append (edit-action claude history $file $rewrite "rewrite project"))
  }

  $actions
}

# --------------------------------------------------------------------------------------------------
# Prune
# --------------------------------------------------------------------------------------------------

export def prune-config [config: record, paths: list<string>]: nothing -> record {
  let projects = ($config | get -o projects | default {})
  let removed = (
    $projects
    | transpose key value
    | where {|entry| match-any $paths $entry.key }
    | get key
  )
  let updated_projects = ($projects | reject ...$removed)

  let repos = ($config | get -o githubRepoPaths | default {})
  let pruned_repos = (
    $repos
    | update cells { $in | where {|path| not (match-any $paths $path) } }
  )
  let dropped = (
    $pruned_repos
    | transpose slug entries
    | where {|entry| ($entry.entries | is-empty) }
    | get slug
  )
  let updated_repos = ($pruned_repos | reject ...$dropped)

  $config | upsert projects $updated_projects | upsert githubRepoPaths $updated_repos
}

def project-path [line: string]: nothing -> any {
  let found = ($line | parse --regex '"project":"(?<project>[^"]*)"' | get -o 0)
  if $found == null { null } else { json-value $found.project }
}

def prune-history [content: string, paths: list<string>]: nothing -> string {
  let trailing = ($content | str ends-with "\n")
  let lines = (
    $content
    | lines
    | where {|line|
      let project = (project-path $line)
      ($project == null) or (not (match-any $paths $project))
    }
  )
  let body = ($lines | str join "\n")
  if $trailing { $body + "\n" } else { $body }
}

export def plan-prune [paths: list<string>]: nothing -> list<record> {
  mut actions = []
  let transcripts = (identity-records (transcript-cwds))
  let known = (recorded-from $transcripts)
  let live_paths = ($known | where {|path| $path | path exists })
  let missing_names = (
    $paths
    | each {|path|
      ($known | where {|known_path| path-match $path $known_path })
      | append $path
      | each {|known_path| encode-path $known_path }
    }
    | flatten
    | uniq
  )

  for dir in (project-dirs) {
    let name = ($dir | path basename)
    if $name not-in $missing_names { continue }
    let cwds = (
      $transcripts
      | where {|record| ($record.file | path dirname) == $dir }
      | get cwd
      | uniq
    )
    if ($cwds | is-not-empty) and (not ($cwds | all {|cwd| match-any $paths $cwd })) {
      print $"Skipping ($dir): records a path outside the pruned paths"
      continue
    }
    let live = ($live_paths | any {|path| (encode-path $path) == $name })
    if $live {
      print $"Skipping ($dir): a live path encodes to the same name"
      continue
    }
    $actions = ($actions | append (action claude projects delete $dir "project directory"))
  }

  let config = (global-config)
  let config_match = (config-paths | any {|path| match-any $paths $path })
  if ($config | path exists) and $config_match {
    $actions = ($actions | append (edit-action claude global-config $config {|content|
      $content | from json | prune-config $in $paths | to json
    } "remove projects and githubRepoPaths"))
  }

  let history = (root | path join history.jsonl)
  let history_match = (
    history-records
    | any {|record| match-any $paths ($record | get -o project) }
  )
  if ($history | path exists) and $history_match {
    $actions = ($actions | append (edit-action claude history $history {|content|
      prune-history $content $paths
    } "remove project entries"))
  }
  $actions
}

# --------------------------------------------------------------------------------------------------
# Transfer
# --------------------------------------------------------------------------------------------------

export def export-bundle [old: string]: nothing -> record {
  let selected = (selected-dirs $old)
  mut files = []

  for item in $selected {
    for file in (files-under $item.dir) {
      if ($file | path basename) == sessions-index.json { continue }
      let name = ($file | path relative-to $item.dir)
      $files = ($files | append {
        kind: projects
        project: $item.owner
        name: $name
        source: $file
      })
    }
  }

  let sessions = (
    $selected
    | each {|item|
      top-files $item.dir
      | each {|file| $file | path basename | str replace --regex '\.jsonl$' '' }
    }
    | flatten
    | uniq
  )
  for session in $sessions {
    let history = (root | path join file-history $session)
    for file in (files-under $history) {
      $files = ($files | append {
        kind: file-history
        project: $session
        session: $session
        name: ($file | path relative-to $history)
        source: $file
      })
    }
  }

  {assistant: claude, old: $old, files: $files, tables: []}
}

def imported-elsewhere [projects: list<string>, file: record]: nothing -> bool {
  $projects
  | any {|project|
    let candidate = ($project | path join $file.name)
    if not ($candidate | path exists) {
      false
    } else if ($file.name | str starts-with "memory/") {
      same-content $file.bundle $candidate
    } else {
      true
    }
  }
}

export def plan-import [bundle: record]: nothing -> list<record> {
  let root = (root)
  let project_root = (projects-dir)
  let projects = if ($project_root | path exists) {
    ls $project_root | where type == "dir" | get name
  } else {
    []
  }
  let sessions = (
    $bundle.files
    | where {|file| ($file | get -o kind) == "projects" }
    | where {|file| not ($file.name | str starts-with "memory/") }
  )
  if ($sessions | is-not-empty) and ($sessions | all {|file| imported-elsewhere $projects $file }) {
    return []
  }
  mut actions = []

  for file in $bundle.files {
    if ($file | get -o kind) == "file-history" {
      let target = ($root | path join file-history $file.session $file.name)
      if ($target | path exists) {
        if (same-content $file.bundle $target) { continue }
        error make --unspanned {
          msg: $"($target) already exists with content that differs from the bundle's copy"
          help: "Compare the two files. Delete or rename the local file if the bundle's copy should win, then rerun the import."
        }
      }
      let write = (
        copy-action claude file-history $file.bundle $target "import file history"
      )
      $actions = ($actions | append $write)
      continue
    }

    let project_dir = ($root | path join projects (encode-path $file.project))
    let memory_dir = ($project_dir | path join memory)
    let staged = (($file.name | str starts-with "memory/") and ($memory_dir | path exists))
    let direct = ($project_dir | path join $file.name)
    let target = if $staged {
      let relative = ($file.name | str replace --regex '^memory/' '')
      $memory_dir | path join incoming (encode-path $file.project) $relative
    } else {
      $direct
    }
    let description = if $staged { "stage memory for review" } else { "import project file" }

    if not $staged and (imported-elsewhere $projects $file) { continue }
    if ($target | path exists) {
      if (same-content $file.bundle $target) { continue }
      if $staged {
        error make --unspanned {
          msg: $"($target) already exists with content that differs from the bundle's copy"
          help: "Consolidate or remove the staged copy, then rerun the import."
        }
      }
      error make --unspanned {
        msg: $"($target) already exists with content that differs from the bundle's copy"
        help: "Compare the two files. Delete or rename the local file if the bundle's copy should win, then rerun the import."
      }
    }
    if $staged and (imported-elsewhere $projects $file) { continue }
    let write = (copy-action claude projects $file.bundle $target $description)
    $actions = ($actions | append $write)
  }
  $actions
}
