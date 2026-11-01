# ==================================================================================================
# Agent Project Move: OpenCode
# ==================================================================================================
# OpenCode state, held in one SQLite database, plus the snapshot directories a move renames.
# ==================================================================================================

use ../lib/actions.nu [action column-actions rename-action same-tree sql-action]
use ../lib/bundle.nu [bundle-table sha1-hex]
use ../lib/paths.nu [path-map path-match valid-path]
use ../lib/sqlite.nu [
  check-columns
  path-condition
  sqlite-columns
  sqlite-insert-if-new
  sqlite-rows
]

const CHILD_TABLES = [
  message
  part
  session_message
  session_input
  session_share
  todo
  session_context_epoch
]

# --------------------------------------------------------------------------------------------------
# Locations
# --------------------------------------------------------------------------------------------------

def data-root []: nothing -> string {
  let base = ($env.XDG_DATA_HOME? | default --empty ($env.HOME | path join .local share))
  $base | path join opencode
}

def db []: nothing -> string {
  $env.OPENCODE_DB? | default --empty (data-root | path join opencode.db)
}

def snapshot-root []: nothing -> string { data-root | path join snapshot }

# --------------------------------------------------------------------------------------------------
# Scan
# --------------------------------------------------------------------------------------------------

# The store records paths only through its scan rows.
export def recorded-paths []: nothing -> list<string> { [] }

def session-total [rows: list, base: string]: nothing -> int {
  let values = (
    $rows
    | where {|row| path-match $base $row.directory }
    | get -o sessions
  )
  $values | each {|value| $value | into int } | append 0 | math sum
}

export def scan []: nothing -> list<record> {
  let database = (db)
  if not ($database | path exists) { return [] }

  let aggregates = "count(*) AS sessions, max(time_updated) AS last_used"
  let sessions = (
    sqlite-rows $database $"SELECT directory, ($aggregates) FROM session GROUP BY directory"
  )
  let projects = (sqlite-rows $database "SELECT id, worktree, sandboxes, time_updated FROM project")
  let directories = (sqlite-rows $database "SELECT project_id, directory FROM project_directory")
  let workspaces = (
    sqlite-rows $database "SELECT directory FROM workspace WHERE directory IS NOT NULL"
  )

  let session_rows = (
    $sessions
    | where {|row| valid-path $row.directory }
    | each {|row|
      {
        assistant: opencode
        path: $row.directory
        sessions: ($row.sessions | into int)
        last_used: (
          if $row.last_used == null { null } else { $row.last_used * 1000000 | into datetime }
        )
      }
    }
  )
  let project_rows = (
    $projects
    | each {|row|
      let count = (session-total $sessions $row.worktree)
      {assistant: opencode, path: $row.worktree, sessions: $count, last_used: null}
    }
  )
  let directory_rows = (
    $directories
    | each {|row| {assistant: opencode, path: $row.directory, sessions: 0, last_used: null} }
  )
  let workspace_rows = (
    $workspaces
    | each {|row| {assistant: opencode, path: $row.directory, sessions: 0, last_used: null} }
  )

  let rows = (
    $session_rows ++ $project_rows ++ $directory_rows ++ $workspace_rows
    | where {|row| valid-path $row.path }
  )
  $rows
  | group-by path
  | transpose path items
  | each {|group|
    let counts = ($group.items | get -o sessions | compact)
    let timestamps = ($group.items | get -o last_used | compact | sort)
    {
      assistant: opencode
      path: $group.path
      sessions: ($counts | append 0 | math sum)
      last_used: ($timestamps | last)
    }
  }
  | sort-by path
}

# --------------------------------------------------------------------------------------------------
# Move
# --------------------------------------------------------------------------------------------------

def snapshot-actions [
  projects: list<record>
  directories: list<record>
  sessions: list<record>
  workspaces: list<record>
  old: string
  new: string
]: nothing -> list<record> {
  let sources = [
    ($projects | each {|row| {project: $row.id, path: $row.worktree} })
    ($directories | each {|row| {project: $row.project_id, path: $row.directory} })
    ($sessions | each {|row| {project: $row.project_id, path: $row.directory} })
    ($workspaces | each {|row| {project: $row.project_id, path: $row.directory} })
  ]
  let locations = (
    $sources
    | flatten
    | where {|row| path-match $old $row.path }
    | uniq
  )

  mut actions = []
  for location in $locations {
    let source = (snapshot-root | path join $location.project (sha1-hex $location.path))
    if not ($source | path exists) { continue }
    let target_path = (path-map $old $new $location.path)
    let target = (snapshot-root | path join $location.project (sha1-hex $target_path))
    if ($target | path exists) {
      if not (same-tree $source $target) {
        error make --unspanned {
          msg: $"OpenCode snapshot ($target) already exists with different content"
          help: "Compare the two directories, keep one, then rerun the move. Nothing was written."
        }
      }
    } else {
      let rename = (rename-action opencode snapshots $source $target "rename snapshot")
      $actions = ($actions | append $rename)
    }
  }
  $actions
}

