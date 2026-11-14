# ==================================================================================================
# Agent Project Move: OMP
# ==================================================================================================
# OMP session transcripts and their owned artifacts.
# ==================================================================================================

use ../lib/actions.nu [
  action
  copy-action
  edit-action
  merge-actions
  same-content
]
use ../lib/paths.nu [
  files-under
  outermost-paths
  path-map
  path-match
  valid-path
]
use ../lib/rewrite.nu [files-with-path rewrite-text]
use ../lib/selection.nu [select-sessions]

# --------------------------------------------------------------------------------------------------
# Locations
# --------------------------------------------------------------------------------------------------

def agent-dir []: nothing -> string {
  $env.PI_CODING_AGENT_DIR? | default --empty ($env.HOME | path join ".omp/agent")
}

def session-root []: nothing -> string { agent-dir | path join "sessions" }

def archive-root []: nothing -> string { agent-dir | path join "archive/sessions" }

# Resolve a path without requiring it to exist.
def resolved-path [path: string]: nothing -> string {
  ^realpath -m $path | str trim
}

# --------------------------------------------------------------------------------------------------
# Encodings
# --------------------------------------------------------------------------------------------------

# Mirrors OMP: session directories resolve the cwd, home, and temp dir through realpath.
def session-encode [path: string, home: string, tmp: string]: nothing -> string {
  let real = (resolved-path $path)
  let home = (resolved-path $home)
  let tmp = (resolved-path $tmp)

  if $real == $home or (path-match $home $real) {
    let relative = if $real == $home {
      ""
    } else {
      $real | str substring (($home | str length) + 1)..
    }
    "-" + ($relative | str replace --all --regex '[/\\:]' "-")
  } else if $real == $tmp or (path-match $tmp $real) {
    let relative = if $real == $tmp {
      ""
    } else {
      $real | str substring (($tmp | str length) + 1)..
    }
    "-tmp-" + ($relative | str replace --all --regex '[/\\:]' "-")
  } else {
    let stripped = ($real | str replace --regex "^/" "")
    $"--($stripped | str replace --all --regex '[/\\:]' '-')--"
  }
}

export def session-encode-here [path: string]: nothing -> string {
  let tmp = ($env.TMPDIR? | default --empty "/tmp")
  session-encode $path $env.HOME $tmp
}

# --------------------------------------------------------------------------------------------------
# Scan
# --------------------------------------------------------------------------------------------------

def session-header [file: string]: nothing -> any {
  if not ($file | str ends-with ".jsonl") { return null }
  open --raw $file
  | lines
  | each {|line|
    try {
      $line | from json
    } catch {
      null
    }
  }
  | where {|row| ($row | get -o type) == "session" }
  | first
}

def session-records []: nothing -> list<record> {
  mut rows = []
  for spec in [
    {
      kind: "sessions"
      root: (session-root)
    }
    {
      kind: "archives"
      root: (archive-root)
    }
  ] {
    for file in (files-under $spec.root | where {|file| $file | str ends-with ".jsonl" }) {
      let header = (session-header $file)
      if $header == null { continue }
      let project = (
        $file
        | path relative-to $spec.root
        | split row "/"
        | first
      )
      let directory = ($spec.root | path join $project)
      $rows = ($rows | append {
        id: $header.id
        cwd: $header.cwd
        parent: ($header | get -o parentSession)
        file: $file
        directory: $directory
        kind: $spec.kind
      })
    }
  }

  let inventory = $rows
  $inventory
  | each {|row|
    let file = $row.file
    let parent = ($row | get -o parent)
    let linked = (
      $inventory
      | where {|candidate|
        let candidate_file = $candidate.file
        (
          ($parent != null and ($candidate.id == $parent or $candidate_file == $parent))
          or (path-match ($candidate_file | str replace --regex '\.jsonl$' "") $file)
        )
      }
      | sort-by {|candidate| $candidate.file | str length }
      | last
    )

    let main = (
      $inventory
      | where {|candidate|
        $candidate.directory == $row.directory and ($candidate.file | path dirname) == $row.directory
      }
      | first
    )
    let owner = if $main == null { $row.cwd } else { $main.cwd }
    $row
    | upsert parent (if $linked == null { null } else { $linked.id })
    | upsert owner $owner
  }
}

export def recorded-paths []: nothing -> list<string> {
  let records = (session-records)
  ($records | get -o cwd) ++ ($records | get -o owner)
  | where {|path| valid-path $path }
  | uniq
}

