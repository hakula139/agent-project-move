# ==================================================================================================
# Agent Project Move: Codex
# ==================================================================================================
# Codex state, including rollouts and SQLite databases.
# ==================================================================================================

use ../lib/actions.nu [
  action
  column-actions
  copy-action
  decompress-file
  edit-action
  sql-action
]
use ../lib/bundle.nu [bundle-table]
use ../lib/paths.nu [path-map valid-path]
use ../lib/rewrite.nu [files-with-path rewrite-text]
use ../lib/selection.nu [select-sessions]
use ../lib/sqlite.nu [
  check-columns
  latest-db
  sql-list
  sqlite-insert-if-new
  sqlite-rows
  table-columns
]

# The projection state goes first, since its AFTER DELETE trigger clears thread_realtime_items.
const PROJECTION_TABLES = ["thread_history_projection_state" "thread_turns" "thread_items"]

# --------------------------------------------------------------------------------------------------
# Locations
# --------------------------------------------------------------------------------------------------

def root []: nothing -> string {
  $env.CODEX_HOME? | default --empty ($env.HOME | path join ".codex")
}

# The state database, or null before Codex has created one.
def state-db []: nothing -> any {
  latest-db (root | path join "state_*.sqlite") "threads"
}

# The thread history database, or null before Codex has created one.
def history-db []: nothing -> any {
  latest-db (root | path join "thread_history_*.sqlite") "thread_items"
}

def plain-rollout-path [path: string]: nothing -> string {
  if ($path | str ends-with ".zst") {
    let end = (($path | str length) - 4)
    $path | str substring 0..<$end
  } else {
    $path
  }
}

def rollout-file [path: string]: nothing -> any {
  let plain = (plain-rollout-path $path)
  if ($plain | path exists) {
    return {
      file: $plain
      compressed: false
    }
  }

  let compressed = if $plain == $path {
    $path + ".zst"
  } else {
    $path
  }
  if ($compressed | path exists) {
    return {
      file: $compressed
      compressed: true
    }
  }
  null
}

# --------------------------------------------------------------------------------------------------
# Scan
# --------------------------------------------------------------------------------------------------

# The store records paths only through its scan rows.
export def recorded-paths []: nothing -> list<string> { [] }

export def scan []: nothing -> list<record> {
  let db = (state-db)
  if $db == null { return [] }

  let sessions = "count(*) AS sessions"
  let last_used = "max(coalesce(updated_at_ms, updated_at * 1000)) AS last_used"
  let query = $"SELECT cwd, ($sessions), ($last_used) FROM threads GROUP BY cwd"
  sqlite-rows $db $query
  | where {|row| valid-path $row.cwd }
  | each {|row|
    {
      assistant: "codex"
      path: $row.cwd
      sessions: ($row.sessions | into int)
      last_used: (
        if $row.last_used == null {
          null
        } else {
          $row.last_used * 1000000 | into datetime
        }
      )
    }
  }
}

# --------------------------------------------------------------------------------------------------
# Move
# --------------------------------------------------------------------------------------------------

def projection-actions [db: any, ids: list<string>]: nothing -> list<record> {
  if ($db == null) or ($ids | is-empty) { return [] }

  let id_list = (sql-list $ids)
  $PROJECTION_TABLES
  | each {|table|
    let statement = $"DELETE FROM ($table) WHERE thread_id IN \(($id_list)\)"
    sql-action "codex" "thread-history" $db [$statement] $"reset ($table)" --derived
  }
}

export def plan-move [old: string, new: string]: nothing -> list<record> {
  let state = (state-db)
  if $state == null { return [] }

  let home = (root)
  let rewrite = {|content| rewrite-text $content $old $new }
  let rollouts = (files-with-path $old [
    ($home | path join "sessions")
    ($home | path join "archived_sessions")
  ])

  let threads = (sqlite-rows $state "SELECT * FROM threads")
  let edited_ids = (
    $threads
    | where {|row|
      let path = ($row | get -o rollout_path)
      (
        (($path | describe) == "string")
        and ($rollouts | any {|file| (plain-rollout-path $file) == (plain-rollout-path $path)})
      )
    }
    | get id
  )

  mut actions = (
    column-actions "codex" [
      {
        db: $state
        table: "threads"
        column: "cwd"
      }
      {
        db: $state
        table: "threads"
        column: "sandbox_policy"
        json: true
      }
    ] $old $new
  )

  for file in $rollouts {
    $actions = ($actions | append (edit-action "codex" "rollouts" $file $rewrite "rewrite cwd"))
  }

  $actions ++ (projection-actions (history-db) $edited_ids)
}

