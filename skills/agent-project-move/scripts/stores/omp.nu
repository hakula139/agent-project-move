# ==================================================================================================
# Agent Project Move: OMP
# ==================================================================================================
# OMP state, including both session directory encodings.
# ==================================================================================================

use ../lib/actions.nu [
  action
  column-actions
  copy-action
  edit-action
  merge-actions
  same-content
  sql-action
]
use ../lib/bundle.nu [bundle-table]
use ../lib/paths.nu [
  files-under
  match-any
  normalize-path
  outermost-paths
  path-map
  path-match
  valid-path
]
use ../lib/rewrite.nu [files-with-path json-value rewrite-text rg-lines]
use ../lib/selection.nu [select-sessions]
use ../lib/sqlite.nu [
  check-columns
  path-condition
  sql-list
  sql-quote
  sqlite-insert-absent
  sqlite-insert-if-new
  sqlite-rows
  table-columns
]

# --------------------------------------------------------------------------------------------------
# Locations
# --------------------------------------------------------------------------------------------------

def agent-dir []: nothing -> string {
  $env.PI_CODING_AGENT_DIR? | default --empty ($env.HOME | path join ".omp/agent")
}

def state-root []: nothing -> string {
  let base = ($env.XDG_STATE_HOME? | default --empty ($env.HOME | path join ".local/state"))
  $base | path join "omp"
}

def session-root []: nothing -> string { agent-dir | path join "sessions" }

def archive-root []: nothing -> string { agent-dir | path join "archive/sessions" }

def memory-root []: nothing -> string { state-root | path join "memories" }

# Resolve a path without requiring it to exist.
def resolved-path [path: string]: nothing -> string {
  ^realpath -m $path | str trim
}

# --------------------------------------------------------------------------------------------------
# Encodings
# --------------------------------------------------------------------------------------------------

# Mirrors OMP: session directories resolve the cwd, home, and temp dir through realpath, while
# memory directories encode the raw cwd.
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
    "--" + ($stripped | str replace --all --regex '[/\\:]' "-") + "--"
  }
}

export def session-encode-here [path: string]: nothing -> string {
  let tmp = ($env.TMPDIR? | default --empty "/tmp")
  session-encode $path $env.HOME $tmp
}

export def memory-encode [path: string]: nothing -> string {
  let stripped = (normalize-path $path | str replace --regex "^/" "")
  "--" + ($stripped | str replace --all --regex '[/\\:]' "-") + "--"
}

# --------------------------------------------------------------------------------------------------
# Scan
# --------------------------------------------------------------------------------------------------

def session-cwds [roots: list<string>]: nothing -> list<string> {
  let existing = ($roots | where {|root| $root | path exists })
  if ($existing | is-empty) { return [] }

  rg-lines ["-m1" "-o" "--no-filename" "--no-messages" "-g" "*.jsonl" '"cwd":"[^"]*"' ...$existing]
  | parse --regex '^"cwd":"(?<cwd>[^"]*)"$'
  | get cwd
  | each {|value| json-value $value }
}

export def recorded-paths []: nothing -> list<string> {
  let sessions = (session-cwds [(session-root) (archive-root)])

  let agent = (agent-dir)
  let history_db = ($agent | path join "history.db")
  let history = if ($history_db | path exists) {
    let rows = (sqlite-rows $history_db "SELECT cwd FROM history WHERE cwd IS NOT NULL")
    let recaps = (sqlite-rows $history_db "SELECT cwd FROM session_recaps WHERE cwd IS NOT NULL")
    ($rows | get cwd) ++ ($recaps | get cwd)
  } else {
    []
  }

  let agent_db = ($agent | path join "agent.db")
  let agent_paths = if ($agent_db | path exists) {
    let threads = (
      sqlite-rows $agent_db "SELECT cwd FROM threads WHERE cwd IS NOT NULL"
      | get cwd
    )

    let jobs = (
      sqlite-rows $agent_db "SELECT job_key FROM jobs WHERE job_key LIKE 'global:%'"
      | get job_key
      | each {|key| $key | str substring 7.. }
    )

    $threads ++ $jobs

  } else {
    []
  }

  $sessions
  | append $history
  | append $agent_paths
  | where {|path| valid-path $path }
  | uniq
}