export def plan-move [old: string, new: string]: nothing -> list<record> {
  let database = (db)
  if not ($database | path exists) { return [] }

  let projects = (sqlite-rows $database "SELECT * FROM project")
  let directories = (sqlite-rows $database "SELECT * FROM project_directory")
  let sessions = (sqlite-rows $database "SELECT * FROM session")
  let workspaces = (sqlite-rows $database "SELECT * FROM workspace")

  (
    (column-actions opencode [
      {db: $database, table: session, column: directory}
      {db: $database, table: workspace, column: directory}
      {db: $database, table: project, column: worktree}
      {db: $database, table: project_directory, column: directory, collide: true}
      {db: $database, table: project, column: sandboxes, json: true}
      {db: $database, table: event, column: data, json: true}
    ] $old $new)
    ++ (snapshot-actions $projects $directories $sessions $workspaces $old $new)
  )
}

# --------------------------------------------------------------------------------------------------
# Prune
# --------------------------------------------------------------------------------------------------

export def plan-prune [paths: list<string>]: nothing -> list<record> {
  let database = (db)
  if not ($database | path exists) { return [] }

  let session_condition = (path-condition directory $paths)
  let project_condition = (
    $"\((path-condition worktree $paths)\)"
    + " AND NOT EXISTS (SELECT 1 FROM session WHERE session.project_id = project.id)"
    + " AND NOT EXISTS ("
    + "SELECT 1 FROM project_directory WHERE project_directory.project_id = project.id)"
  )
  let count = (
    sqlite-rows $database (
      "SELECT (SELECT count(*) FROM session WHERE " + $session_condition + ")"
      + " + (SELECT count(*) FROM workspace WHERE " + $session_condition + ")"
      + " + (SELECT count(*) FROM project_directory WHERE " + $session_condition + ")"
      + " + (SELECT count(*) FROM project WHERE " + $project_condition + ") AS rows"
    )
    | get 0.rows
    | into int
  )
  if $count == 0 { return [] }

  let session_ids = $"SELECT id FROM session WHERE ($session_condition)"
  let statements = [
    $"DELETE FROM event_sequence WHERE aggregate_id IN \(($session_ids)\)"
    $"DELETE FROM session WHERE ($session_condition)"
    $"DELETE FROM workspace WHERE ($session_condition)"
    $"DELETE FROM project_directory WHERE ($session_condition)"
    $"DELETE FROM project WHERE ($project_condition)"
  ]

  let pruned = "(" + $session_condition + ")"
  let removed_projects = (
    sqlite-rows $database (
      "SELECT id, worktree FROM project WHERE (" + (path-condition worktree $paths) + ")"
      + " AND NOT EXISTS (SELECT 1 FROM session"
      + " WHERE session.project_id = project.id AND NOT " + $pruned + ")"
      + " AND NOT EXISTS (SELECT 1 FROM project_directory"
      + " WHERE project_directory.project_id = project.id AND NOT " + $pruned + ")"
    )
  )
  let removed_directories = (
    sqlite-rows $database (
      $"SELECT project_id, directory FROM project_directory WHERE \(($session_condition)\)"
    )
  )

  let deletion = (
    sql-action opencode database $database $statements "delete state" --rows-first --foreign-keys
  )
  mut actions = [$deletion]
  for project in $removed_projects {
    let snapshot = (snapshot-root | path join $project.id)
    if ($snapshot | path exists) {
      let remove = (action opencode snapshots delete $snapshot "project snapshots")
      $actions = ($actions | append $remove)
    }
  }
  for row in $removed_directories {
    let snapshot = (snapshot-root | path join $row.project_id (sha1-hex $row.directory))
    if ($snapshot | path exists) {
      let remove = (action opencode snapshots delete $snapshot "directory snapshot")
      $actions = ($actions | append $remove)
    }
  }
  $actions
}

# --------------------------------------------------------------------------------------------------
# Transfer
# --------------------------------------------------------------------------------------------------

def sandboxes [value: any]: nothing -> list {
  if ($value | describe) != "string" { return [] }
  $value | from json
}

