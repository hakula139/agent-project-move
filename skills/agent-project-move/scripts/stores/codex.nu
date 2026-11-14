# ==================================================================================================
# Agent Project Move: Codex
# ==================================================================================================
# Codex state, including rollouts, trust settings, and SQLite databases.
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
use ../lib/paths.nu [match-any path-map path-match valid-path]
use ../lib/rewrite.nu [files-with-path offsets-kept rewrite-text]
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

# A trust block opens with a `[projects."<path>"]` table header.
const TRUST_HEADER = '^\[projects\."(?<path>[^"]+)"\]$'

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

def config-path []: nothing -> string {
  root | path join "config.toml"
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
  if ($plain | path exists) { return {file: $plain, compressed: false} }

  let compressed = if $plain == $path {
    $path + ".zst"
  } else {
    $path
  }
  if ($compressed | path exists) { return {file: $compressed, compressed: true} }
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
# Trust blocks
# --------------------------------------------------------------------------------------------------

# Trailing comment lines, from the first comment on, lead the next header.
def split-leading [body: list<string>]: nothing -> record {
  let trailing = (
    $body
    | reverse
    | take while {|line| ($line | str trim) == "" or ($line | str starts-with "#") }
    | reverse
  )
  let leading = ($trailing | skip while {|line| ($line | str trim) == "" })
  {body: ($body | take (($body | length) - ($leading | length))), leading: $leading}
}

# Split the config at every table header. Lines before the first form a headerless section.
def config-sections [content: string]: nothing -> list<record> {
  mut sections = []
  mut current: oneof<record, nothing> = null

  for line in ($content | lines) {
    if ($line | str starts-with "[") {
      let header = ($line | parse --regex $TRUST_HEADER)
      let path = if ($header | is-empty) {
        null
      } else {
        $header | get 0.path
      }
      if $current != null {
        let split = (split-leading $current.body)
        $current = ($current | upsert body $split.body)
        $sections = ($sections | append $current)
        $current = {header: $line, path: $path, leading: $split.leading, body: []}
      } else {
        $current = {header: $line, path: $path, leading: [], body: []}
      }
    } else if $current == null {
      $current = {header: null, path: null, leading: [], body: [$line]}
    } else {
      $current = ($current | update body { $in | append $line })
    }
  }
  if $current != null { $sections = ($sections | append $current) }
  $sections
}

def section-lines [section: record]: nothing -> list<string> {
  if $section.header == null {
    $section.body
  } else {
    $section.leading ++ [$section.header] ++ $section.body
  }
}

def trust-blocks-in [content: string]: nothing -> list<record> {
  config-sections $content | where {|section| $section.path != null }
}

def trust-blocks []: nothing -> list<record> {
  let file = (config-path)
  if not ($file | path exists) { return [] }
  trust-blocks-in (open --raw $file)
}

export def move-trust [content: string, old: string, new: string]: nothing -> string {
  let sections = (config-sections $content)
  let existing = ($sections | get -o path | compact)
  let kept = (
    $sections
    | where {|section| ($section.path == null) or (not (path-match $old $section.path)) }
  )
  let moved = (
    $sections
    | where {|section| ($section.path != null) and (path-match $old $section.path) }
    | each {|section|
      let target = (path-map $old $new $section.path)
      if $target in $existing {
        null
      } else {
        {
          header: $"[projects.\"($target)\"]"
          path: $target
          leading: $section.leading
          body: $section.body
        }
      }
    }
    | compact
  )
  let lines = (
    $kept ++ $moved
    | each {|section| section-lines $section }
    | flatten
  )
  ($lines | str join "\n") + "\n"
}

export def prune-trust [content: string, paths: list<string>, --exact]: nothing -> string {
  let kept = (
    config-sections $content
    | where {|section|
      if $exact {
        $section.path not-in $paths
      } else {
        not (($section.path != null) and (match-any $paths $section.path))
      }
    }
    | each {|section| section-lines $section }
    | flatten
  )
  if ($kept | is-empty) {
    ""
  } else {
    ($kept | str join "\n") + "\n"
  }
}

# --------------------------------------------------------------------------------------------------
# Move
# --------------------------------------------------------------------------------------------------

def trust-actions [old: string, new: string]: nothing -> list<record> {
  let config = (config-path)
  let match = (trust-blocks | any {|block| path-match $old $block.path })
  if ($config | path exists) and $match {
    let edit = (edit-action "codex" "config" $config {|content|
      move-trust $content $old $new
    } "rewrite trust blocks")
    [$edit]
  } else {
    []
  }
}

def projection-actions [
  db: any
  ids: list<string>
  old: string
  new: string
]: nothing -> list<record> {
  if ($db == null) or ($ids | is-empty) { return [] }

  if (offsets-kept $old $new) {
    let columns = [{db: $db, table: "thread_items", column: "item_json", json: true}]
    column-actions "codex" $columns $old $new
  } else {
    let id_list = (sql-list $ids)
    $PROJECTION_TABLES
    | each {|table|
      let statement = $"DELETE FROM ($table) WHERE thread_id IN \(($id_list)\)"
      sql-action "codex" "thread-history" $db [$statement] $"reset ($table)" --derived
    }
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

  let desktop = (files-with-path $old [($home | path join ".codex-global-state.json")])

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
      {db: $state, table: "threads", column: "cwd"}
      {db: $state, table: "threads", column: "sandbox_policy", json: true}
    ] $old $new
  )
  for file in $rollouts {
    $actions = ($actions | append (edit-action "codex" "rollouts" $file $rewrite "rewrite cwd"))
  }
  for file in $desktop {
    $actions = (
      $actions | append (edit-action "codex" "desktop-state" $file $rewrite "rewrite desktop state")
    )
  }
  $actions = ($actions ++ (projection-actions (history-db) $edited_ids $old $new))
  $actions = ($actions ++ (trust-actions $old $new))
  $actions
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
# Prune
# --------------------------------------------------------------------------------------------------

def delete-threads [
  state: string
  threads: list<record>
  paths: list<string>
  --exact
]: nothing -> list<record> {
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

  let config = (config-path)
  let trust_match = (trust-blocks | any {|block|
    if $exact {
      $block.path in $paths
    } else {
      match-any $paths $block.path
    }
  })
  if ($config | path exists) and $trust_match {
    $actions = ($actions | append (edit-action "codex" "config" $config {|content|
      prune-trust $content $paths --exact=$exact
    } "remove trust blocks"))
  }
  $actions
}

export def plan-prune [paths: list<string>]: nothing -> list<record> {
  let state = (state-db)
  if $state == null { return [] }
  let threads = (
    sqlite-rows $state "SELECT * FROM threads"
    | where {|row| match-any $paths $row.cwd }
  )
  delete-threads $state $threads $paths
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
  let ids = ($threads | get -o id)
  let remaining = (
    $inventory
    | where {|row| $row.id not-in $ids }
  )
  let unused = (
    $threads
    | get -o cwd
    | uniq
    | where {|cwd| not ($remaining | any {|row| $cwd == $row.cwd }) }
  )
  mut actions = (delete-threads $state $threads $unused --exact)
  let projects = (
    $threads
    | get -o project_id
    | compact
    | uniq
  )
  if ($projects | is-not-empty) {
    let statement = (
      $"DELETE FROM projects WHERE id IN \((sql-list $projects)\)"
      + " AND NOT EXISTS (SELECT 1 FROM threads WHERE threads.project_id = projects.id)"
    )
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
    return {assistant: "codex", old: $old, files: [], tables: []}
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
    {db: "state", table: "projects", columns: (table-columns $db "projects"), rows: $projects, key: ["id"]}
    {db: "state", table: "threads", columns: (table-columns $db "threads"), rows: $threads, key: ["id"]}
  ]
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

  {assistant: "codex", old: $old, files: $files, tables: $tables}
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

export def plan-import [bundle: record]: nothing -> list<record> {
  let state_db = (state-db)
  let projects = (bundle-table $bundle "projects")
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
    let source_body = (rollout-content $file.bundle ($file | get -o compress | default false))
    let local_body = (rollout-content $local.file $local.compressed)
    if $source_body != $local_body {
      error make --unspanned {msg: $"Existing thread ($file.thread) differs from the bundle"}
    }
  }
  mut actions = []

  for file in $bundle.files {
    if ($file | get -o thread | default "") in $imported { continue }
    let target = (root | path join (rollout-target $file))
    let compress = ($file | get -o compress | default false)
    if ($target | path exists) {
      let equal = (rollout-content $file.bundle $compress) == (rollout-content $target $compress)
      if $equal { continue }
      error make --unspanned {
        msg: $"($target) already exists with content that differs from the bundle's copy"
        help: "Compare the two files. Delete or rename the local file if the bundle's copy should win, then rerun the import."
      }
    }
    let write = (copy-action "codex" "rollouts" $file.bundle $target "import rollout")
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
  let mapped = (
    $threads.rows
    | where {|row| $row.id not-in $imported }
    | each {|row|
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
  let statements = ($project_statements ++ $thread_statements ++ $edge_statements)
  if ($statements | is-not-empty) {
    let load = (sql-action "codex" "state" $state_db $statements "import state")
    $actions = ($actions | append $load)
  }
  $actions
}