export def scan []: nothing -> list<record> {
  let paths = (recorded-paths)
  $paths
  | each {|path|
    let dir = (session-root | path join (session-encode-here $path))
    let files = (files-under $dir | where {|file| $file | str ends-with ".jsonl" })
    let last_used = if ($files | is-empty) {
      null
    } else {
      ls ...$files
      | get modified
      | math max
    }

    {assistant: "omp", path: $path, sessions: ($files | length), last_used: $last_used}
  }
  | sort-by path
}

# --------------------------------------------------------------------------------------------------
# Move
# --------------------------------------------------------------------------------------------------

def session-actions [candidates: list<string>, old: string, new: string]: nothing -> list<record> {
  let session_files = (files-with-path $old [(session-root) (archive-root)])
  let rewrite = {|content| rewrite-text $content $old $new }
  mut actions = (
    $session_files
    | each {|file| edit-action "omp" "sessions" $file $rewrite "rewrite session cwd" }
  )

  for path in $candidates {
    let mapped = (path-map $old $new $path)
    for spec in [
      {kind: "sessions", root: (session-root), from: $path, to: $mapped}
      {kind: "archives", root: (archive-root), from: $path, to: $mapped}
    ] {
      let source = ($spec.root | path join (session-encode-here $spec.from))
      let target = ($spec.root | path join (session-encode-here $spec.to))
      $actions = (
        $actions
        ++ (merge-actions "omp" $spec.kind $source $target $"merge ($spec.kind) directory")
      )
    }

    let memory = (memory-root | path join (memory-encode $path))
    let moved_memory = (memory-root | path join (memory-encode $mapped))
    let description = "merge memory directory"
    $actions = (
      $actions
      ++ (
        merge-actions "omp" "memories" $memory $moved_memory $description --prefer-destination
      )
    )
  }
  $actions
}

def rollout-actions [db: string, old: string, new: string]: nothing -> list<record> {
  if not ($db | path exists) { return [] }

  let project_paths = (
    sqlite-rows $db "SELECT DISTINCT cwd FROM threads"
    | where {|row| path-match $old $row.cwd }
    | get cwd
  )

  let statements = (
    $project_paths
    | each {|path|
      let from = (session-root | path join (session-encode-here $path))
      let to = (session-root | path join (session-encode-here (path-map $old $new $path)))
      if $from == $to {
        null
      } else {
        let value = (
          (sql-quote $to)
          + " || substr(rollout_path, length(" + (sql-quote $from) + ") + 1)"
        )
        (
          "UPDATE threads SET rollout_path = " + $value
          + " WHERE " + (path-condition "rollout_path" [$from])
        )
      }
    }
    | compact
  )

  if ($statements | is-empty) {
    []
  } else {
    [(sql-action "omp" "agent" $db $statements "rewrite rollout paths")]
  }
}

export def plan-move [old: string, new: string]: nothing -> list<record> {
  let recorded = (recorded-paths | where {|path| path-match $old $path })
  let candidates = ($recorded ++ [$old] | uniq)
  let agent = (agent-dir)
  let history_db = ($agent | path join "history.db")
  let agent_db = ($agent | path join "agent.db")

  let columns = [
    {db: $history_db, table: "history", column: "cwd"}
    {db: $history_db, table: "session_recaps", column: "cwd"}
    {db: $agent_db, table: "threads", column: "cwd"}
    {db: $agent_db, table: "jobs", column: "job_key", prefix: "global:", collide: true}
  ]

  (
    (session-actions $candidates $old $new)
    ++ (column-actions "omp" $columns $old $new)
    ++ (rollout-actions $agent_db $old $new)
  )
}