# --------------------------------------------------------------------------------------------------
# Session selection
# --------------------------------------------------------------------------------------------------

def selected-threads [
  state: string
  rows: list<record>
  old: string
  --exact
  --session-ids: list<string> = []
]: nothing -> list<record> {
  let edges = if (table-columns $state "thread_spawn_edges" | is-not-empty) {
    sqlite-rows $state "SELECT * FROM thread_spawn_edges"
  } else {
    []
  }

  let linked = (
    $rows
    | each {|row|
      let edge = (
        $edges
        | where child_thread_id == $row.id
        | first
      )

      let parent = if $edge != null {
        $edge.parent_thread_id
      } else {
        $row
        | get -o attached_thread_parent_id
        | default ($row | get -o parent_thread_id)
      }

      $row | upsert parent $parent
    }
  )

  let ids = (
    select-sessions $linked $old --exact=$exact --session-ids $session_ids
    | get -o id
  )

  $rows | where {|row| $row.id in $ids }
}

# --------------------------------------------------------------------------------------------------
# Retirement
# --------------------------------------------------------------------------------------------------

def delete-threads [state: string, threads: list<record>]: nothing -> list<record> {
  let ids = ($threads | get -o id)
  mut actions = []

  for row in $threads {
    let rollout = ($row | get -o rollout_path)
    if ($rollout | describe) == "string" {
      let resolved = (rollout-file $rollout)
      if $resolved != null {
        $actions = ($actions | append (action "codex" "rollouts" "delete" $resolved.file "rollout"))
      }
    }
  }

  if ($ids | is-not-empty) {
    let condition = $"id IN \((sql-list $ids)\)"
    let delete = $"DELETE FROM threads WHERE ($condition)"
    let edges = if (table-columns $state "thread_spawn_edges" | is-not-empty) {
      [$"DELETE FROM thread_spawn_edges WHERE child_thread_id IN \((sql-list $ids)\) OR parent_thread_id IN \((sql-list $ids)\)"]
    } else {
      []
    }

    let statements = ($edges ++ [$delete])
    let remove = (
      sql-action "codex" "threads" $state $statements "delete threads" --rows-first --foreign-keys
    )
    $actions = ($actions | append $remove)

    let history = (history-db)
    if $history != null {
      let id_list = (sql-list $ids)
      for table in $PROJECTION_TABLES {
        let statement = $"DELETE FROM ($table) WHERE thread_id IN \(($id_list)\)"
        let remove = (
          sql-action "codex" "thread-history" $history [$statement] $"delete ($table)" --derived
        )
        $actions = ($actions | append $remove)
      }
    }
  }

  $actions
}

export def plan-retire [
  old: string
  --exact
  --session-ids: list<string> = []
]: nothing -> list<record> {
  let state = (state-db)
  if $state == null { return [] }
  let inventory = (sqlite-rows $state "SELECT * FROM threads")
  let threads = (selected-threads $state $inventory $old --exact=$exact --session-ids $session_ids)
  mut actions = (delete-threads $state $threads)
  let projects = (
    $threads
    | get -o project_id
    | compact
    | uniq
  )

  if ($projects | is-not-empty) {
    let statement = $"DELETE FROM projects WHERE id IN \((sql-list $projects)\) AND NOT EXISTS \(SELECT 1 FROM threads WHERE threads.project_id = projects.id\)"
    let description = "remove unreferenced projects"
    $actions = ($actions | append (
      sql-action "codex" "projects" $state [$statement] $description --rows-first --foreign-keys
    ))
  }
  $actions
}

# --------------------------------------------------------------------------------------------------
# Transfer
# --------------------------------------------------------------------------------------------------

