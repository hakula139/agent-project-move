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
  same-content
  sql-action
]
use ../lib/bundle.nu [bundle-table]
use ../lib/paths.nu [match-any path-map path-match valid-path]
use ../lib/rewrite.nu [files-with-path offsets-kept rewrite-text]
use ../lib/sqlite.nu [
  check-columns
  latest-db
  path-condition
  sql-list
  sqlite-insert-if-new
  sqlite-rows
  table-columns
]

# The projection state goes first, since its AFTER DELETE trigger clears thread_realtime_items.
const PROJECTION_TABLES = [thread_history_projection_state thread_turns thread_items]

# A trust block opens with a `[projects."<path>"]` table header.
const TRUST_HEADER = '^\[projects\."(?<path>[^"]+)"\]$'

# --------------------------------------------------------------------------------------------------
# Locations
# --------------------------------------------------------------------------------------------------

def root []: nothing -> string {
  $env.CODEX_HOME? | default --empty ($env.HOME | path join .codex)
}

# The state database, or null before Codex has created one.
def state-db []: nothing -> any {
  latest-db (root | path join 'state_*.sqlite') threads
}

# The thread history database, or null before Codex has created one.
def history-db []: nothing -> any {
  latest-db (root | path join 'thread_history_*.sqlite') thread_items
}

def config-path []: nothing -> string {
  root | path join config.toml
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

  let compressed = if $plain == $path { $path + ".zst" } else { $path }
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
      assistant: codex
      path: $row.cwd
      sessions: ($row.sessions | into int)
      last_used: (
        if $row.last_used == null { null } else { $row.last_used * 1000000 | into datetime }
      )
    }
  }
}

# --------------------------------------------------------------------------------------------------
# Trust blocks
# --------------------------------------------------------------------------------------------------

def trust-blocks []: nothing -> record {
  let file = (config-path)
  if not ($file | path exists) { return {} }
  trust-blocks-from (open --raw $file)
}

export def move-trust [content: string, old: string, new: string]: nothing -> string {
  let lines = ($content | lines)
  let existing = (trust-blocks-from $content)
  mut kept = []
  mut skipping = false
  mut moved = []

  for line in $lines {
    let header = ($line | parse --regex $TRUST_HEADER)
    if ($header | is-not-empty) {
      let path = ($header | get 0.path)
      if (path-match $old $path) {
        $skipping = true
        let target = (path-map $old $new $path)
        if $target not-in ($existing | columns) {
          let body = (
            $existing
            | transpose key body
            | where key == $path
            | get -o 0.body
            | default []
          )
          let block = if ($body | is-empty) { ["trust_level = \"trusted\"" ""] } else { $body }
          $moved = ($moved | append ([$"[projects.\"($target)\"]"] ++ $block))
        }
      } else {
        $skipping = false
        $kept = ($kept | append $line)
      }
    } else if ($line | str starts-with "[") {
      $skipping = false
      $kept = ($kept | append $line)
    } else if not $skipping {
      $kept = ($kept | append $line)
    }
  }

  let additions = if ($moved | is-empty) { [] } else { $moved | flatten }
  (($kept ++ $additions) | str join "\n") + "\n"
}

def trust-blocks-from [content: string]: nothing -> record {
  let lines = ($content | lines)
  mut blocks = {}
  mut current: oneof<string, nothing> = null
  mut body = []

  for line in $lines {
    let header = ($line | parse --regex $TRUST_HEADER)
    if ($header | is-not-empty) {
      if $current != null { $blocks = ($blocks | merge {($current): $body}) }
      $current = ($header | get 0.path)
      $body = []
    } else if ($line | str starts-with "[") {
      if $current != null { $blocks = ($blocks | merge {($current): $body}) }
      $current = null
      $body = []
    } else if $current != null {
      $body = ($body | append $line)
    }
  }
  if $current != null { $blocks = ($blocks | merge {($current): $body}) }
  $blocks
}