# --------------------------------------------------------------------------------------------------
# Session selection
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
    {kind: "sessions", root: (session-root)}
    {kind: "archives", root: (archive-root)}
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

  let agent = (agent-dir)
  for spec in [
    {db: ($agent | path join "agent.db"), table: "threads", key: "id"}
    {db: ($agent | path join "history.db"), table: "history", key: "session_id"}
    {db: ($agent | path join "history.db"), table: "session_recaps", key: "session_id"}
  ] {
    if not ($spec.db | path exists) { continue }
    let records = (sqlite-rows $spec.db $"SELECT * FROM ($spec.table)")
    let sessions = (
      $records
      | each {|row|
        {id: ($row | get $spec.key), cwd: $row.cwd, parent: ($row | get -o parent_thread_id)}
      }
    )
    $rows = ($rows ++ $sessions)
  }

  let inventory = $rows
  $inventory
  | each {|row|
    let file = ($row | get -o file)
    let parent = ($row | get -o parent)
    let linked = (
      $inventory
      | where {|candidate|
        let candidate_file = ($candidate | get -o file)
        (
          ($parent != null and ($candidate.id == $parent or $candidate_file == $parent))
          or ($file != null and $candidate_file != null and (
            path-match ($candidate_file | str replace --regex '\.jsonl$' "") $file
          ))
        )
      }
      | sort-by {|candidate|
        $candidate
        | get -o file
        | default ""
        | str length
      }
      | last
    )

    let owner = if $file == null {
      $row.cwd

    } else {
      let main = (
        $inventory
        | where {|candidate|
          let directory = (
            $candidate
            | get -o file
            | default ""
            | path dirname
          )

          (
            ($candidate | get -o directory) == $row.directory
            and $directory == $row.directory
          )
        }
        | first
      )

      if $main == null { $row.cwd } else { $main.cwd }
    }
    $row
    | upsert parent (if $linked == null { null } else { $linked.id })
    | upsert owner $owner
  }
}

# --------------------------------------------------------------------------------------------------
# Prune
# --------------------------------------------------------------------------------------------------

def directory-prune-actions [
  paths: list<string>
  live_paths: list<string>
]: nothing -> list<record> {
  mut actions = []
  for path in ($paths | uniq) {
    for spec in [
      {kind: "sessions", directory: (session-root | path join (session-encode-here $path))}
      {kind: "archives", directory: (archive-root | path join (session-encode-here $path))}
      {kind: "memories", directory: (memory-root | path join (memory-encode $path))}
    ] {
      let directory = $spec.directory
      if not ($directory | path exists) { continue }

      if $spec.kind == "memories" {
        let collisions = (
          $live_paths
          | where {|live| (memory-encode $live) == ($directory | path basename) }
        )

        if ($collisions | is-not-empty) {
          print $"Skipping ($directory): a live path encodes to the same name"
          continue
        }

      } else {
        let cwds = (session-cwds [$directory] | uniq)
        if ($cwds | is-not-empty) and (not ($cwds | all {|cwd| match-any $paths $cwd })) {
          print $"Skipping ($directory): holds a session outside the pruned paths"
          continue
        }
      }

      $actions = ($actions | append (action "omp" $spec.kind "delete" $directory "project state"))
    }
  }
  $actions
}