export def export-bundle [
  old: string
  --exact
  --session-ids: list<string> = []
]: nothing -> record {
  let db = (state-db)
  if $db == null {
    return {
      assistant: "codex"
      old: $old
      files: []
      tables: []
    }
  }

  let inventory = (sqlite-rows $db "SELECT * FROM threads")
  let threads = (selected-threads $db $inventory $old --exact=$exact --session-ids $session_ids)

  mut files = []
  for row in $threads {
    let rollout = ($row | get -o rollout_path)
    if ($rollout | describe) != "string" { continue }
    let resolved = (rollout-file $rollout)
    if $resolved == null { continue }
    let name = ($resolved.file | path relative-to (root))
    $files = ($files | append {
      kind: "rollouts"
      project: $row.cwd
      name: $name
      source: $resolved.file
      thread: $row.id
      compress: $resolved.compressed
    })
  }

  let project_ids = (
    $threads
    | get -o project_id
    | compact
    | uniq
  )

  let projects = if ($project_ids | is-not-empty) {
    sqlite-rows $db "SELECT * FROM projects"
    | where {|row| $row.id in $project_ids }
  } else {
    []
  }

  mut tables = [
    {
      db: "state"
      table: "projects"
      columns: (table-columns $db "projects")
      rows: $projects
      key: ["id"]
    }
    {
      db: "state"
      table: "threads"
      columns: (table-columns $db "threads")
      rows: $threads
      key: ["id"]
    }
  ]

  let root_columns = (table-columns $db "project_roots")
  if ($root_columns | is-not-empty) {
    let roots = (
      sqlite-rows $db "SELECT * FROM project_roots"
      | where {|row| $row.project_id in $project_ids }
    )

    $tables = ($tables | append {
      db: "state"
      table: "project_roots"
      columns: $root_columns
      rows: $roots
      key: ["project_id" "position"]
    })
  }

  if (table-columns $db "thread_spawn_edges" | is-not-empty) {
    let ids = ($threads | get -o id)
    let edges = (
      sqlite-rows $db "SELECT * FROM thread_spawn_edges"
      | where {|row| $row.child_thread_id in $ids }
    )
    $tables = ($tables | append {
      db: "state"
      table: "thread_spawn_edges"
      columns: (table-columns $db "thread_spawn_edges")
      rows: $edges
      key: ["child_thread_id"]
    })
  }

  {
    assistant: "codex"
    old: $old
    files: $files
    tables: $tables
  }
}

def rollout-target [file: record]: nothing -> string {
  let name = ($file.name | into string)
  if ($file | get -o compress | default false) and not ($name | str ends-with ".zst") {
    $name + ".zst"
  } else {
    $name
  }
}

def rollout-content [path: string, compressed: bool]: nothing -> string {
  if $compressed {
    decompress-file $path
  } else {
    open --raw $path
  }
}

