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
  path-map
  path-match
  valid-path
]
use ../lib/rewrite.nu [files-with-path json-value rewrite-text rg-lines]
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
  $env.PI_CODING_AGENT_DIR? | default --empty ($env.HOME | path join .omp agent)
}

def state-root []: nothing -> string {
  let base = ($env.XDG_STATE_HOME? | default --empty ($env.HOME | path join .local state))
  $base | path join omp
}

def session-root []: nothing -> string { agent-dir | path join sessions }

def archive-root []: nothing -> string { agent-dir | path join archive sessions }

def memory-root []: nothing -> string { state-root | path join memories }

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
    "-" + ($relative | str replace --all --regex '[/\\:]' '-')
  } else if $real == $tmp or (path-match $tmp $real) {
    let relative = if $real == $tmp {
      ""
    } else {
      $real | str substring (($tmp | str length) + 1)..
    }
    "-tmp-" + ($relative | str replace --all --regex '[/\\:]' '-')
  } else {
    let stripped = ($real | str replace --regex '^/' '')
    "--" + ($stripped | str replace --all --regex '[/\\:]' '-') + "--"
  }
}

export def session-encode-here [path: string]: nothing -> string {
  let tmp = ($env.TMPDIR? | default --empty "/tmp")
  session-encode $path $env.HOME $tmp
}

export def memory-encode [path: string]: nothing -> string {
  let stripped = (normalize-path $path | str replace --regex '^/' '')
  "--" + ($stripped | str replace --all --regex '[/\\:]' '-') + "--"
}

# --------------------------------------------------------------------------------------------------
# Scan
# --------------------------------------------------------------------------------------------------

# The cwd recorded in each session file's first record.
def session-cwds [roots: list<string>]: nothing -> list<string> {
  let existing = ($roots | where {|root| $root | path exists })
  if ($existing | is-empty) { return [] }

  rg-lines [-m1 -o --no-filename --no-messages -g '*.jsonl' '"cwd":"[^"]*"' ...$existing]
  | parse --regex '^"cwd":"(?<cwd>[^"]*)"$'
  | get cwd
  | each {|value| json-value $value }
}

export def recorded-paths []: nothing -> list<string> {
  let sessions = (session-cwds [(session-root) (archive-root)])

  let agent = (agent-dir)
  let history_db = ($agent | path join history.db)
  let history = if ($history_db | path exists) {
    let rows = (sqlite-rows $history_db "SELECT cwd FROM history WHERE cwd IS NOT NULL")
    let recaps = (sqlite-rows $history_db "SELECT cwd FROM session_recaps WHERE cwd IS NOT NULL")
    ($rows | get cwd) ++ ($recaps | get cwd)
  } else {
    []
  }

  let agent_db = ($agent | path join agent.db)
  let agent_paths = if ($agent_db | path exists) {
    let threads = (sqlite-rows $agent_db "SELECT cwd FROM threads WHERE cwd IS NOT NULL" | get cwd)
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
      ls ...$files | get modified | math max
    }
    {assistant: omp, path: $path, sessions: ($files | length), last_used: $last_used}
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
    | each {|file| edit-action omp sessions $file $rewrite "rewrite session cwd" }
  )

  for path in $candidates {
    let mapped = (path-map $old $new $path)
    for spec in [
      {kind: sessions, root: (session-root), from: $path, to: $mapped}
      {kind: archives, root: (archive-root), from: $path, to: $mapped}
    ] {
      let source = ($spec.root | path join (session-encode-here $spec.from))
      let target = ($spec.root | path join (session-encode-here $spec.to))
      $actions = (
        $actions
        ++ (merge-actions omp $spec.kind $source $target $"merge ($spec.kind) directory")
      )
    }
    let memory = (memory-root | path join (memory-encode $path))
    let moved_memory = (memory-root | path join (memory-encode $mapped))
    $actions = (
      $actions
      ++ (
        merge-actions omp memories $memory $moved_memory "merge memory directory"
        --prefer-destination
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
          + " WHERE " + (path-condition rollout_path [$from])
        )
      }
    }
    | compact
  )
  if ($statements | is-empty) { [] } else {
    [(sql-action omp agent $db $statements "rewrite rollout paths")]
  }
}