def history-deletions [
  db: string
  ids: list<string>
  --metadata-paths: list<string> = []
]: nothing -> list<record> {
  if not ($db | path exists) { return [] }
  let sessions = if ($ids | is-empty) {
    "0"
  } else {
    $"session_id IN \((sql-list $ids)\)"
  }

  let metadata = if ($metadata_paths | is-empty) {
    "0"
  } else {
    $"session_id IS NULL AND cwd IN \((sql-list $metadata_paths)\)"
  }

  let condition = $"\(($sessions)\) OR \(($metadata)\)"
  let history = $"history WHERE ($condition)"
  let recaps = $"session_recaps WHERE \(($condition)\)"
  let counts = (
    sqlite-rows $db (
      $"SELECT \(SELECT count\(*\) FROM ($history)\) AS history,"
      + $" \(SELECT count\(*\) FROM ($recaps)\) AS recaps,"
      + $" \(SELECT count\(*\) FROM session_titles WHERE ($sessions)\) AS titles"
    )
    | get 0
  )

  let removed = (
    ($counts.history | into int) + ($counts.recaps | into int) + ($counts.titles | into int)
  )

  if $removed == 0 { return [] }

  mut statements = []
  if ($ids | is-not-empty) {
    $statements = (
      $statements | append $"DELETE FROM session_titles WHERE session_id IN \((sql-list $ids)\)"
    )
  }

  if ($counts.recaps | into int) > 0 {
    $statements = ($statements | append $"DELETE FROM session_recaps WHERE \(($condition)\)")
  }

  if ($counts.history | into int) > 0 {
    $statements = (
      $statements | append $"DELETE FROM history WHERE \(($condition)\)"
    )
    $statements = ($statements | append "INSERT INTO history_fts(history_fts) VALUES('rebuild')")
  }

  [(sql-action "omp" "history" $db $statements "delete history" --rows-first)]
}

def agent-deletions [db: string, ids: list<string>, paths: list<string>]: nothing -> list<record> {
  if not ($db | path exists) { return [] }

  let condition = if ($ids | is-empty) {
    "0"
  } else {
    $"id IN \((sql-list $ids)\)"
  }

  let global = if ($paths | is-empty) {
    "0"
  } else {
    let keys = ($paths | each {|path| "global:" + $path })
    $"job_key IN \((sql-list $keys)\)"
  }

  let counts = (
    sqlite-rows $db (
      $"SELECT \(SELECT count\(*\) FROM threads WHERE ($condition)\) AS threads,"
      + $" \(SELECT count\(*\) FROM jobs WHERE ($global)\) AS jobs"
    )
    | get 0
  )

  let thread_count = ($counts.threads | into int)
  let job_count = ($counts.jobs | into int)
  if ($thread_count + $job_count) == 0 { return [] }

  mut statements = []
  if $thread_count > 0 {
    let scope = $"SELECT id FROM threads WHERE ($condition)"
    $statements = (
      $statements | append $"DELETE FROM stage1_outputs WHERE thread_id IN \(($scope)\)"
    )
    $statements = ($statements | append $"DELETE FROM jobs WHERE job_key IN \(($scope)\)")
    $statements = ($statements | append $"DELETE FROM threads WHERE ($condition)")
  }
  if $job_count > 0 {
    $statements = ($statements | append $"DELETE FROM jobs WHERE ($global)")
  }
  [(sql-action "omp" "agent" $db $statements "delete threads and jobs" --rows-first)]
}

export def plan-prune [paths: list<string>]: nothing -> list<record> {
  let agent = (agent-dir)
  let recorded = (recorded-paths)
  let live_paths = ($recorded | where {|path| (valid-path $path) and ($path | path exists) })
  let ids = (
    session-records
    | where {|row| match-any $paths $row.cwd }
    | get -o id
    | compact
    | uniq
  )
  let metadata = ($recorded | where {|path| match-any $paths $path })

  (
    (directory-prune-actions $paths $live_paths)
    ++ (history-deletions ($agent | path join "history.db") $ids --metadata-paths $metadata)
    ++ (agent-deletions ($agent | path join "agent.db") $ids $metadata)
  )
}