export def scan []: nothing -> list<record> {
  let records = (session-records)
  let paths = (
    $records
    | get -o cwd
    | where {|path| valid-path $path }
    | uniq
  )

  $paths
  | each {|path|
    let files = ($records | where cwd == $path | get file | uniq)
    let last_used = (
      ls ...$files
      | get modified
      | math max
    )

    {
      assistant: "omp"
      path: $path
      sessions: ($files | length)
      last_used: $last_used
    }
  }
  | sort-by path
}

# --------------------------------------------------------------------------------------------------
# Move
# --------------------------------------------------------------------------------------------------

def remap-parent [content: string, new: string]: nothing -> string {
  $content
  | split row "\n"
  | each {|line|
    let header = try {
      $line | from json
    } catch {
      null
    }

    if ($header | get -o type) != "session" {
      return $line
    }
    let field = (
      $line
      | parse --regex '(?<prefix>"parentSession"\s*:\s*)(?<value>"(?:\\.|[^"\\])*")'
      | first
    )
    let original = ($field.prefix + $field.value)
    let mapped = ($field.prefix + ($new | to json --raw))
    $line | str replace $original $mapped
  }
  | str join "\n"
}

def session-actions [candidates: list<string>, old: string, new: string]: nothing -> list<record> {
  let records = (session-records)
  mut targets = []
  mut merges = []

  for path in $candidates {
    let mapped = (path-map $old $new $path)
    for spec in [
      {
        kind: "sessions"
        root: (session-root)
        from: $path
        to: $mapped
      }
      {
        kind: "archives"
        root: (archive-root)
        from: $path
        to: $mapped
      }
    ] {
      let source = ($spec.root | path join (session-encode-here $spec.from))
      let target = ($spec.root | path join (session-encode-here $spec.to))
      $merges = (
        $merges
        ++ (merge-actions "omp" $spec.kind $source $target $"merge ($spec.kind) directory")
      )
      if $source == $target { continue }
      $targets = (
        $targets
        ++ ($records | where {|row| path-match $source $row.file } | each {|row|
          {source_path: $row.file, target: (path-map $source $target $row.file)}
        })
      )
    }
  }

  let targets = $targets
  let parents = (
    $records
    | each {|row|
      let parent = (session-header $row.file | get -o parentSession)
      let target = ($targets | where source_path == $parent | first)
      if $target != null { {file: $row.file, parent: $target.target} }
    }
  )
  let session_files = (files-with-path $old [(session-root) (archive-root)])
  let edits = (
    $session_files ++ ($parents | get -o file)
    | uniq
    | each {|file|
      let parent = ($parents | where file == $file | first | get -o parent)
      let rewrite = {|content|
        let rewritten = (rewrite-text $content $old $new)
        if $parent == null { $rewritten } else { remap-parent $rewritten $parent }
      }
      edit-action "omp" "sessions" $file $rewrite "rewrite session paths"
    }
  )
  $edits ++ $merges
}

export def plan-move [old: string, new: string]: nothing -> list<record> {
  let recorded = (recorded-paths | where {|path| path-match $old $path })
  let candidates = ($recorded ++ [$old] | uniq)
  session-actions $candidates $old $new
}

# --------------------------------------------------------------------------------------------------
# Retirement
# --------------------------------------------------------------------------------------------------

export def plan-retire [
  old: string
  --exact
  --session-ids: list<string> = []
]: nothing -> list<record> {
  let records = (session-records)
  let selected = (select-sessions $records $old --exact=$exact --session-ids $session_ids)
  let session_files = (
    $selected
    | get file
    | uniq
  )

  let subtrees = (
    $session_files
    | each {|file| $file | str replace --regex '\.jsonl$' "" }
    | where {|path| $path | path exists }
  )

  $session_files ++ $subtrees
  | outermost-paths $in
  | each {|file| action "omp" "sessions" "delete" $file "retire session tree" }
}

# --------------------------------------------------------------------------------------------------
# Transfer
# --------------------------------------------------------------------------------------------------

export def export-bundle [
  old: string
  --exact
  --session-ids: list<string> = []
]: nothing -> record {
  let records = (session-records)
  let selected = (select-sessions $records $old --exact=$exact --session-ids $session_ids)
  mut files = []
  for row in $selected {
    let subtree = ($row.file | str replace --regex '\.jsonl$' "")
    for file in ([$row.file] ++ (files-under $subtree)) {
      let header = (session-header $file)
      $files = ($files | append {
        kind: $row.kind
        project: $row.owner
        name: ($file | path relative-to $row.directory)
        source: $file
        source_path: (if $header == null { null } else { $file })
        session: ($header | get -o id)
      })
    }
  }
  $files = ($files | uniq)

  {
    assistant: "omp"
    old: $old
    files: $files
    tables: []
  }
}