export def plan-move [old: string, new: string]: nothing -> list<record> {
  let recorded = (recorded-paths | where {|path| path-match $old $path })
  let candidates = ($recorded ++ [$old] | uniq)
  let agent = (agent-dir)
  let history_db = ($agent | path join history.db)
  let agent_db = ($agent | path join agent.db)

  let columns = [
    {db: $history_db, table: history, column: cwd}
    {db: $history_db, table: session_recaps, column: cwd}
    {db: $agent_db, table: threads, column: cwd}
    {db: $agent_db, table: jobs, column: job_key, prefix: "global:", collide: true}
  ]

  (
    (session-actions $candidates $old $new)
    ++ (column-actions omp $columns $old $new)
    ++ (rollout-actions $agent_db $old $new)
  )
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
      {kind: sessions, directory: (session-root | path join (session-encode-here $path))}
      {kind: archives, directory: (archive-root | path join (session-encode-here $path))}
      {kind: memories, directory: (memory-root | path join (memory-encode $path))}
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

      $actions = ($actions | append (action omp $spec.kind delete $directory "project state"))
    }
  }
  $actions
}

def history-deletions [db: string, paths: list<string>]: nothing -> list<record> {
  if not ($db | path exists) { return [] }

  let condition = (path-condition cwd $paths)
  let history = $"history WHERE cwd IS NOT NULL AND \(($condition)\)"
  let recaps = $"session_recaps WHERE \(($condition)\)"
  let counts = (
    sqlite-rows $db (
      $"SELECT \(SELECT count\(*\) FROM ($history)\) AS history,"
      + $" \(SELECT count\(*\) FROM ($recaps)\) AS recaps"
    )
    | get 0
  )
  let removed = (($counts.history | into int) + ($counts.recaps | into int))
  if $removed == 0 { return [] }

  mut statements = []
  if ($counts.history | into int) > 0 {
    let scope = $"SELECT session_id FROM ($history)"
    $statements = (
      $statements | append $"DELETE FROM session_titles WHERE session_id IN \(($scope)\)"
    )
    $statements = (
      $statements | append $"DELETE FROM session_recaps WHERE session_id IN \(($scope)\)"
    )
    $statements = (
      $statements | append $"DELETE FROM history WHERE cwd IS NOT NULL AND \(($condition)\)"
    )
    $statements = ($statements | append "INSERT INTO history_fts(history_fts) VALUES('rebuild')")
  }
  if ($counts.recaps | into int) > 0 {
    $statements = ($statements | append $"DELETE FROM session_recaps WHERE \(($condition)\)")
  }
  [(sql-action omp history $db $statements "delete history" --rows-first)]
}

def agent-deletions [db: string, paths: list<string>]: nothing -> list<record> {
  if not ($db | path exists) { return [] }

  let condition = (path-condition cwd $paths)
  let global = (path-condition job_key $paths --prefix "global:")
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
  [(sql-action omp agent $db $statements "delete threads and jobs" --rows-first)]
}

export def plan-prune [paths: list<string>]: nothing -> list<record> {
  let agent = (agent-dir)
  let live_paths = (recorded-paths | where {|path| (valid-path $path) and ($path | path exists) })

  (
    (directory-prune-actions $paths $live_paths)
    ++ (history-deletions ($agent | path join history.db) $paths)
    ++ (agent-deletions ($agent | path join agent.db) $paths)
  )
}

# --------------------------------------------------------------------------------------------------
# Transfer
# --------------------------------------------------------------------------------------------------