export def plan-retire [
  old: string
  --exact
  --session-ids: list<string> = []
]: nothing -> list<record> {
  let records = (session-records)
  let selected = (select-sessions $records $old --exact=$exact --session-ids $session_ids)
  let ids = (
    $selected
    | get -o id
    | compact
    | uniq
  )
  if ($ids | is-empty) { return [] }

  let remaining = ($records | where {|row| $row.id not-in $ids })
  let paths = (
    ($selected | get -o cwd) ++ ($selected | get -o owner)
    | uniq
    | where {|cwd| valid-path $cwd }
    | where {|cwd| not ($remaining | any {|row| $row.cwd == $cwd or $row.owner == $cwd }) }
  )
  let session_files = (
    $selected
    | where {|row| ($row | get -o file) != null }
    | get file
    | uniq
  )

  let subtrees = (
    $session_files
    | each {|file| $file | str replace --regex '\.jsonl$' "" }
    | where {|path| $path | path exists }
  )

  mut actions = (
    $session_files ++ $subtrees
    | outermost-paths $in
    | each {|file| action "omp" "sessions" "delete" $file "retire session tree" }
  )
  for path in $paths {
    let memory = (memory-root | path join (memory-encode $path))
    let shared = (
      $remaining
      | any {|row|
        (valid-path $row.cwd) and ((memory-encode $row.cwd) == (memory-encode $path))
      }
    )

    if ($memory | path exists) and not $shared {
      let remove = (action "omp" "memories" "delete" $memory "unreferenced memory")
      $actions = ($actions | append $remove)
    }
  }

  let agent = (agent-dir)
  (
    $actions
    ++ (history-deletions ($agent | path join "history.db") $ids)
    ++ (agent-deletions ($agent | path join "agent.db") $ids $paths)
  )
}

# --------------------------------------------------------------------------------------------------
# Transfer
# --------------------------------------------------------------------------------------------------

def history-tables [
  db: string
  ids: list<string>
  --metadata-paths: list<string> = []
]: nothing -> list<record> {
  if not ($db | path exists) { return [] }
  let history = (
    sqlite-rows $db "SELECT * FROM history"
    | where {|row|
      ($row.session_id in $ids) or ($row.session_id == null and $row.cwd in $metadata_paths)
    }
  )

  let recaps = (
    sqlite-rows $db "SELECT * FROM session_recaps"
    | where {|row|
      ($row.session_id in $ids) or ($row.session_id == null and $row.cwd in $metadata_paths)
    }
  )

  let session_titles = if ($ids | is-empty) {
    []
  } else {
    sqlite-rows $db $"SELECT * FROM session_titles WHERE session_id IN \((sql-list $ids)\)"
  }

  [
    {db: "history", table: "history", columns: (table-columns $db "history"), rows: $history, key: null, natural: ["prompt"], drop: ["id"]}
    {db: "history", table: "session_titles", columns: (table-columns $db "session_titles"), rows: $session_titles, key: ["session_id"], drop: []}
    {db: "history", table: "session_recaps", columns: (table-columns $db "session_recaps"), rows: $recaps, key: null, natural: ["session_id" "created_at"], drop: ["id"]}
  ]
}

def agent-tables [
  db: string
  ids: list<string>
  paths: list<string>
]: nothing -> list<record> {
  if not ($db | path exists) { return [] }
  let threads = (
    sqlite-rows $db "SELECT * FROM threads"
    | where {|row|
      $row.id in $ids
    }
  )

  let thread_ids = ($threads | get -o id)

  let stage1 = if ($thread_ids | is-not-empty) {
    sqlite-rows $db $"SELECT * FROM stage1_outputs WHERE thread_id IN \((sql-list $thread_ids)\)"
  } else {
    []
  }

  let jobs = (
    sqlite-rows $db "SELECT * FROM jobs"
    | where {|row|
      ($row.job_key in $ids) or ($paths | any {|path| $row.job_key == ("global:" + $path) })
    }
  )

  [
    {db: "agent", table: "threads", columns: (table-columns $db "threads"), rows: $threads, key: ["id"], drop: []}
    {db: "agent", table: "stage1_outputs", columns: (table-columns $db "stage1_outputs"), rows: $stage1, key: ["thread_id"], drop: []}
    {db: "agent", table: "jobs", columns: (table-columns $db "jobs"), rows: $jobs, key: ["kind" "job_key"], drop: []}
  ]
}