def export-selection [database: string, old: string]: nothing -> record {
  let projects = (sqlite-rows $database "SELECT * FROM project")
  let directories = (sqlite-rows $database "SELECT * FROM project_directory")
  let sessions = (sqlite-rows $database "SELECT * FROM session")
  let workspaces = (sqlite-rows $database "SELECT * FROM workspace")
  let events = (sqlite-rows $database "SELECT * FROM event")

  let selected_sessions = (
    $sessions | where {|row| path-match $old $row.directory }
  )
  let selected_directories = (
    $directories | where {|row| path-match $old $row.directory }
  )
  let selected_workspaces = (
    $workspaces | where {|row| path-match $old $row.directory }
  )

  let referenced = (
    ($selected_sessions | get -o project_id | compact)
    ++ ($selected_directories | get -o project_id | compact)
    ++ ($selected_workspaces | get -o project_id | compact)
  )
  let selected_projects = (
    $projects
    | where {|row|
      (
        (path-match $old $row.worktree)
        or ($row.id in $referenced)
        or (sandboxes $row.sandboxes | any {|sandbox| path-match $old $sandbox })
      )
    }
  )

  let session_ids = ($selected_sessions | get -o id | compact)
  let selected_events = (
    $events | where {|row| $row.aggregate_id in $session_ids }
  )

  {
    projects: $selected_projects
    directories: $selected_directories
    sessions: $selected_sessions
    workspaces: $selected_workspaces
    events: $selected_events
  }
}

def table-spec [database: string, table: string, rows: list]: nothing -> record {
  {
    db: opencode
    table: $table
    columns: (sqlite-columns $database $table)
    rows: $rows
  }
}

def selection-tables [database: string, selection: record]: nothing -> list<record> {
  let session_ids = ($selection.sessions | get -o id | compact)
  let aggregate_ids = (
    $session_ids ++ ($selection.events | get -o aggregate_id | compact) | uniq
  )
  let sequences = if ($aggregate_ids | is-empty) {
    []
  } else {
    sqlite-rows $database "SELECT * FROM event_sequence"
    | where {|row| $row.aggregate_id in $aggregate_ids }
  }

  [
    (table-spec $database project $selection.projects)
    (table-spec $database project_directory $selection.directories)
    (table-spec $database workspace $selection.workspaces)
    (table-spec $database session $selection.sessions)
    (table-spec $database event_sequence $sequences)
    (table-spec $database event $selection.events)
  ]
}

def child-tables [database: string, session_ids: list]: nothing -> list<record> {
  $CHILD_TABLES
  | each {|table|
    let rows = (
      sqlite-rows $database $"SELECT * FROM ($table)"
      | where {|row| ($row | get -o session_id) in $session_ids }
    )
    table-spec $database $table $rows
  }
}

def permission-tables [database: string, project_ids: list]: nothing -> list<record> {
  if ($project_ids | is-empty) { return [] }
  let rows = (
    sqlite-rows $database "SELECT * FROM permission"
    | where {|row| ($row | get -o project_id) in $project_ids }
  )
  [(table-spec $database permission $rows)]
}

export def export-bundle [old: string]: nothing -> record {
  let database = (db)
  if not ($database | path exists) {
    return {assistant: opencode, old: $old, files: [], tables: []}
  }

  let selection = (export-selection $database $old)
  let session_ids = ($selection.sessions | get -o id | compact)
  let project_ids = ($selection.projects | get -o id | compact)
  let tables = (
    (selection-tables $database $selection)
    ++ (child-tables $database $session_ids)
    ++ (permission-tables $database $project_ids)
  )

  {assistant: opencode, old: $old, files: [], tables: $tables}
}

export def plan-import [bundle: record]: nothing -> list<record> {
  let database = (db)
  let order = (
    [
      project
      project_directory
      workspace
      session
      event_sequence
      event
    ]
    ++ $CHILD_TABLES
    ++ [permission]
  )
  let specs = (
    $order
    | each {|table|
      let spec = (bundle-table $bundle $table)
      if ($spec.rows | is-not-empty) {
        check-columns $database $table $spec.columns "OpenCode"
      }
      $spec
    }
    | where {|spec| ($spec.rows | is-not-empty) }
  )
  let sessions = (bundle-table $bundle session)
  let local = if ($database | path exists) {
    sqlite-rows $database "SELECT id FROM session" | get -o id
  } else {
    []
  }
  if ($sessions.rows | get -o id | all {|id| $id in $local }) {
    return []
  }
  let statements = (
    $specs
    | each {|spec| $spec.rows | each {|row| sqlite-insert-if-new $spec.table $spec.columns $row } }
    | flatten
  )
  if ($statements | is-empty) { return [] }
  [(sql-action opencode database $database $statements "import state")]
}