def export-files [candidates: list<string>]: nothing -> list<record> {
  mut files = []
  for path in $candidates {
    for spec in [
      {kind: sessions, root: (session-root), project: $path}
      {kind: archives, root: (archive-root), project: $path}
      {kind: memories, root: (memory-root), project: $path}
    ] {
      let source_root = if $spec.kind == "memories" {
        (memory-root | path join (memory-encode $path))
      } else {
        ($spec.root | path join (session-encode-here $path))
      }
      for file in (files-under $source_root) {
        let name = ($file | path relative-to $source_root)
        $files = ($files | append {
          kind: $spec.kind
          project: $path
          name: $name
          source: $file
        })
      }
    }
  }
  $files
}

def history-tables [db: string, old: string]: nothing -> list<record> {
  if not ($db | path exists) { return [] }
  let history = (
    sqlite-rows $db "SELECT * FROM history"
    | where {|row| path-match $old $row.cwd }
  )
  let recaps = (
    sqlite-rows $db "SELECT * FROM session_recaps"
    | where {|row| path-match $old $row.cwd }
  )
  let sessions = (
    ($history | get -o session_id | compact)
    ++ ($recaps | get -o session_id | compact)
  )
  let ids = ($sessions | uniq)
  let session_titles = if ($ids | is-empty) {
    []
  } else {
    sqlite-rows $db $"SELECT * FROM session_titles WHERE session_id IN \((sql-list $ids)\)"
  }

  [
    {
      db: history
      table: history
      columns: (table-columns $db history)
      rows: $history
      key: null
      natural: [prompt]
      drop: [id]
    }
    {
      db: history
      table: session_titles
      columns: (table-columns $db session_titles)
      rows: $session_titles
      key: [session_id]
      drop: []
    }
    {
      db: history
      table: session_recaps
      columns: (table-columns $db session_recaps)
      rows: $recaps
      key: null
      natural: [session_id created_at]
      drop: [id]
    }
  ]
}

def agent-tables [db: string, old: string]: nothing -> list<record> {
  if not ($db | path exists) { return [] }
  let threads = (
    sqlite-rows $db "SELECT * FROM threads"
    | where {|row| path-match $old $row.cwd }
  )
  let thread_ids = ($threads | get -o id)
  let stage1 = if ($thread_ids | is-not-empty) {
    sqlite-rows $db $"SELECT * FROM stage1_outputs WHERE thread_id IN \((sql-list $thread_ids)\)"
  } else {
    []
  }
  let jobs = (
    sqlite-rows $db "SELECT * FROM jobs WHERE job_key LIKE 'global:%'"
    | where {|row| path-match $old ($row.job_key | str substring 7..) }
  )

  [
    {
      db: agent
      table: threads
      columns: (table-columns $db threads)
      rows: $threads
      key: [id]
      drop: []
    }
    {
      db: agent
      table: stage1_outputs
      columns: (table-columns $db stage1_outputs)
      rows: $stage1
      key: [thread_id]
      drop: []
    }
    {
      db: agent
      table: jobs
      columns: (table-columns $db jobs)
      rows: $jobs
      key: [kind job_key]
      drop: []
    }
  ]
}

export def export-bundle [old: string]: nothing -> record {
  let recorded = (recorded-paths | where {|path| path-match $old $path })
  let candidates = ($recorded ++ [$old] | uniq)
  let agent = (agent-dir)

  {
    assistant: omp
    old: $old
    files: (export-files $candidates)
    tables: (
      (history-tables ($agent | path join history.db) $old)
      ++ (agent-tables ($agent | path join agent.db) $old)
    )
  }
}