export def plan-import [bundle: record, --target: string]: nothing -> list<record> {
  let rewrite = if $target == null {
    null
  } else {
    {|content| rewrite-text $content $bundle.old $target }
  }

  let state_db = (state-db)
  let projects = (bundle-table $bundle "projects")
  let roots = (bundle-table $bundle "project_roots")
  let threads = (bundle-table $bundle "threads")
  let edges = (bundle-table $bundle "thread_spawn_edges")
  if $state_db == null and (($projects.rows | is-not-empty) or ($threads.rows | is-not-empty)) {
    error make --unspanned {
      msg: "Codex import found no state database"
      help: "Start Codex once on this host, then rerun the import."
    }
  }
  if ($projects.rows | is-not-empty) {
    check-columns $state_db "projects" $projects.columns "Codex"
  }
  if ($threads.rows | is-not-empty) {
    check-columns $state_db "threads" $threads.columns "Codex"
  }
  if ($roots.rows | is-not-empty) {
    check-columns $state_db "project_roots" $roots.columns "Codex"
  }
  if ($edges.rows | is-not-empty) {
    check-columns $state_db "thread_spawn_edges" $edges.columns "Codex"
  }

  let local_threads = if $state_db == null {
    []
  } else {
    sqlite-rows $state_db "SELECT * FROM threads"
  }

  let imported = ($local_threads | get -o id)
  for file in $bundle.files {
    if ($file | get -o thread | default "") not-in $imported { continue }
    let row = (
      $local_threads
      | where id == $file.thread
      | first
    )
    let local = (rollout-file $row.rollout_path)
    if $local == null {
      error make --unspanned {msg: $"Existing thread ($file.thread) has no readable rollout"}
    }
    let content = (rollout-content $file.bundle ($file | get -o compress | default false))
    let source_body = if $rewrite == null {
      $content
    } else {
      do $rewrite $content
    }

    let local_body = (rollout-content $local.file $local.compressed)
    if $source_body != $local_body {
      error make --unspanned {msg: $"Existing thread ($file.thread) differs from the bundle"}
    }
  }

  mut actions = []

  for file in $bundle.files {
    if ($file | get -o thread | default "") in $imported { continue }
    let source = $file.bundle
    let to = (root | path join (rollout-target $file))
    let compress = ($file | get -o compress | default false)
    if ($to | path exists) {
      let content = (rollout-content $source $compress)
      let expected = if $rewrite == null {
        $content
      } else {
        do $rewrite $content
      }

      let equal = $expected == (rollout-content $to $compress)
      if $equal { continue }
      error make --unspanned {
        msg: $"($to) already exists with content that differs from the bundle's copy"
        help: "Compare the two files. Delete or rename the local file if the bundle's copy should win, then rerun the import."
      }
    }
    let label = "import rollout"
    let write = (
      copy-action "codex" "rollouts" $source $to $label --transform $rewrite --compressed=$compress
    )
    $actions = ($actions | append $write)
  }

  let local_ids = if $state_db == null or ($projects.rows | is-empty) {
    []
  } else {
    sqlite-rows $state_db "SELECT id FROM projects"
    | get -o id
  }

  let project_statements = (
    $projects.rows
    | where {|row| $row.id not-in $local_ids }
    | each {|row| sqlite-insert-if-new "projects" $projects.columns $row }
  )

  let mapped_roots = (
    $roots.rows
    | each {|row|
      if $target == null {
        $row
      } else {
        $row | upsert path (path-map $bundle.old $target $row.path)
      }
    }
  )

  if $target != null and ($roots.columns | is-not-empty) and ($local_ids | is-not-empty) {
    check-columns $state_db "project_roots" $roots.columns "Codex"
    let local_roots = (sqlite-rows $state_db "SELECT * FROM project_roots")
    for project in ($projects.rows | where {|row| $row.id in $local_ids }) {
      let expected = (
        $mapped_roots
        | where project_id == $project.id
        | sort-by position
        | get -o path
      )

      let actual = (
        $local_roots
        | where project_id == $project.id
        | sort-by position
        | get -o path
      )

      if $actual != $expected {
        error make --unspanned {
          msg: $"Existing project ($project.id) has different roots from the targeted import"
        }
      }
    }
  }

  let root_statements = (
    $mapped_roots
    | where {|row| $row.project_id not-in $local_ids }
    | each {|row| sqlite-insert-if-new "project_roots" $roots.columns $row }
  )

  let mapped = (
    $threads.rows
    | where {|row| $row.id not-in $imported }
    | each {|row|
      let row = if $rewrite == null {
        $row
      } else {
        let mapped = ($row | upsert cwd (path-map $bundle.old $target $row.cwd))
        if ("sandbox_policy" in ($row | columns)) and $row.sandbox_policy != null {
          $mapped | upsert sandbox_policy (rewrite-text $row.sandbox_policy $bundle.old $target)
        } else {
          $mapped
        }
      }

      let file = (
        $bundle.files
        | where thread == $row.id
        | get -o 0
      )
      if $file != null {
        let name = (plain-rollout-path (rollout-target $file))
        $row | upsert rollout_path (root | path join $name)
      } else {
        $row
      }
    }
  )

  let thread_statements = (
    $mapped
    | each {|row| sqlite-insert-if-new "threads" $threads.columns $row }
  )

  let local_edges = if ($edges.rows | is-empty) {
    []
  } else {
    sqlite-rows $state_db "SELECT * FROM thread_spawn_edges"
  }

  let edge_statements = (
    $edges.rows
    | each {|row|
      let local = (
        $local_edges
        | where child_thread_id == $row.child_thread_id
        | first
      )

      if $local == null {
        sqlite-insert-if-new "thread_spawn_edges" $edges.columns $row
      } else if $local.parent_thread_id != $row.parent_thread_id {
        error make --unspanned {
          msg: $"Existing thread ($row.child_thread_id) has a different parent"
        }
      } else {
        null
      }
    }
    | compact
  )

  let statements = (
    $project_statements ++ $root_statements ++ $thread_statements ++ $edge_statements
  )
  if ($statements | is-not-empty) {
    let load = (sql-action "codex" "state" $state_db $statements "import state")
    $actions = ($actions | append $load)
  }

  $actions
}