export def export-bundle [
  old: string
  --exact
  --session-ids: list<string> = []
]: nothing -> record {
  let records = (session-records)
  let selected = (select-sessions $records $old --exact=$exact --session-ids $session_ids)
  let ids = (
    $selected
    | get -o id
    | compact
    | uniq
  )
  let owned = (
    ($selected | get -o owner) ++ ($selected | get -o cwd)
    | where {|path| valid-path $path }
  )

  let paths = if ($session_ids | is-not-empty) {
    $owned | uniq
  } else {
    let recorded = (
      recorded-paths
      | where {|path|
        if $exact {
          $path == $old
        } else {
          path-match $old $path
        }
      }
    )
    $owned ++ $recorded ++ [$old]
    | uniq
  }

  let agent = (agent-dir)
  let history_paths = if ($session_ids | is-empty) { $paths } else { [] }
  let history = (
    history-tables ($agent | path join "history.db") $ids --metadata-paths $history_paths
  )
  let tables = ($history ++ (agent-tables ($agent | path join "agent.db") $ids $paths))

  mut files = []
  for row in ($selected | where {|row| ($row | get -o file) != null }) {
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

  for path in $paths {
    let memory = (memory-root | path join (memory-encode $path))
    for file in (files-under $memory) {
      $files = ($files | append {
        kind: "memories"
        project: $path
        name: ($file | path relative-to $memory)
        source: $file
      })
    }
  }

  {assistant: "omp", old: $old, files: $files, tables: $tables}
}

def artifact-target [file: record, targets: list<record>]: nothing -> string {
  if $file.existing or $file.kind not-in ["sessions" "archives"] { return $file.target }
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

def mapped-parent [file: record, targets: list<record>]: nothing -> any {
  let parent = ($file.header | get -o parentSession)
  if not (valid-path $parent) { return null }
  let target = (
    $targets
    | where {|entry| $entry.source_path == $parent }
    | first

  )
  if $target == null or $target.target == $parent {
    null
  } else {
    {old: $parent, new: $target.target}
  }
}

def remap-parent [content: string, old: string, new: string]: nothing -> string {
  $content
  | split row "\n"
  | each {|line|
    let header = try {
      $line | from json
    } catch {
      null
    }

    if ($header | get -o type) != "session" or ($header | get -o parentSession) != $old {
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

def rollout-target [id: string, value: any, targets: list<record>]: nothing -> any {
  if ($value | describe) != "string" { return $value }

  let found = (
    $targets
    | where {|target| $target.id == $id }
    | get -o 0
  )
  if $found == null { $value } else { $found.target }
}

export def plan-import [bundle: record]: nothing -> list<record> {
  let agent = (agent-dir)
  let history_db = ($agent | path join "history.db")
  let agent_db = ($agent | path join "agent.db")

  for spec in $bundle.tables {
    if ($spec.rows | is-empty) { continue }
    let db = match $spec.db {
      "history" => $history_db
      "agent" => $agent_db
    }
    let columns = ($spec.columns | where {|column| $column not-in $spec.drop })
    check-columns $db $spec.table $columns "OMP"
  }

  let thread_ids = (
    (bundle-table $bundle "threads").rows
    | get -o id
    | compact
  )
  let history_ids = (
    (bundle-table $bundle "history").rows
    | get -o session_id
    | compact
  )
  let bundle_sessions = (
    $thread_ids ++ $history_ids
    | uniq
  )

  let local_sessions = (
    (if ($agent_db | path exists) {
      sqlite-rows $agent_db "SELECT id FROM threads"
      | get -o id
    } else {
      []
    })
    ++ (if ($history_db | path exists) {
      sqlite-rows $history_db "SELECT session_id FROM history"
      | get -o session_id
    } else {
      []
    })
  )

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
          $row.id == $header.id and ($row | get -o file) != null
        }
        | first
      }

      let target = if $local != null {
        $local.file
      } else {
        match $file.kind {
          "sessions" => (session-root | path join (session-encode-here $file.project) $file.name)
          "archives" => (archive-root | path join (session-encode-here $file.project) $file.name)
          "memories" => (memory-root | path join (memory-encode $file.project) $file.name)
          _ => {
            error make --unspanned {msg: $"Unknown OMP file kind ($file.kind)"}
          }
        }
      }

      let thread = if $header == null {
        null
      } else {
        (bundle-table $bundle "threads").rows
        | where id == $header.id
        | first
      }

      $file | merge {
        header: $header
        existing: ($local != null)
        target: $target
        source_path: ($file | get -o source_path | default ($thread | get -o rollout_path))
      }
    }
  )

  let targets = ($planned | each {|file| $file | upsert target (artifact-target $file $planned) })

  let already_imported = (
    ($bundle_sessions | all {|id| $id in $local_sessions })
    and (
      $targets
      | where {|file| $file.kind in ["sessions" "archives"] }
      | all {|file| $file.target | path exists }
    )
    and (($bundle_sessions | is-not-empty) or ($targets | any {|file| $file.header != null }))
  )

  mut actions = []
  let memories = (files-under (memory-root))

  for file in $targets {
    let parent = (mapped-parent $file $targets)
    let expected = if $file.header == null {
      null
    } else {
      let content = (open --raw $file.bundle)
      if $parent == null {
        $content
      } else {
        remap-parent $content $parent.old $parent.new
      }
    }

    if $file.header != null {
      let copies = (
        $local_inventory
        | where {|row| $row.id == $file.header.id and ($row | get -o file) != null }
      )

      for copy in $copies {
        if (open --raw $copy.file) != $expected {
          error make --unspanned {
            msg: $"Existing session ($file.header.id) differs from the bundle"
          }
        }
      }
      if ($copies | is-empty) and ($file.header.id in $local_sessions) {
        error make --unspanned {
          msg: $"Existing session ($file.header.id) has no readable transcript"
        }
      }
    }

    if $already_imported and $file.kind == "memories" { continue }
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

    if $file.kind == "memories" {
      let identical = (
        $memories
        | any {|path|
          (
            (($path | path basename) == ($file.name | path basename))
            and (same-content $file.bundle $path)
          )
        }
      )

      if $identical { continue }
    }

    let copy = if $parent == null {
      copy-action "omp" "files" $file.bundle $file.target "import file"
    } else {
      copy-action "omp" "files" $file.bundle $file.target "import session" --transform {|content|
        remap-parent $content $parent.old $parent.new
      }
    }

    $actions = ($actions | append $copy)
  }

  let rollout_map = (
    $targets
    | where {|file| $file.header != null }
    | each {|file| {id: $file.header.id, target: $file.target} }
  )

  mut history_statements = []
  mut agent_statements = []
  for spec in $bundle.tables {
    if ($spec.rows | is-empty) { continue }
    let columns = ($spec.columns | where {|column| $column not-in $spec.drop })
    let rows = (
      $spec.rows
      | each {|row|
        let row = ($row | reject --optional ...$spec.drop)
        if $spec.table == "threads" {
          $row | upsert rollout_path (rollout-target $row.id $row.rollout_path $rollout_map)
        } else {
          $row
        }
      }
    )
    let natural = ($spec | get -o natural | default [])
    let statements = (
      $rows
      | each {|row|
        if ($natural | is-not-empty) {
          sqlite-insert-absent $spec.table $columns $natural $row
        } else {
          sqlite-insert-if-new $spec.table $columns $row
        }
      }
    )
    if $spec.db == "history" {
      $history_statements = ($history_statements ++ $statements)
    } else {
      $agent_statements = ($agent_statements ++ $statements)
    }
  }

  if ($history_statements | is-not-empty) {
    let load = (sql-action "omp" "history" $history_db $history_statements "import history")
    $actions = ($actions | append $load)
  }

  if ($agent_statements | is-not-empty) {
    let load = (sql-action "omp" "agent" $agent_db $agent_statements "import agent")
    $actions = ($actions | append $load)
  }

  $actions
}