export def plan-import [bundle: record]: nothing -> list<record> {
  let agent = (agent-dir)
  let history_db = ($agent | path join history.db)
  let agent_db = ($agent | path join agent.db)

  for spec in $bundle.tables {
    if ($spec.rows | is-empty) { continue }
    let db = match $spec.db {
      'history' => $history_db
      'agent' => $agent_db
    }
    let columns = ($spec.columns | where {|column| $column not-in $spec.drop })
    check-columns $db $spec.table $columns "OMP"
  }

  let bundle_sessions = (
    ((bundle-table $bundle threads).rows | get -o id | compact)
    ++ ((bundle-table $bundle history).rows | get -o session_id | compact)
    | uniq
  )

  let local_sessions = (
    (if ($agent_db | path exists) {
      sqlite-rows $agent_db "SELECT id FROM threads" | get -o id
    } else {
      []
    })
    ++ (if ($history_db | path exists) {
      sqlite-rows $history_db "SELECT session_id FROM history" | get -o session_id
    } else {
      []
    })
  )

  let session_dirs = (
    [(session-root) (archive-root)]
    | each {|root|
      if ($root | path exists) { ls $root | where type == "dir" | get name } else { [] }
    }
    | flatten
  )
  let session_files = ($bundle.files | where {|file| $file.kind in [sessions archives] })

  let already_imported = (
    ($bundle_sessions | all {|id| $id in $local_sessions })
    and ($session_files | all {|file|
      $session_dirs | any {|dir| ($dir | path join $file.name) | path exists }
    })
  )
  if (($bundle_sessions | is-not-empty) or ($session_files | is-not-empty)) and $already_imported {
    return []
  }

  mut actions = []
  mut rollout_targets = []
  let memory_root_dir = (memory-root)
  let memories = if ($memory_root_dir | path exists) {
    ls $memory_root_dir
    | where type == "dir"
    | get name
    | each {|dir| files-under $dir }
    | flatten
  } else {
    []
  }

  for file in $bundle.files {
    let target = match $file.kind {
      'sessions' => (session-root | path join (session-encode-here $file.project) $file.name)
      'archives' => (archive-root | path join (session-encode-here $file.project) $file.name)
      'memories' => (memory-root | path join (memory-encode $file.project) $file.name)
      _ => {
        error make --unspanned {
          msg: $"Unknown OMP file kind ($file.kind)"
          help: "Rerun with the version that exported this bundle."
        }
      }
    }
    if ($file.kind in [sessions archives]) {
      let entry = {kind: $file.kind, name: ($file.name | path basename), target: $target}
      $rollout_targets = ($rollout_targets | append $entry)
      let imported = ($session_dirs | any {|dir| ($dir | path join $file.name) | path exists })
      if $imported { continue }
    }
    if ($target | path exists) {
      if (same-content $file.bundle $target) { continue }
      error make --unspanned {
        msg: $"($target) already exists with content that differs from the bundle's copy"
        help: "Compare the two files. Delete or rename the local file if the bundle's copy should win, then rerun the import."
      }
    }
    if $file.kind == memories {
      let identical = (
        $memories
        | any {|path|
          let same_name = (($path | path basename) == ($file.name | path basename))
          $same_name and (same-content $file.bundle $path)
        }
      )
      if $identical { continue }
    }
    let write = (copy-action omp files $file.bundle $target "import file")
    $actions = ($actions | append $write)
  }
  let rollout_map = $rollout_targets

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
          $row | upsert rollout_path (rollout-target $row.rollout_path $rollout_map)
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
    let load = (sql-action omp history $history_db $history_statements "import history")
    $actions = ($actions | append $load)
  }
  if ($agent_statements | is-not-empty) {
    let load = (sql-action omp agent $agent_db $agent_statements "import agent")
    $actions = ($actions | append $load)
  }
  $actions
}

def rollout-target [value: any, targets: list<record>]: nothing -> any {
  if ($value | describe) != "string" { return $value }

  let kind = if ($value | str contains "/archive/sessions/") { "archives" } else { "sessions" }
  let name = ($value | path basename)
  let found = (
    $targets
    | where {|target| $target.kind == $kind and $target.name == $name }
    | get -o 0
  )
  if $found == null { $value } else { $found.target }
}