def prune-trust [content: string, paths: list<string>]: nothing -> string {
  let lines = ($content | lines)
  mut kept = []
  mut skipping = false

  for line in $lines {
    let header = ($line | parse --regex $TRUST_HEADER)
    if ($header | is-not-empty) {
      $skipping = (match-any $paths ($header | get 0.path))
      if not $skipping { $kept = ($kept | append $line) }
    } else if ($line | str starts-with "[") {
      $skipping = false
      $kept = ($kept | append $line)
    } else if not $skipping {
      $kept = ($kept | append $line)
    }
  }
  if ($kept | is-empty) { "" } else { ($kept | str join "\n") + "\n" }
}

# --------------------------------------------------------------------------------------------------
# Move
# --------------------------------------------------------------------------------------------------

def trust-actions [old: string, new: string]: nothing -> list<record> {
  let config = (config-path)
  let match = (trust-blocks | columns | any {|path| path-match $old $path })
  if ($config | path exists) and $match {
    let edit = (edit-action codex config $config {|content|
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
    column-actions codex [{db: $db, table: thread_items, column: item_json, json: true}] $old $new
  } else {
    let id_list = (sql-list $ids)
    $PROJECTION_TABLES
    | each {|table|
      let statement = $"DELETE FROM ($table) WHERE thread_id IN \(($id_list)\)"
      sql-action codex thread-history $db [$statement] $"reset ($table)" --derived
    }
  }
}

export def plan-move [old: string, new: string]: nothing -> list<record> {
  let state = (state-db)
  if $state == null { return [] }

  let home = (root)
  let rollouts = (files-with-path $old [
    ($home | path join sessions)
    ($home | path join archived_sessions)
  ])
  let desktop = (files-with-path $old [($home | path join .codex-global-state.json)])

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
    column-actions codex [
      {db: $state, table: threads, column: cwd}
      {db: $state, table: threads, column: sandbox_policy, json: true}
    ] $old $new
  )
  for file in $rollouts {
    $actions = ($actions | append (edit-action codex rollouts $file {|content|
      rewrite-text $content $old $new
    } "rewrite cwd"))
  }
  for file in $desktop {
    $actions = ($actions | append (edit-action codex desktop-state $file {|content|
      rewrite-text $content $old $new
    } "rewrite desktop state"))
  }
  $actions = ($actions ++ (projection-actions (history-db) $edited_ids $old $new))
  $actions = ($actions ++ (trust-actions $old $new))
  $actions
}

# --------------------------------------------------------------------------------------------------
# Prune
# --------------------------------------------------------------------------------------------------

export def plan-prune [paths: list<string>]: nothing -> list<record> {
  let state = (state-db)
  if $state == null { return [] }

  let threads = (
    sqlite-rows $state "SELECT * FROM threads"
    | where {|row| match-any $paths $row.cwd }
  )
  let ids = ($threads | get -o id | compact)
  mut actions = []

  for row in $threads {
    let rollout = ($row | get -o rollout_path)
    if ($rollout | describe) == "string" {
      let resolved = (rollout-file $rollout)
      if $resolved != null {
        $actions = ($actions | append (action codex rollouts delete $resolved.file "rollout"))
      }
    }
  }

  if ($ids | is-not-empty) {
    let condition = (path-condition cwd $paths)
    let delete = $"DELETE FROM threads WHERE ($condition)"
    let remove = (
      sql-action codex threads $state [$delete] "delete threads" --rows-first --foreign-keys
    )
    $actions = ($actions | append $remove)

    let history = (history-db)
    if $history != null {
      let id_list = (sql-list $ids)
      for table in $PROJECTION_TABLES {
        let statement = $"DELETE FROM ($table) WHERE thread_id IN \(($id_list)\)"
        let remove = (
          sql-action codex thread-history $history [$statement] $"delete ($table)" --derived
        )
        $actions = ($actions | append $remove)
      }
    }
  }

  let config = (config-path)
  let trust_match = (trust-blocks | columns | any {|path| match-any $paths $path })
  if ($config | path exists) and $trust_match {
    $actions = ($actions | append (edit-action codex config $config {|content|
      prune-trust $content $paths
    } "remove trust blocks"))
  }
  $actions
}

# --------------------------------------------------------------------------------------------------
# Transfer
# --------------------------------------------------------------------------------------------------

export def export-bundle [old: string]: nothing -> record {
  let db = (state-db)
  if $db == null {
    return {assistant: codex, old: $old, files: [], tables: []}
  }

  let threads = (
    sqlite-rows $db "SELECT * FROM threads"
    | where {|row| path-match $old $row.cwd }
  )

  mut files = []
  for row in $threads {
    let rollout = ($row | get -o rollout_path)
    if ($rollout | describe) != "string" { continue }
    let resolved = (rollout-file $rollout)
    if $resolved == null { continue }
    let name = ($resolved.file | path relative-to (root))
    $files = ($files | append {
      kind: rollouts
      project: $row.cwd
      name: $name
      source: $resolved.file
      thread: $row.id
      compress: $resolved.compressed
    })
  }

  let project_ids = ($threads | get -o project_id | compact | uniq)
  let projects = if ($project_ids | is-not-empty) {
    sqlite-rows $db "SELECT * FROM projects" | where {|row| $row.id in $project_ids }
  } else {
    []
  }

  let tables = [
    {
      db: state
      table: projects
      columns: (table-columns $db projects)
      rows: $projects
      key: [id]
    }
    {
      db: state
      table: threads
      columns: (table-columns $db threads)
      rows: $threads
      key: [id]
    }
  ]

  {
    assistant: codex
    old: $old
    files: $files
    tables: $tables
  }
}

export def rollout-target [file: record]: nothing -> string {
  let name = ($file.name | into string)
  if (($file | get -o compress | default false)) and not ($name | str ends-with ".zst") {
    $name + ".zst"
  } else {
    $name
  }
}

export def plan-import [bundle: record]: nothing -> list<record> {
  let state_db = (state-db)
  let projects = (bundle-table $bundle projects)
  let threads = (bundle-table $bundle threads)
  if $state_db == null and (($projects.rows | is-not-empty) or ($threads.rows | is-not-empty)) {
    error make {msg: "Codex import found no state database. Start Codex once on this host"}
  }
  if ($projects.rows | is-not-empty) {
    check-columns $state_db projects $projects.columns "Codex"
  }
  if ($threads.rows | is-not-empty) {
    check-columns $state_db threads $threads.columns "Codex"
  }
  let imported = if $state_db == null {
    []
  } else {
    sqlite-rows $state_db "SELECT id FROM threads" | get -o id | default []
  }
  if (($threads.rows | get -o id | compact) | all {|id| $id in $imported }) {
    return []
  }
  mut actions = []

  for file in $bundle.files {
    if (($file | get -o thread | default "") in $imported) { continue }
    let target = (root | path join (rollout-target $file))
    let compress = ($file | get -o compress | default false)
    if ($target | path exists) {
      let equal = if $compress {
        (decompress-file $file.bundle) == (decompress-file $target)
      } else {
        same-content $file.bundle $target
      }
      if $equal { continue }
      error make {msg: $"Import collision: ($target)"}
    }
    let write = (copy-action codex rollouts $file.bundle $target "import rollout")
    $actions = ($actions | append $write)
  }

  let project_statements = (
    $projects.rows | each {|row| sqlite-insert-if-new projects $projects.columns $row }
  )
  let mapped = (
    $threads.rows
    | each {|row|
      let file = ($bundle.files | where thread == $row.id | get -o 0)
      if $file != null {
        let name = (plain-rollout-path (rollout-target $file))
        $row | upsert rollout_path (root | path join $name)
      } else {
        $row
      }
    }
  )
  let thread_statements = (
    $mapped | each {|row| sqlite-insert-if-new threads $threads.columns $row }
  )
  let statements = ($project_statements ++ $thread_statements)
  if ($statements | is-not-empty) {
    let load = (sql-action codex state $state_db $statements "import state")
    $actions = ($actions | append $load)
  }
  $actions
}