def artifact-target [file: record, targets: list<record>]: nothing -> string {
  if $file.existing { return $file.target }
  let owner = (
    $targets
    | where {|candidate|
      let stem = ($candidate.name | str replace --regex '\.jsonl$' "")
      (
        $candidate.header != null and $candidate.kind == $file.kind
        and $candidate.project == $file.project
        and ($file.name | str starts-with ($stem + "/"))
      )
    }
    | sort-by {|candidate| $candidate.name | str length } --reverse
    | first
  )

  if $owner == null { return $file.target }
  let source = ($owner.name | str replace --regex '\.jsonl$' "")
  let target = (artifact-target $owner $targets | str replace --regex '\.jsonl$' "")
  path-map $source $target $file.name
}

def mapped-parent [file: record, targets: list<record>, --remap]: nothing -> any {
  let parent = ($file.header | get -o parentSession)
  if not (valid-path $parent) { return null }
  let target = (
    $targets
    | where {|entry| $entry.source_path == $parent }
    | first
  )

  if $target == null or (not $remap and $target.target == $parent) {
    null
  } else {
    $target.target
  }
}

export def plan-import [bundle: record, --target: string]: nothing -> list<record> {
  let destination = $target
  let rewritten = if $destination == null {
    []
  } else {
    let sources = (
      $bundle.files
      | where {|file| $file.kind in ["sessions" "archives"] }
      | get -o bundle
    )
    files-with-path $bundle.old $sources
  }

  let local_inventory = (session-records)

  let planned = (
    $bundle.files
    | each {|file|
      let header = if $file.kind in ["sessions" "archives"] {
        session-header $file.bundle
      } else {
        null
      }

      let local = if $header == null {
        null
      } else {
        $local_inventory
        | where {|row|
          $row.id == $header.id
        }
        | first
      }

      let target = if $local != null {
        $local.file
      } else {
        let project = if $destination == null {
          $file.project
        } else {
          path-map $bundle.old $destination $file.project
        }

        match $file.kind {
          "sessions" => (session-root | path join (session-encode-here $project) $file.name)
          "archives" => (archive-root | path join (session-encode-here $project) $file.name)
          _ => {
            error make --unspanned {msg: $"Unknown OMP file kind ($file.kind)"}
          }
        }
      }

      $file | merge {
        header: $header
        existing: ($local != null)
        target: $target
      }
    }
  )

  let targets = ($planned | each {|file| $file | upsert target (artifact-target $file $planned) })

  mut actions = []

  for file in $targets {
    let parent = (mapped-parent $file $targets --remap=($destination != null))
    let content = if $file.header != null or $file.bundle in $rewritten {
      open --raw $file.bundle
    } else {
      null
    }

    let rewrite = $file.bundle in $rewritten and ($content | describe) == "string"
    let transform = if not $rewrite and $parent == null {
      null

    } else {
      {|content|
        let content = if $rewrite {
          rewrite-text $content $bundle.old $destination
        } else {
          $content
        }

        if $parent == null {
          $content
        } else {
          remap-parent $content $parent
        }
      }

    }

    let expected = if $file.header != null or $transform != null {
      if $transform == null {
        $content
      } else {
        do $transform $content
      }
    } else {
      null
    }

    if $file.header != null {
      let copies = (
        $local_inventory
        | where {|row| $row.id == $file.header.id }
      )

      for copy in $copies {
        if (open --raw $copy.file) != $expected {
          error make --unspanned {
            msg: $"Existing session ($file.header.id) differs from the bundle"
          }
        }
      }
    }

    if ($file.target | path exists) {
      let equal = if $expected == null {
        same-content $file.bundle $file.target
      } else {
        (open --raw $file.target) == $expected
      }
      if $equal { continue }
      error make --unspanned {
        msg: $"($file.target) already exists with content that differs from the bundle's copy"
        help: "Compare the two files, then reconcile the copies before importing again."
      }
    }

    let copy = (
      copy-action "omp" "files" $file.bundle $file.target "import file" --transform $transform
    )

    $actions = ($actions | append $copy)
  }

  $actions
}
