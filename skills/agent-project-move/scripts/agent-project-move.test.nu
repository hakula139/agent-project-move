#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Selective Transfer and Retirement Tests
# ==================================================================================================

use std/assert

use ./lib/sqlite.nu [sql-quote sqlite-rows]
use ./stores/claude.nu [encode-path]
use ./stores/omp.nu [scan session-encode-here]

const SCRIPT = path self "agent-project-move.nu"

def fixture-env [root: string]: nothing -> record {
  {
    CLAUDE_CONFIG_DIR: ($root | path join "claude")
    CODEX_HOME: ($root | path join "codex")
    PI_CODING_AGENT_DIR: ($root | path join "omp")
    TZ: "UTC"
    XDG_STATE_HOME: ($root | path join "state")
  }
}

def traced-fixture-env [root: string]: nothing -> record {
  let sqlite = (
    which sqlite3
    | first
    | get path
  )

  fixture-env $root
  | merge {
    APM_SQLITE: $sqlite
    APM_SQLITE_BACKUP_LOG: ($root | path join "sqlite-backups.jsonl")
    PATH: ($env.PATH | prepend $env.NU_TEST_STUBS)
  }
}

def write-jsonl [file: string, rows: list<record>] {
  mkdir ($file | path dirname)
  $rows
  | each {|row| $row | to json --raw }
  | str join "\n"
  | save $file
}

def --wrapped run-cli [...args: string]: nothing -> record {
  ^$nu.current-exe $SCRIPT ...$args | complete
}

def apply-codex [root: string, db: string, args: list<string>, backup: bool]: nothing -> any {
  let before = (open --raw $db | hash sha256)
  let ids = (sqlite-rows $db "SELECT id FROM threads ORDER BY id")
  let rollout = ($root | path join "codex/sessions/parent.jsonl.zst")
  let had_rollout = ($rollout | path exists)
  let backup_root = ($root | path join "state/agent-project-move")
  let backup_log = ($root | path join "sqlite-backups.jsonl")
  let flags = if $backup { [] } else { ["--no-backup"] }
  let label = $"($args | str join ' '), backup=($backup)"

  with-env (traced-fixture-env $root) {
    let dry = (run-cli ...$args --assistant "codex" ...$flags)
    assert equal $dry.exit_code 0 $"($label): ($dry.stderr)"

    assert equal (open --raw $db | hash sha256) $before $label
    assert equal ($rollout | path exists) $had_rollout $label
    assert not ($backup_root | path exists) $label
    assert not ($backup_log | path exists) $label
    assert str contains $dry.stdout (
      if $backup { "A backup goes to" } else { "No backup will be created." }
    ) $label

    let apply = (run-cli ...$args --assistant "codex" --apply ...$flags)
    assert equal $apply.exit_code 0 $"($label): ($apply.stderr)"

    assert equal ($backup_root | path exists) $backup $label
    assert equal ($backup_log | path exists) $backup $label
    if $backup {
      let saved = (
        ls $backup_root
        | get name
        | first
      )
      let saved_db = ($saved | path join ($db | str trim --left --char "/"))

      assert (($saved | path join "manifest.json") | path exists) $label
      assert equal (sqlite-rows $saved_db "SELECT id FROM threads ORDER BY id") $ids $label
      $saved
    }
  }
}

def make-codex [root: string, project: string]: nothing -> record {
  let dir = ($root | path join "codex")
  let db = ($dir | path join "state_5.sqlite")
  mkdir ($dir | path join "sessions")
  let rows = [
    {
      id: "parent"
      cwd: $project
      parent: null
    }
    {
      id: "child"
      cwd: "/other/worker"
      parent: "parent"
    }
    {
      id: "other-child"
      cwd: "/another/worker"
      parent: "parent"
    }
    {
      id: "retained"
      cwd: $project
      parent: null
    }
    {
      id: "nested"
      cwd: ($project | path join "sub")
      parent: null
    }
  ]
  let schema = (
    "CREATE TABLE projects (id TEXT PRIMARY KEY, path TEXT); "
    + "CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, rollout_path TEXT, "
    + "project_id TEXT REFERENCES projects(id), attached_thread_parent_id TEXT, "
    + "updated_at INTEGER, updated_at_ms INTEGER); "
    + "CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, "
    + "child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL); "
    + "CREATE TABLE dependent (thread_id TEXT REFERENCES threads(id) ON DELETE CASCADE); "
    + $"INSERT INTO projects VALUES \('shared', (sql-quote $project)\); "
  )
  $schema | ^sqlite3 $db
  "INSERT INTO thread_spawn_edges VALUES ('parent', 'child', 'completed');"
  | ^sqlite3 $db

  for row in $rows {
    let file = ($dir | path join "sessions" $"($row.id).jsonl")
    let body = [
      {
        type: "session_meta"
        payload: {
          id: $row.id
          cwd: $row.cwd
        }
      }
      {
        type: "response_item"
        payload: {
          role: "user"
          content: $"body ($row.id)"
        }
      }
    ]
    write-jsonl $file $body

    let id = (sql-quote $row.id)
    let cwd = (sql-quote $row.cwd)
    let rollout = (sql-quote $file)
    let parent = (sql-quote (if $row.id == "other-child" { $row.parent } else { null }))
    let insert = $"INSERT INTO threads VALUES \(($id), ($cwd), ($rollout), 'shared', ($parent), 1, 1000\); INSERT INTO dependent VALUES \(($id)\);"
    $insert | ^sqlite3 $db
  }

  let plain = ($dir | path join "sessions/parent.jsonl")
  let compressed = $plain + ".zst"
  (
    ^zstd $plain
      -q
      -o $compressed
  )
  rm $plain

  let history = ($dir | path join "thread_history_1.sqlite")
  let projection_schema = (
    "CREATE TABLE thread_history_projection_state (thread_id TEXT); "
    + "CREATE TABLE thread_turns (thread_id TEXT); "
    + "CREATE TABLE thread_items (thread_id TEXT); "
    + "CREATE TABLE thread_realtime_items (thread_id TEXT); "
    + "CREATE TRIGGER clear_realtime AFTER DELETE ON thread_history_projection_state "
    + "BEGIN DELETE FROM thread_realtime_items WHERE thread_id = OLD.thread_id; END; "
  )
  $projection_schema | ^sqlite3 $history
  for table in [
    "thread_history_projection_state" "thread_turns" "thread_items" "thread_realtime_items"
  ] {
    $"INSERT INTO ($table) VALUES \('parent'\), \('child'\), \('other-child'\), \('retained'\), \('nested'\);"
    | ^sqlite3 $history
  }

  {
    db: $db
    history: $history
    compressed: $compressed
  }
}

def clear-codex-sessions [fixture: record] {
  let sessions = (
    $fixture.db
    | path dirname
    | path join "sessions"
  )

  "DELETE FROM dependent; DELETE FROM thread_spawn_edges; DELETE FROM threads; DELETE FROM projects;"
  | ^sqlite3 $fixture.db
  rm --recursive $sessions
}

def bundle-ids [directory: string, assistant: string, table: string]: nothing -> list {
  open ($directory | path join $assistant "entries.json")
  | get tables
  | where table == $table
  | get 0.rows
  | get -o id
  | sort
}

def "test Codex export scopes roots and carries compressed descendants" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-codex $root $project)
  let bytes = (open --raw $fixture.compressed | hash sha256)
  let cases = [
    {
      name: "prefix"
      flags: []
      expected: ["child" "nested" "other-child" "parent" "retained"]
    }
    {
      name: "exact"
      flags: ["--exact"]
      expected: ["child" "other-child" "parent" "retained"]
    }
    {
      name: "parent"
      flags: ["--session-ids" "parent"]
      expected: ["child" "other-child" "parent"]
    }
    {
      name: "retained"
      flags: ["--session-ids" "retained"]
      expected: ["retained"]
    }
    {
      name: "child"
      flags: ["--session-ids" "child"]
      expected: ["child"]
    }
  ]

  with-env (fixture-env $root) {
    for case in $cases {
      let directory = ($root | path join $case.name)

      let scope = if $case.name == "child" { "/other" } else { $project }
      let run = (run-cli export $scope $directory --assistant "codex" ...$case.flags)
      assert equal $run.exit_code 0 $run.stderr

      assert equal (bundle-ids $directory "codex" "threads") $case.expected $case.name
      if "parent" in $case.expected {
        let entry = (
          open ($directory | path join "codex/entries.json")
          | get files
          | where thread == "parent"
          | first
        )
        let carried = ($directory | path join "codex" $entry.bundle)
        assert equal $entry.compress true
        assert equal (open --raw $carried | hash sha256) $bytes
      }
    }
  }

  let target = ($root | path join "target")
  let target_fixture = (make-codex $target $project)
  clear-codex-sessions $target_fixture

  with-env (fixture-env $target) {
    let import = (run-cli import ($root | path join "parent") --assistant "codex" --apply)
    assert equal $import.exit_code 0 $import.stderr

    assert equal (sqlite-rows $target_fixture.db "SELECT id FROM threads ORDER BY id") [
      {id: "child"}
      {id: "other-child"}
      {id: "parent"}
    ]
    assert equal (sqlite-rows $target_fixture.db "SELECT * FROM thread_spawn_edges") [
      {
        parent_thread_id: "parent"
        child_thread_id: "child"
        status: "completed"
      }
    ]
    assert equal (open --raw $target_fixture.compressed | hash sha256) $bytes

    let imported = ($root | path join "imported")
    let export = (run-cli export $project $imported --assistant "codex" --session-ids "parent")
    assert equal $export.exit_code 0 $export.stderr

    assert equal (bundle-ids $imported "codex" "threads") [
      "child" "other-child" "parent"
    ]
  }
}

def "test live Codex retirement preserves peers and removes dependent rows with backups" [] {
  for backup in [true false] {
    let root = (mktemp -d)
    let project = ($root | path join "live")
    mkdir $project
    let fixture = (make-codex $root $project)

    let saved = (apply-codex $root $fixture.db ["retire" $project "--session-ids" "parent"] $backup)

    with-env (fixture-env $root) {
      assert equal (sqlite-rows $fixture.db "SELECT id FROM threads ORDER BY id") [
        {id: "nested"}
        {id: "retained"}
      ]
      assert equal (sqlite-rows $fixture.db "SELECT * FROM dependent ORDER BY thread_id") [
        {thread_id: "nested"}
        {thread_id: "retained"}
      ]
      assert equal (sqlite-rows $fixture.db "SELECT id FROM projects") [{id: "shared"}]
      assert not ($fixture.compressed | path exists)
      assert (($root | path join "codex/sessions/retained.jsonl") | path exists)

      for table in [
        "thread_history_projection_state" "thread_turns" "thread_items" "thread_realtime_items"
      ] {
        assert equal (sqlite-rows $fixture.history $"SELECT * FROM ($table) ORDER BY thread_id") [
          {thread_id: "nested"}
          {thread_id: "retained"}
        ] $table
      }

      if $backup {
        let saved_rollout = ($saved | path join ($fixture.compressed | str trim --left --char "/"))

        assert ($saved_rollout | path exists)
      }

      let exact = (run-cli retire $project --assistant "codex" --exact --apply --no-backup)
      assert equal $exact.exit_code 0 $exact.stderr

      assert equal (sqlite-rows $fixture.db "SELECT id FROM threads") [{id: "nested"}]
      assert equal (sqlite-rows $fixture.db "SELECT id FROM projects") [{id: "shared"}]

      let last = (
        run-cli retire ($project | path join "sub") --assistant "codex" --exact --apply --no-backup
      )
      assert equal $last.exit_code 0 $last.stderr

      assert equal (sqlite-rows $fixture.db "SELECT id FROM threads") []
      assert equal (sqlite-rows $fixture.db "SELECT id FROM projects") []
    }
  }
}

def "test Codex mutations honor backup choice and preserve unrelated imports" [] {
  for operation in ["move" "import"] {
    for backup in [true false] {
      let root = (mktemp -d)
      let target = ($root | path join "target")
      let project = "/home/u/src/app"
      let live = ($root | path join "live")
      let destination = ($root | path join "moved")
      mkdir $live $destination
      let moved = ($destination | path expand)
      let fixture_project = if $operation == "import" { $live } else { $project }
      let fixture = (make-codex $target $fixture_project)
      let directory = ($root | path join "bundle")

      if $operation == "import" {
        [
          "DELETE FROM dependent WHERE thread_id != 'retained';"
          "DELETE FROM thread_spawn_edges;"
          "DELETE FROM threads WHERE id != 'retained';"
          "UPDATE projects SET id = 'live-project';"
          "UPDATE threads SET project_id = 'live-project';"
        ]
        | str join " "
        | ^sqlite3 $fixture.db

        for file in (glob ($target | path join "codex/sessions/*")) {
          if ($file | path basename) != "retained.jsonl" {
            rm $file
          }
        }

        let source = ($root | path join "source")
        let source_fixture = (make-codex $source $project)
        "UPDATE threads SET attached_thread_parent_id = NULL WHERE id = 'other-child';"
        | ^sqlite3 $source_fixture.db

        with-env (fixture-env $source) {
          let export = (
            run-cli export $project $directory --assistant "codex" --session-ids "parent"
          )
          assert equal $export.exit_code 0 $export.stderr
        }
      } else if $operation == "move" {
        "ALTER TABLE threads ADD COLUMN sandbox_policy TEXT;" | ^sqlite3 $fixture.db
      }

      let retained = ($target | path join "codex/sessions/retained.jsonl")
      let retained_body = (open --raw $retained)
      let label = $"($operation), backup=($backup)"
      let args = if $operation == "move" {
        ["move" $project $moved]
      } else {
        ["import" $directory]
      }

      apply-codex $target $fixture.db $args $backup | ignore

      with-env (fixture-env $target) {
        if $operation == "import" {
          assert equal (
            sqlite-rows $fixture.db "SELECT id, cwd, project_id FROM threads ORDER BY id"
          ) [
            {
              id: "child"
              cwd: "/other/worker"
              project_id: "shared"
            }
            {
              id: "parent"
              cwd: $project
              project_id: "shared"
            }
            {
              id: "retained"
              cwd: $live
              project_id: "live-project"
            }
          ] $label
          assert equal (sqlite-rows $fixture.db "SELECT * FROM thread_spawn_edges") [
            {
              parent_thread_id: "parent"
              child_thread_id: "child"
              status: "completed"
            }
          ] $label
          assert equal (
            sqlite-rows $fixture.db "SELECT * FROM dependent"
          ) [{thread_id: "retained"}] $label
          assert equal (open --raw $retained) $retained_body $label
          assert ($fixture.compressed | path exists) $label
          assert (($target | path join "codex/sessions/child.jsonl") | path exists) $label
        } else {
          assert equal (sqlite-rows $fixture.db "SELECT cwd FROM threads WHERE id = 'parent'") [
            {cwd: $moved}
          ] $label
        }
      }
    }
  }
}

def "test selecting a Codex child preserves its parent and sibling sessions" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-codex $root $project)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export "/other" $directory --assistant "codex" --session-ids "child")
    assert equal $export.exit_code 0 $export.stderr

    let edge = (
      open ($directory | path join "codex/entries.json")
      | get tables
      | where table == "thread_spawn_edges"
      | get 0.rows
    )

    assert equal (bundle-ids $directory "codex" "threads") ["child"]
    assert equal $edge [
      {
        parent_thread_id: "parent"
        child_thread_id: "child"
        status: "completed"
      }
    ]

    let apply = (
      run-cli retire "/other" --assistant "codex" --session-ids "child" --apply --no-backup
    )
    assert equal $apply.exit_code 0 $apply.stderr

    assert equal (sqlite-rows $fixture.db "SELECT id FROM threads ORDER BY id") [
      {id: "nested"}
      {id: "other-child"}
      {id: "parent"}
      {id: "retained"}
    ]
    assert ($fixture.compressed | path exists)
  }

  let target = ($root | path join "target")
  let target_fixture = (make-codex $target $project)
  clear-codex-sessions $target_fixture

  with-env (fixture-env $target) {
    let import = (run-cli import $directory --assistant "codex" --apply)
    assert equal $import.exit_code 0 $import.stderr

    assert equal (sqlite-rows $target_fixture.db "SELECT id FROM threads") [{id: "child"}]
    assert equal (sqlite-rows $target_fixture.db "SELECT * FROM thread_spawn_edges") [
      {
        parent_thread_id: "parent"
        child_thread_id: "child"
        status: "completed"
      }
    ]
  }
}

def "test an imported Codex id with different rollout content is rejected" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-codex $root $project)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export $project $directory --assistant "codex" --session-ids "parent")
    assert equal $export.exit_code 0 $export.stderr

    "DELETE FROM thread_spawn_edges;" | ^sqlite3 $fixture.db

    let restore = (run-cli import $directory --assistant "codex" --apply)
    assert equal $restore.exit_code 0 $restore.stderr

    assert equal (sqlite-rows $fixture.db "SELECT * FROM thread_spawn_edges") [
      {
        parent_thread_id: "parent"
        child_thread_id: "child"
        status: "completed"
      }
    ]

    let same = (run-cli import $directory --assistant "codex")
    assert equal $same.exit_code 0 $same.stderr
    assert str contains $same.stdout "Skipped"

    "UPDATE thread_spawn_edges SET parent_thread_id = 'retained';" | ^sqlite3 $fixture.db

    let relation_conflict = (run-cli import $directory --assistant "codex" --apply)

    assert ($relation_conflict.exit_code != 0) $relation_conflict.stdout
    assert equal (sqlite-rows $fixture.db "SELECT * FROM thread_spawn_edges") [
      {
        parent_thread_id: "retained"
        child_thread_id: "child"
        status: "completed"
      }
    ]

    "UPDATE thread_spawn_edges SET parent_thread_id = 'parent';" | ^sqlite3 $fixture.db

    let entry = (
      open ($directory | path join "codex/entries.json")
      | get files
      | where thread == "parent"
      | first
    )
    let carried = ($directory | path join "codex" $entry.bundle)
    let changed = (
      {
        type: "response_item"
        payload: {
          role: "user"
          content: "different body"
        }
      }
      | to json --raw
    )
    let compression = (
      $changed
      | ^zstd
          -q
          -f
          -o $carried
      | complete
    )
    assert equal $compression.exit_code 0 $compression.stderr

    let before = (open --raw $fixture.db | hash sha256)

    let different = (run-cli import $directory --assistant "codex" --apply)

    assert ($different.exit_code != 0) $different.stdout
    assert equal (open --raw $fixture.db | hash sha256) $before
  }
}

def make-target-codex [root: string, project: string]: nothing -> record {
  let fixture = (make-codex $root $project)
  (
    "DROP TABLE projects; "
    + "CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, metadata TEXT, position INTEGER, "
    + "created_at_ms INTEGER, updated_at_ms INTEGER); "
    + "CREATE TABLE project_roots (project_id TEXT, position INTEGER, path TEXT); "
    + "ALTER TABLE threads ADD COLUMN sandbox_policy TEXT; "
    + "ALTER TABLE threads ADD COLUMN agent_path TEXT;"
  ) | ^sqlite3 $fixture.db

  let metadata = (
    {source: $project}
    | to json --raw
    | sql-quote $in
  )
  let policy = (
    {writable_roots: [$project]}
    | to json --raw
    | sql-quote $in
  )
  $"INSERT INTO projects VALUES \('shared', 'Example', ($metadata), 2, 1001, 2002\); INSERT INTO project_roots VALUES \('shared', 0, (sql-quote $project)\), \('shared', 1, (sql-quote ($project + '/worktree'))\); UPDATE threads SET sandbox_policy = ($policy), agent_path = (sql-quote ($project + '/logical-agent'));"
  | ^sqlite3 $fixture.db

  let plain = ($fixture.compressed | str replace --regex '\.zst$' '')
  write-jsonl $plain [
    {
      type: "session_meta"
      payload: {
        id: "parent"
        cwd: $project
        timestamp: "2026-01-01T00:00:00.123456789Z"
      }
    }
    {
      type: "response_item"
      payload: {
        path: ($project + "/file.txt")
        uri: ("file://" + $project + "/file.txt")
        sibling: ($project + "-peer/file.txt")
      }
    }
  ]

  (
    ^zstd $plain
      -q
      -f
      -o $fixture.compressed
  )
  rm $plain
  ^touch -d "2026-01-01T00:00:00.123456789Z" $fixture.compressed

  $fixture
}

def "test targeted Codex imports map incoming paths and preserve local state" [] {
  let root = (mktemp -d)
  let source = ($root | path join "source")
  let local = ($root | path join "local")
  let project = "/home/u/src/app"
  let target = $project + "/relocated"
  let fixture = (make-target-codex $source $project)
  let destination = (make-target-codex $local "/other/live")
  let directory = ($root | path join "bundle")
  let metadata = (sqlite-rows $fixture.db "SELECT * FROM projects")
  let timestamp = (with-env {TZ: "UTC"} { ^stat -c "%y" $fixture.compressed })

  "DELETE FROM dependent WHERE thread_id != 'retained'; DELETE FROM thread_spawn_edges; DELETE FROM threads WHERE id != 'retained'; UPDATE projects SET id = 'live'; UPDATE project_roots SET project_id = 'live'; UPDATE threads SET project_id = 'live';"
  | ^sqlite3 $destination.db

  let opaque = (
    {source: $project}
    | to json --raw
    | sql-quote $in
  )
  let policy = (
    {writable_roots: [$project]}
    | to json --raw
    | sql-quote $in
  )
  $"UPDATE projects SET metadata = ($opaque); UPDATE threads SET sandbox_policy = ($policy), agent_path = (sql-quote ($project + '/local-agent'));"
  | ^sqlite3 $destination.db

  let sessions = ($local | path join "codex/sessions")
  for file in (glob ($sessions | path join "*")) {
    if ($file | path basename) != "retained.jsonl" {
      rm $file
    }
  }
  let retained = ($sessions | path join "retained.jsonl")
  {cwd: $project}
  | to json
  | save --force $retained

  let desktop = ($local | path join "codex/.codex-global-state.json")
  {saved: [$project]}
  | to json
  | save $desktop

  let local_rows = (sqlite-rows $destination.db "SELECT * FROM threads")
  let local_project = (sqlite-rows $destination.db "SELECT * FROM projects")
  let retained_bytes = (open --raw $retained)
  let desktop_bytes = (open --raw $desktop)
  let projection_bytes = (open --raw $destination.history | hash sha256)

  with-env (fixture-env $source) {
    let export = (
      run-cli export $project $directory --assistant "codex" --session-ids "parent,nested"
    )
    assert equal $export.exit_code 0 $export.stderr
  }

  with-env (fixture-env $local) {
    $"INSERT INTO projects VALUES \('shared', 'Local', '{}', 9, 3003, 4004\); INSERT INTO project_roots VALUES \('shared', 0, (sql-quote ($target + '/worktree'))\), \('shared', 1, (sql-quote $target)\);"
    | ^sqlite3 $destination.db
    let conflicting = (open --raw $destination.db | hash sha256)

    let refused = (
      run-cli import $directory --assistant "codex" --target $target --no-backup --apply
    )
    assert ($refused.exit_code != 0) $refused.stdout
    assert str contains $refused.stderr "different roots"

    assert equal (open --raw $destination.db | hash sha256) $conflicting
    assert not (($sessions | path join "parent.jsonl.zst") | path exists)

    "DELETE FROM project_roots WHERE project_id = 'shared'; DELETE FROM projects WHERE id = 'shared';"
    | ^sqlite3 $destination.db
    let before = (open --raw $destination.db | hash sha256)

    let preview = (run-cli import $directory --assistant "codex" --target $target --no-backup)
    assert equal $preview.exit_code 0 $preview.stderr

    assert equal (open --raw $destination.db | hash sha256) $before
    assert not (($sessions | path join "parent.jsonl.zst") | path exists)

    let import = (
      run-cli import $directory --assistant "codex" --target $target --no-backup --apply
    )
    assert equal $import.exit_code 0 $import.stderr

    assert equal (
      sqlite-rows $destination.db "SELECT * FROM threads WHERE id = 'retained'"
    ) $local_rows
    assert equal (
      sqlite-rows $destination.db "SELECT * FROM projects WHERE id = 'live'"
    ) $local_project
    assert equal (
      sqlite-rows $destination.db "SELECT * FROM projects WHERE id = 'shared'"
    ) $metadata
    assert equal (open --raw $retained) $retained_bytes
    assert equal (open --raw $desktop) $desktop_bytes
    assert equal (open --raw $destination.history | hash sha256) $projection_bytes

    let roots_query = "SELECT path FROM project_roots WHERE project_id = 'shared' ORDER BY position"
    let roots = (
      sqlite-rows $destination.db $roots_query
      | get path
    )

    assert equal $roots [$target ($target + "/worktree")]

    let rows = (
      sqlite-rows $destination.db "SELECT * FROM threads WHERE id != 'retained' ORDER BY id"
    )

    assert equal ($rows | select id cwd) [
      {
        id: "child"
        cwd: "/other/worker"
      }
      {
        id: "nested"
        cwd: ($target + "/sub")
      }
      {
        id: "other-child"
        cwd: "/another/worker"
      }
      {
        id: "parent"
        cwd: $target
      }
    ]
    for row in $rows {
      assert equal $row.agent_path ($project + "/logical-agent") $row.id
      assert equal $row.updated_at_ms 1000 $row.id
      assert equal ($row.sandbox_policy | from json) {writable_roots: [$target]} $row.id
      assert equal $row.rollout_path ($sessions | path join $"($row.id).jsonl") $row.id
    }
    assert equal (sqlite-rows $destination.db "SELECT * FROM thread_spawn_edges") [
      {
        parent_thread_id: "parent"
        child_thread_id: "child"
        status: "completed"
      }
    ]
    assert equal (
      $rows
      | where id == "other-child"
      | get 0.attached_thread_parent_id
    ) "parent"

    let compressed = ($sessions | path join "parent.jsonl.zst")
    let content = (
      ^zstd -dc $compressed
      | lines
      | each {|line| $line | from json }
    )

    assert equal ($content | get 0.payload) {
      id: "parent"
      cwd: $target
      timestamp: "2026-01-01T00:00:00.123456789Z"
    }
    assert equal ($content | get 1.payload) {
      path: ($target + "/file.txt")
      uri: ("file://" + $target + "/file.txt")
      sibling: ($project + "-peer/file.txt")
    }
    assert equal (^stat -c "%y" $compressed) $timestamp

    "UPDATE projects SET name = 'Destination metadata', position = 8 WHERE id = 'shared';"
    | ^sqlite3 $destination.db
    let reused = (sqlite-rows $destination.db "SELECT * FROM projects WHERE id = 'shared'")

    let repeated = (
      run-cli import $directory --assistant "codex" --target $target --no-backup --apply
    )
    assert equal $repeated.exit_code 0 $repeated.stderr
    assert str contains $repeated.stdout "No changes"
    assert equal (sqlite-rows $destination.db "SELECT * FROM projects WHERE id = 'shared'") $reused

    let stable = (open --raw $destination.db | hash sha256)
    let other = "/other/destination"

    let conflict = (
      run-cli import $directory --assistant "codex" --target $other --no-backup --apply
    )
    assert ($conflict.exit_code != 0) $conflict.stdout

    assert equal (open --raw $destination.db | hash sha256) $stable
    assert equal (^stat -c "%y" $compressed) $timestamp
  }
}

def make-claude [root: string, project: string]: nothing -> record {
  let config = ($root | path join "claude")
  let dir = ($config | path join "projects" (encode-path $project))
  let nested = ($config | path join "projects" (encode-path ($project | path join "sub")))

  for row in [
    {
      id: "parent"
      dir: $dir
      cwd: $project
    }
    {
      id: "retained"
      dir: $dir
      cwd: "/other/retained"
    }
    {
      id: "nested"
      dir: $nested
      cwd: ($project | path join "sub")
    }
  ] {
    let body = [
      {
        type: "user"
        sessionId: $row.id
        cwd: $row.cwd
        message: {content: $row.id}
      }
    ]
    let visits = if $row.id == "parent" {
      [
        {
          type: "system"
          sessionId: $row.id
          cwd: "/other/visited"
        }
      ]
    } else {
      []
    }

    write-jsonl ($row.dir | path join $"($row.id).jsonl") ($body ++ $visits)
  }

  let child = ($dir | path join "parent/subagents/agent-child.jsonl")
  write-jsonl $child [
    {
      type: "assistant"
      sessionId: "child"
      cwd: "/other/worker"
      message: {
        content: [{type: "tool_use", id: "read-child", name: "Read", input: {file_path: $project}}]
      }
    }
  ]

  $'{ "path": "($project)" }' | save ($dir | path join "sessions-index.json")
  mkdir ($dir | path join "memory")
  "shared memory" | save ($dir | path join "memory/MEMORY.md")
  write-jsonl ($dir | path join "memory/notes.jsonl") [
    {sessionId: "notes", cwd: $project, message: {content: "shared notes"}}
  ]
  for name in ["output.json" "output.jsonl"] {
    $'{ "cwd": "($project)", "sessionId": "artifact" }'
    | save ($dir | path join "parent" $name)
  }

  mkdir ($config | path join "file-history/parent")
  "original artifact" | save ($config | path join "file-history/parent/file@v1")
  mkdir ($config | path join "file-history/child")
  "child artifact" | save ($config | path join "file-history/child/child@v1")
  mkdir ($config | path join "file-history/retained")
  "retained artifact" | save ($config | path join "file-history/retained/file@v1")
  mkdir ($config | path join "file-history/nested")
  "nested artifact" | save ($config | path join "file-history/nested/file@v1")

  write-jsonl ($config | path join "history.jsonl") [
    {
      sessionId: "parent"
      project: $project
      display: "parent"
    }
    {
      sessionId: "retained"
      project: $project
      display: "retained"
    }
    {
      sessionId: "nested"
      project: ($project | path join "sub")
      display: "nested"
    }
  ]

  {
    projects: {
      ($project): {hasTrustDialogAccepted: true}
      ($project | path join "sub"): {hasTrustDialogAccepted: true}
    }
    githubRepoPaths: {"example/app": [$project ($project | path join "sub")]}
  }
  | to json
  | save ($config | path join ".claude.json")

  {
    dir: $dir
    nested: $nested
    child: $child
    config: $config
  }
}

def "test Claude project moves preserve opaque files and reject memory conflicts" [] {
  for conflict in [false true] {
    let root = (mktemp -d)
    let project = "/home/u/src/app"
    let target = "/home/u/destination"
    let fixture = (make-claude $root $project)
    let destination = ($fixture.config | path join "projects" (encode-path $target))
    let state = ["history.jsonl" ".claude.json" "teams/example/config.json"]
    mkdir ($fixture.config | path join "teams/example")
    $project | save ($fixture.config | path join "teams/example/config.json")
    let originals = ($state | each {|name| open --raw ($fixture.config | path join $name) })
    let opaque = [
      "sessions-index.json" "memory/MEMORY.md" "memory/notes.jsonl"
      "parent/output.json" "parent/output.jsonl"
    ]
    let contents = ($opaque | each {|name| open --raw ($fixture.dir | path join $name) })
    let session = (open --raw ($fixture.dir | path join "parent.jsonl"))
    if $conflict {
      mkdir ($destination | path join "memory")
      "other memory" | save ($destination | path join "memory/MEMORY.md")
    }

    let result = (with-env (fixture-env $root) {
      run-cli move $project $target --assistant "claude" --apply --no-backup
    })

    if $conflict {
      assert ($result.exit_code != 0) $result.stdout
      assert equal (open --raw ($fixture.dir | path join "parent.jsonl")) $session
      assert equal (open --raw ($destination | path join "memory/MEMORY.md")) "other memory"
    } else {
      assert equal $result.exit_code 0 $result.stderr
      assert not ($fixture.dir | path exists)
      assert equal ($opaque | each {|name| open --raw ($destination | path join $name) }) $contents
      assert equal (
        open --raw ($destination | path join "parent.jsonl")
        | lines
        | each {|line| $line | from json | get cwd }
      ) [$target "/other/visited"]
      assert equal (
        open --raw ($destination | path join "parent/subagents/agent-child.jsonl")
        | from json
        | get cwd
      ) "/other/worker"
      assert equal (
        open --raw ($destination | path join "parent/subagents/agent-child.jsonl")
        | from json
        | get message.content.0.input.file_path
      ) $target
    }
    assert equal ($state | each {|name| open --raw ($fixture.config | path join $name) }) $originals
  }
}

def "test an explicit Claude move locates a project with only outside cwd records" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let target = "/home/u/destination"
  let source = ($root | path join "claude/projects" (encode-path $project))
  let destination = ($root | path join "claude/projects" (encode-path $target))
  write-jsonl ($source | path join "parent.jsonl") [
    {type: "user", sessionId: "parent", cwd: "/other/visited", message: {content: "parent"}}
  ]
  let original = (open --raw ($source | path join "parent.jsonl"))

  let moved = (with-env (fixture-env $root) {
    run-cli move $project $target --assistant "claude" --apply --no-backup
  })
  assert equal $moved.exit_code 0 $moved.stderr

  assert not ($source | path exists)
  assert equal (open --raw ($destination | path join "parent.jsonl")) $original
}

def "test Claude selected parents carry subagents and preserve shared project state" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-claude $root $project)
  let directory = ($root | path join "bundle")
  let state = ["history.jsonl" ".claude.json"]
  let originals = ($state | each {|name| open --raw ($fixture.config | path join $name) })
  let shared = ["memory/MEMORY.md" "memory/notes.jsonl" "sessions-index.json"]
  let shared_contents = ($shared | each {|name| open --raw ($fixture.dir | path join $name) })

  with-env (fixture-env $root) {
    let complete = ($root | path join "complete")
    let default_export = (run-cli export $project $complete --assistant "claude")
    assert equal $default_export.exit_code 0 $default_export.stderr

    assert equal (
      open ($complete | path join "claude/entries.json")
      | get files
      | where kind == "file-history"
      | get session
      | uniq
      | sort
    ) ["child" "nested" "parent"]

    let export = (run-cli export $project $directory --assistant "claude" --session-ids "parent")
    assert equal $export.exit_code 0 $export.stderr

    let entries = (open ($directory | path join "claude/entries.json"))
    assert equal (
      $entries.files
      | where kind == "projects"
      | get name
      | sort
    ) [
      "parent.jsonl"
      "parent/output.json"
      "parent/output.jsonl"
      "parent/subagents/agent-child.jsonl"
    ]
    assert equal (
      $entries.files
      | where kind == "projects"
      | get project
      | uniq
    ) [$project]
    assert equal (
      $entries.files
      | where kind == "file-history"
      | get name
      | sort
    ) [
      "child@v1" "file@v1"
    ]

    let apply = (
      run-cli retire $project --assistant "claude" --session-ids "parent" --apply --no-backup
    )
    assert equal $apply.exit_code 0 $apply.stderr

    assert not (($fixture.dir | path join "parent.jsonl") | path exists)
    assert not ($fixture.child | path exists)
    assert not (($fixture.config | path join "file-history/parent") | path exists)
    assert not (($fixture.config | path join "file-history/child") | path exists)
    assert (($fixture.dir | path join "retained.jsonl") | path exists)
    assert (($fixture.nested | path join "nested.jsonl") | path exists)
    assert equal ($shared | each {|name| open --raw ($fixture.dir | path join $name) }) $shared_contents
    assert equal ($state | each {|name| open --raw ($fixture.config | path join $name) }) $originals

    let final = (run-cli retire "/other/retained" --assistant "claude" --exact --apply --no-backup)
    assert equal $final.exit_code 0 $final.stderr

    assert not (($fixture.dir | path join "retained.jsonl") | path exists)
    assert (($fixture.nested | path join "nested.jsonl") | path exists)
    assert equal ($shared | each {|name| open --raw ($fixture.dir | path join $name) }) $shared_contents
    assert equal ($state | each {|name| open --raw ($fixture.config | path join $name) }) $originals

    let excluded = (
      run-cli export $project ($root | path join "notes") --assistant "claude" --session-ids "notes"
    )
    assert ($excluded.exit_code != 0) $excluded.stdout
  }
}

def "test selecting a Claude subagent preserves its parent and other project files" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-claude $root $project)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export "/other" $directory --assistant "claude" --session-ids "child")
    assert equal $export.exit_code 0 $export.stderr

    let entries = (open ($directory | path join "claude/entries.json"))
    assert equal (
      $entries.files
      | where kind == "projects"
      | get name
      | sort
    ) ["parent/subagents/agent-child.jsonl"]
    assert equal (
      $entries.files
      | where kind == "file-history"
      | get name
    ) ["child@v1"]

    let local = ($root | path join "local")
    let target = "/home/u/destination"
    let local_dir = ($local | path join "claude/projects" (encode-path $project))
    mkdir ($local_dir | path join "memory")
    "local memory" | save ($local_dir | path join "memory/MEMORY.md")
    let settings = ($local | path join "claude/.claude.json")
    '{"opaque":"unchanged"}' | save $settings
    with-env (fixture-env $local) {
      let import = (
        run-cli import $directory --assistant "claude" --target $target --apply --no-backup
      )
      assert equal $import.exit_code 0 $import.stderr

      let imported = ($local_dir | path join "parent/subagents/agent-child.jsonl")
      assert equal (open --raw $imported | from json | get cwd) ($target + "/worker")
      let scan = (run-cli scan --assistant "claude")
      assert equal $scan.exit_code 0 $scan.stderr
      assert str contains $scan.stdout ($target + "/worker")

      let retired = (
        run-cli retire $target --assistant "claude" --session-ids "child" --apply --no-backup
      )
      assert equal $retired.exit_code 0 $retired.stderr

      assert not ($imported | path exists)
      assert equal (open --raw ($local_dir | path join "memory/MEMORY.md")) "local memory"
      assert equal (open --raw $settings) '{"opaque":"unchanged"}'
    }

    let apply = (
      run-cli retire "/other" --assistant "claude" --session-ids "child" --apply --no-backup
    )
    assert equal $apply.exit_code 0 $apply.stderr

    assert not ($fixture.child | path exists)
    assert (($fixture.dir | path join "parent.jsonl") | path exists)
    assert (($fixture.dir | path join "retained.jsonl") | path exists)
    assert (($fixture.nested | path join "nested.jsonl") | path exists)
    assert (($fixture.config | path join "file-history/parent/file@v1") | path exists)
    assert equal (open --raw ($fixture.dir | path join "memory/MEMORY.md")) "shared memory"
  }
}

def "test identical Claude sessions still import and validate their file history" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-claude $root $project)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export $project $directory --assistant "claude" --session-ids "parent")
    assert equal $export.exit_code 0 $export.stderr
    rm --recursive ($fixture.config | path join "file-history")

    let import = (run-cli import $directory --assistant "claude" --apply)
    assert equal $import.exit_code 0 $import.stderr

    assert equal (
      open --raw ($fixture.config | path join "file-history/parent/file@v1")
    ) "original artifact"
    assert equal (
      open --raw ($fixture.config | path join "file-history/child/child@v1")
    ) "child artifact"

    "different artifact" | save --force ($fixture.config | path join "file-history/child/child@v1")

    let conflict = (run-cli import $directory --assistant "claude" --apply)

    assert ($conflict.exit_code != 0) $conflict.stdout
    assert equal (
      open --raw ($fixture.config | path join "file-history/child/child@v1")
    ) "different artifact"

    "child artifact" | save --force ($fixture.config | path join "file-history/child/child@v1")
    let session = ($fixture.dir | path join "parent.jsonl")
    "changed transcript" | save --append $session
    let changed = (open --raw $session)

    let session_conflict = (run-cli import $directory --assistant "claude" --apply)

    assert ($session_conflict.exit_code != 0) $session_conflict.stdout
    assert equal (open --raw $session) $changed
  }
}

def "test Claude imports keep missing artifacts with their physical session owner" [] {
  let project = "/home/u/src/app"
  for case in [
    {name: "same owner", owner: $project, artifact: true, succeeds: true}
    {name: "other owner", owner: "/home/u/other", artifact: true, succeeds: false}
    {name: "already imported", owner: "/home/u/other", artifact: false, succeeds: true}
  ] {
    let root = (mktemp -d)
    let source = ($root | path join "source")
    let local = ($root | path join "local")
    let source_dir = ($source | path join "claude/projects" (encode-path $project))
    let local_root = ($local | path join "claude/projects")
    let local_dir = ($local_root | path join (encode-path $case.owner))
    let directory = ($root | path join "bundle")
    write-jsonl ($source_dir | path join "parent.jsonl") [
      {type: "user", sessionId: "parent", cwd: $project, message: {content: "parent"}}
    ]
    if $case.artifact {
      mkdir ($source_dir | path join "parent")
      "owned note" | save ($source_dir | path join "parent/notes.md")
    }
    mkdir $local_dir
    ^cp ($source_dir | path join "parent.jsonl") ($local_dir | path join "parent.jsonl")
    let before = (open --raw ($local_dir | path join "parent.jsonl"))
    let export = (with-env (fixture-env $source) {
      run-cli export $project $directory --assistant "claude" --session-ids "parent"
    })
    assert equal $export.exit_code 0 $export.stderr

    let import = (with-env (fixture-env $local) {
      run-cli import $directory --assistant "claude" --apply --no-backup
    })

    assert equal ($import.exit_code == 0) $case.succeeds $case.name
    assert equal (open --raw ($local_dir | path join "parent.jsonl")) $before $case.name
    if $case.artifact and $case.succeeds {
      assert equal (open --raw ($local_dir | path join "parent/notes.md")) "owned note"
    } else if $case.succeeds {
      assert str contains $import.stdout "No changes" $case.name
    } else {
      assert not (($local_root | path join (encode-path $project)) | path exists) $case.name
      assert not (($local_dir | path join "parent") | path exists) $case.name
    }
  }
}

def "test targeted Claude imports preserve local sessions and opaque file history" [] {
  let root = (mktemp -d)
  let source = ($root | path join "source")
  let local = ($root | path join "local")
  let project = "/home/u/src/app"
  let target = "/home/u/destination"
  let fixture = (make-claude $source $project)
  let directory = ($root | path join "bundle")
  let config = ($local | path join "claude")
  let retained = ($config | path join "projects" (encode-path "/other/live") "local.jsonl")
  write-jsonl $retained [
    {
      type: "user"
      sessionId: "local"
      cwd: "/other/live"
      message: {content: $project}
    }
  ]
  {
    projects: {"/other/live": {note: $project}}
    opaque: $project
  }
  | to json
  | save ($config | path join ".claude.json")
  let history = ($fixture.config | path join "file-history/parent/file@v1")
  $project | save --force $history
  let bytes = (open --raw $retained)

  with-env (fixture-env $source) {
    let export = (
      run-cli export $project $directory --assistant "claude" --session-ids "parent,nested"
    )
    assert equal $export.exit_code 0 $export.stderr
  }

  let entries = ($directory | path join "claude/entries.json")
  ^cp ($fixture.dir | path join "memory/notes.jsonl") ($directory | path join "claude/files/notes")
  open $entries
  | update files {
    $in | append {
      kind: "projects"
      project: $project
      name: "memory/notes.jsonl"
      bundle: "files/notes"
    }
  }
  | to json
  | save --force $entries

  with-env (fixture-env $local) {
    let preview = (run-cli import $directory --assistant "claude" --target $target --no-backup)
    assert equal $preview.exit_code 0 $preview.stderr

    assert not (($config | path join "file-history/parent") | path exists)
    assert equal (open --raw $retained) $bytes

    let import = (
      run-cli import $directory --assistant "claude" --target $target --no-backup --apply
    )
    assert equal $import.exit_code 0 $import.stderr

    let owner = ($config | path join "projects" (encode-path $target))
    let body = (
      open --raw ($owner | path join "parent.jsonl")
      | lines
      | each {|line| $line | from json }
    )
    let nested = ($config | path join "projects" (encode-path ($target + "/sub")) "nested.jsonl")
    let child = ($owner | path join "parent/subagents/agent-child.jsonl")
    let settings = (open ($config | path join ".claude.json"))

    assert equal ($body | get cwd) [$target "/other/visited"]
    assert equal ($body | get sessionId) ["parent" "parent"]
    assert equal (
      open --raw $nested
      | from json
      | get cwd
    ) ($target + "/sub")
    assert equal (
      open --raw $child
      | from json
      | get cwd
    ) "/other/worker"
    assert equal (
      open --raw $child
      | from json
      | get message.content.0.input.file_path
    ) $target
    assert equal (open --raw ($config | path join "file-history/parent/file@v1")) $project
    assert equal (open --raw ($config | path join "file-history/child/child@v1")) "child artifact"
    for name in ["output.json" "output.jsonl"] {
      assert equal (
        open --raw ($owner | path join "parent" $name)
      ) (open --raw ($fixture.dir | path join "parent" $name)) $name
    }
    assert not (($owner | path join "memory") | path exists)
    assert equal (open --raw $retained) $bytes
    assert equal $settings.opaque $project
    assert equal ($settings.projects | get "/other/live") {note: $project}

    let repeated = (
      run-cli import $directory --assistant "claude" --target $target --no-backup --apply
    )
    assert equal $repeated.exit_code 0 $repeated.stderr
    assert str contains $repeated.stdout "No changes"
  }
}

def make-omp [root: string, project: string]: nothing -> record {
  let dir = ($root | path join "omp/sessions" (session-encode-here $project))
  let parent_file = ($dir | path join "2026-01-01T00-00-00_parent.jsonl")
  let child_root = ($dir | path join "2026-01-01T00-00-00_parent")

  for row in [
    {
      id: "parent"
      cwd: $project
      parentSession: null
      file: $parent_file
    }
    {
      id: "child"
      cwd: $project
      parentSession: "parent"
      file: ($child_root | path join "implementer/worker.jsonl")
    }
    {
      id: "grandchild"
      cwd: "/other/deeper"
      parentSession: ($child_root | path join "implementer/worker.jsonl")
      file: ($child_root | path join "reviewer/worker.jsonl")
    }
    {
      id: "sibling"
      cwd: $project
      parentSession: "parent"
      file: ($child_root | path join "auditor/agent.jsonl")
    }
    {
      id: "retained"
      cwd: $project
      parentSession: null
      file: ($dir | path join "retained.jsonl")
    }
  ] {
    write-jsonl $row.file [
      {
        type: "title"
        title: "A session title"
      }
      (
        $row
        | reject file
        | merge {
          type: "session"
          version: 3
          timestamp: "2026-01-01T00:00:00Z"
        }
      )
      {
        type: "message"
        id: "message"
        message: {
          role: "user"
          content: $row.id
        }
      }
    ]
  }

  "worker log" | save ($child_root | path join "implementer/worker.log")
  mkdir ($child_root | path join "implementer/worker")
  "child log" | save ($child_root | path join "implementer/worker/run.log")
  mkdir ($child_root | path join "reviewer/worker")
  {result: "child review"}
  | to json
  | save ($child_root | path join "reviewer/worker/result.json")

  {result: "review"}
  | to json
  | save ($child_root | path join "reviewer/result.json")

  "task notes" | save ($child_root | path join "notes.md")

  {
    dir: $dir
    parent: $parent_file
    children: $child_root
  }
}

def "test OMP file-only retirement preserves peers and backs up nested artifacts" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-omp $root $project)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export $project $directory --assistant "omp" --session-ids "parent")
    assert equal $export.exit_code 0 $export.stderr

    assert equal (
      open ($directory | path join "omp/entries.json")
      | get files
      | where kind == "sessions"
      | get name
      | sort
    ) [
      "2026-01-01T00-00-00_parent.jsonl"
      "2026-01-01T00-00-00_parent/auditor/agent.jsonl"
      "2026-01-01T00-00-00_parent/implementer/worker.jsonl"
      "2026-01-01T00-00-00_parent/implementer/worker.log"
      "2026-01-01T00-00-00_parent/implementer/worker/run.log"
      "2026-01-01T00-00-00_parent/notes.md"
      "2026-01-01T00-00-00_parent/reviewer/result.json"
      "2026-01-01T00-00-00_parent/reviewer/worker.jsonl"
      "2026-01-01T00-00-00_parent/reviewer/worker/result.json"
    ]

    let apply = (run-cli retire $project --assistant "omp" --session-ids "parent" --apply)
    assert equal $apply.exit_code 0 $apply.stderr

    assert not ($fixture.parent | path exists)
    assert not ($fixture.children | path exists)
    assert (($fixture.dir | path join "retained.jsonl") | path exists)

    let backup = (
      ls ($root | path join "state/agent-project-move")
      | get name
      | first
    )
    let subtree = ($backup | path join ($fixture.children | str trim --left --char "/"))
    for artifact in [
      {name: "implementer/worker.log", body: "worker log"}
      {name: "notes.md", body: "task notes"}
      {name: "reviewer/result.json", body: ({result: "review"} | to json)}
    ] {
      assert equal (open --raw ($subtree | path join $artifact.name)) $artifact.body
    }
    assert (($subtree | path join "implementer/worker.jsonl") | path exists)
    assert (($subtree | path join "reviewer/worker.jsonl") | path exists)

    let final = (run-cli retire $project --assistant "omp" --exact --apply --no-backup)
    assert equal $final.exit_code 0 $final.stderr

    assert not (($fixture.dir | path join "retained.jsonl") | path exists)
  }
}

def "test selecting an OMP child carries only its descendants and own artifact subtree" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-omp $root $project)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export $project $directory --assistant "omp" --session-ids "child")
    assert equal $export.exit_code 0 $export.stderr

    assert equal (
      open ($directory | path join "omp/entries.json")
      | get files
      | where kind == "sessions"
      | get name
      | sort
    ) [
      "2026-01-01T00-00-00_parent/implementer/worker.jsonl"
      "2026-01-01T00-00-00_parent/implementer/worker/run.log"
      "2026-01-01T00-00-00_parent/reviewer/worker.jsonl"
      "2026-01-01T00-00-00_parent/reviewer/worker/result.json"
    ]

    let apply = (
      run-cli retire $project --assistant "omp" --session-ids "child" --apply --no-backup
    )
    assert equal $apply.exit_code 0 $apply.stderr

    assert ($fixture.parent | path exists)
    assert (($fixture.children | path join "notes.md") | path exists)
    assert (($fixture.children | path join "auditor/agent.jsonl") | path exists)
    assert (($fixture.children | path join "implementer/worker.log") | path exists)
    assert (($fixture.children | path join "reviewer/result.json") | path exists)
    assert not (($fixture.children | path join "implementer/worker.jsonl") | path exists)
    assert not (($fixture.children | path join "implementer/worker") | path exists)
    assert not (($fixture.children | path join "reviewer/worker.jsonl") | path exists)
    assert not (($fixture.children | path join "reviewer/worker") | path exists)
    assert (($fixture.dir | path join "retained.jsonl") | path exists)
  }
}

def "test OMP scans and transfers session files without touching auxiliary state" [] {
  let root = (mktemp -d | path expand)
  let source = ($root | path join "source")
  let target = ($root | path join "target")
  let moved = ($root | path join "moved")
  let project = "/home/u/src/app"
  let fixture = (make-omp $source $project)
  let archive = (
    $source | path join "omp/archive/sessions" (session-encode-here $project) "archived.jsonl"
  )
  for file in (glob ($fixture.dir | path join "**/*.jsonl")) {
    ^touch -d "2026-01-01T00:00:00Z" $file
  }
  write-jsonl $archive [
    {type: "session", id: "archived", cwd: "/other/deeper", parentSession: "parent"}
  ]
  ^touch -d "2026-01-02T00:00:00Z" $archive
  mkdir $moved

  let databases = ["agent.db" "history.db"]
  for name in $databases {
    let db = ($source | path join "omp" $name)
    $"CREATE TABLE kept \(cwd TEXT\); INSERT INTO kept VALUES \((sql-quote $project)\);"
    | ^sqlite3 $db
  }
  let memory = ($source | path join "state/omp/memories/--home-u-src-app--/MEMORY.md")
  mkdir ($memory | path dirname)
  [$project] | to json | save $memory
  let untouched = (
    ($databases | each {|name| $source | path join "omp" $name })
    | append $memory
    | each {|file| {file: $file, hash: (open --raw $file | hash sha256)} }
  )
  let directory = ($root | path join "bundle")

  with-env (fixture-env $source) {
    let created = ("2026-01-01T00:00:00Z" | into datetime)
    let archived = ("2026-01-02T00:00:00Z" | into datetime)

    assert equal (scan) [
      {assistant: "omp", path: $project, sessions: 4, last_used: $created}
      {assistant: "omp", path: "/other/deeper", sessions: 2, last_used: $archived}
    ]

    for args in [
      ["export" $project $directory "--session-ids" "parent"]
      ["move" $project $moved "--apply" "--no-backup"]
      ["retire" $moved "--session-ids" "parent" "--apply" "--no-backup"]
    ] {
      let run = (run-cli ...$args --assistant "omp")
      assert equal $run.exit_code 0 $run.stderr

      for original in $untouched {
        assert equal (open --raw $original.file | hash sha256) $original.hash $original.file
      }
    }
  }

  let entries = ($directory | path join "omp/entries.json")
  let bundle = (open $entries)
  assert equal $bundle.tables []
  assert ($bundle.files | all {|file| $file.kind in ["sessions" "archives"] })
  $bundle
  | upsert tables [{table: "kept", columns: ["cwd"], rows: [{cwd: $project}]}]
  | to json
  | save --force $entries

  with-env (fixture-env $target) {
    let import = (run-cli import $directory --assistant "omp" --apply --no-backup)
    assert equal $import.exit_code 0 $import.stderr

    let parent = (
      $target
      | path join "omp/sessions" (session-encode-here $project) "2026-01-01T00-00-00_parent.jsonl"
    )
    assert ($parent | path exists)
    let subtree = ($parent | str replace --regex '\.jsonl$' "")
    for child in [
      {name: "implementer/worker.jsonl", id: "child"}
      {name: "reviewer/worker.jsonl", id: "grandchild"}
    ] {
      let id = (
        open --raw ($subtree | path join $child.name)
        | lines
        | each {|line| $line | from json }
        | where type == "session"
        | first
        | get id
      )
      assert equal $id $child.id $child.name
    }
    let archived = (
      $target
      | path join "omp/archive/sessions" (session-encode-here "/other/deeper") "archived.jsonl"
    )
    assert ($archived | path exists)
    for path in ["omp/agent.db" "omp/history.db" "state/omp"] {
      assert not ($target | path join $path | path exists) $path
    }
  }
}

def "test bundle file origins describe source files without directing imports" [] {
  let root = (mktemp -d)
  let source = ($root | path join "source")
  let project = "/home/u/src/app"
  let session_dir = ($source | path join "omp/sessions" (session-encode-here $project))
  let session = ($session_dir | path join "recording.jsonl")
  let artifact = ($session_dir | path join "recording/notes.md")
  let protected = ($root | path join "protected.txt")
  let directory = ($root | path join "bundle")
  let manifest = ($directory | path join "omp/entries.json")
  write-jsonl $session [
    {
      type: "session"
      version: 3
      id: "selected"
      cwd: $project
    }
    {
      type: "message"
      message: {
        role: "user"
        content: "session body"
      }
    }
  ]
  mkdir ($artifact | path dirname)
  "owned notes" | save $artifact
  "protected content" | save $protected
  let transcript = (open --raw $session)

  with-env (fixture-env $source) {
    let export = (run-cli export $project $directory --assistant "omp" --session-ids "selected")
    assert equal $export.exit_code 0 $export.stderr
  }

  let entries = (open $manifest)

  assert equal (
    $entries.files
    | select name origin_path
    | sort-by name
  ) [
    {
      name: "recording.jsonl"
      origin_path: $session
    }
    {
      name: "recording/notes.md"
      origin_path: $artifact
    }
  ]

  for mode in ["normal" "hostile" "legacy"] {
    let target = ($root | path join $mode)
    let destination = ($target | path join "omp/sessions" (session-encode-here $project))
    let files = (
      $entries.files
      | each {|file|
        if $mode == "hostile" {
          $file | upsert origin_path $protected
        } else if $mode == "legacy" {
          $file | reject origin_path
        } else {
          $file
        }
      }
    )

    $entries
    | upsert files $files
    | to json
    | save --force $manifest

    with-env (fixture-env $target) {
      let import = (run-cli import $directory --assistant "omp" --apply)
      assert equal $import.exit_code 0 $import.stderr
    }

    assert equal (open --raw ($destination | path join "recording.jsonl")) $transcript $mode
    assert equal (open --raw ($destination | path join "recording/notes.md")) "owned notes" $mode
    assert equal (open --raw $protected) "protected content" $mode
  }
}

def "test OMP imports compare session header ids when filenames change" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-omp $root $project)
  let directory = ($root | path join "bundle")
  let renamed = ($fixture.dir | path join "renamed.jsonl")
  let renamed_artifacts = ($fixture.dir | path join "renamed")
  rm --recursive $fixture.children
  mkdir $fixture.children
  "owned notes" | save ($fixture.children | path join "notes.md")

  with-env (fixture-env $root) {
    let export = (run-cli export $project $directory --assistant "omp" --session-ids "parent")
    assert equal $export.exit_code 0 $export.stderr
    mv $fixture.parent $renamed
    mv $fixture.children $renamed_artifacts
    rm ($renamed_artifacts | path join "notes.md")

    let same = (run-cli import $directory --assistant "omp" --apply)
    assert equal $same.exit_code 0 $same.stderr

    assert not ($fixture.parent | path exists)
    assert ($renamed | path exists)
    assert not ($fixture.children | path exists)
    assert equal (open --raw ($renamed_artifacts | path join "notes.md")) "owned notes"

    let exported = ($root | path join "after-import")
    let export = (run-cli export $project $exported --assistant "omp" --session-ids "parent")
    assert equal $export.exit_code 0 $export.stderr

    assert equal (
      open ($exported | path join "omp/entries.json")
      | get files
      | where kind == "sessions"
      | get name
      | sort
    ) ["renamed.jsonl" "renamed/notes.md"]

    let changed = (
      open --raw $renamed
      | lines
      | each {|line| $line | from json }
      | each {|row|
        if $row.type == "message" {
          $row | update message.content "different body"
        } else {
          $row
        }
      }
    )
    rm $renamed
    write-jsonl $renamed $changed

    let conflict = (run-cli import $directory --assistant "omp" --apply)

    assert ($conflict.exit_code != 0) $conflict.stdout
    assert not ($fixture.parent | path exists)
  }
}

def "test flat OMP forks keep parent links after importing to a different state root" [] {
  let root = (mktemp -d)
  let source = ($root | path join "source")
  let target = ($root | path join "target")
  let project = "/home/u/src/app"
  let fixture = (make-omp $source $project)
  let forks = [
    {id: "path-fork", parentSession: $fixture.parent}
    {id: "escaped-fork", parentSession: $fixture.parent}
    {id: "id-fork", parentSession: "parent"}
  ]
  for row in $forks {
    let file = ($fixture.dir | path join $"($row.id).jsonl")
    write-jsonl $file [
      (
        $row
        | merge {
          type: "session"
          cwd: $project
        }
      )
      {
        type: "message"
        message: {
          role: "user"
          content: $fixture.parent
        }
      }
    ]

    let original = (open --raw $file)
    let content = if $row.id == "escaped-fork" {
      let value = ($fixture.parent | to json --raw)
      let escaped = ($value | str replace --all "/" '\/')

      $original | str replace ('"parentSession":' + $value) ('"parentSession":' + $escaped)

    } else {
      $original
    }

    "  " + $content + "\n\n" | save --force $file
  }

  let directory = ($root | path join "bundle")

  with-env (fixture-env $source) {
    let export = (run-cli export $project $directory --assistant "omp" --session-ids "parent")
    assert equal $export.exit_code 0 $export.stderr
  }

  with-env (fixture-env $target) {
    let import = (run-cli import $directory --assistant "omp" --apply)
    assert equal $import.exit_code 0 $import.stderr

    let destination = ($target | path join "omp/sessions" (session-encode-here $project))
    for row in $forks {
      let parent = if $row.parentSession == "parent" {
        "parent"
      } else {
        $destination | path join "2026-01-01T00-00-00_parent.jsonl"
      }
      let original = (open --raw ($fixture.dir | path join $"($row.id).jsonl"))
      let expected = if $row.id != "id-fork" {
        let value = ($fixture.parent | to json --raw)
        let encoded = if $row.id == "escaped-fork" {
          $value | str replace --all "/" '\/'
        } else {
          $value
        }
        let old = ('"parentSession":' + $encoded)
        let new = ('"parentSession":' + ($parent | to json --raw))

        $original | str replace $old $new

      } else {
        $original
      }

      assert equal (open --raw ($destination | path join $"($row.id).jsonl")) $expected
    }

    let repeated = (run-cli import $directory --assistant "omp" --apply)
    assert equal $repeated.exit_code 0 $repeated.stderr

    let exported = ($root | path join "target-bundle")
    let export = (run-cli export $project $exported --assistant "omp" --session-ids "parent")
    assert equal $export.exit_code 0 $export.stderr

    let names = (
      open ($exported | path join "omp/entries.json")
      | get files
      | get name
    )

    assert ("path-fork.jsonl" in $names)
    assert ("escaped-fork.jsonl" in $names)
    assert ("id-fork.jsonl" in $names)
  }
}

def "test targeted OMP imports restore native parent links after path rewrites" [] {
  for same_store in [false true] {
    let label = if $same_store { "existing native parent" } else { "different native state root" }
    let root = (
      mktemp -d
      | path expand
    )
    let source = ($root | path join "source")
    let local = if $same_store {
      $source
    } else {
      $root | path join "local"
    }
    let project = $root
    let target = ($root | path join "relocated")
    let owner = "/other/owner"
    let source_dir = ($source | path join "omp/sessions" (session-encode-here $owner))
    let parent = ($source_dir | path join "000-parent.jsonl")
    let fork = ($source_dir | path join "fork.jsonl")
    let outside = "/other/dependent"
    let external = (
      $source | path join "omp/sessions" (session-encode-here $outside) "external.jsonl"
    )
    write-jsonl $parent [
      {
        type: "session"
        id: "parent"
        cwd: $project
        timestamp: "2026-01-01T00:00:00Z"
      }
    ]
    write-jsonl $fork [
      {
        type: "session"
        id: "fork"
        cwd: ($project + "/worktree")
        parentSession: $parent
      }
      {
        type: "message"
        message: {content: ("file://" + $project + "/notes.md")}
      }
    ]
    write-jsonl $external [
      {
        type: "session"
        id: "external"
        cwd: $outside
        parentSession: "parent"
      }
      {
        type: "message"
        message: {content: ($project + "/external.txt")}
      }
    ]

    let value = ($parent | to json --raw)
    let escaped = ($value | str replace --all "/" '\/')
    open --raw $fork
    | str replace ('"parentSession":' + $value) ('"parentSession":' + $escaped)
    | save --force $fork
    mkdir ($source_dir | path join "000-parent")
    let artifact = ($source_dir | path join "000-parent/output.bin")
    0x[00 ff 80 0a] | save $artifact
    ^touch -d "2026-01-01T00:00:00.987654321Z" $fork
    let timestamp = (with-env {TZ: "UTC"} { ^stat -c "%y" $fork })
    let directory = ($root | path join "bundle")

    with-env (fixture-env $source) {
      let export = (run-cli export $project $directory --assistant "omp" --session-ids "parent")
      assert equal $export.exit_code 0 $"($label): ($export.stderr)"

      assert equal (
        open ($directory | path join "omp/entries.json")
        | get files
        | where session == "external"
        | get 0.project
      ) $outside $label
    }

    if $same_store {
      rm $fork
      rm $external
      rm --recursive ($source_dir | path join "000-parent")

      write-jsonl ($source_dir | path join "mapped-parent.jsonl") [
        {
          type: "session"
          id: "parent"
          cwd: $target
          timestamp: "2026-01-01T00:00:00Z"
        }
      ]
      mv --force ($source_dir | path join "mapped-parent.jsonl") $parent
    }
    let retained = (
      $local | path join "omp/sessions" (session-encode-here "/other/live") "retained.jsonl"
    )
    write-jsonl $retained [
      {type: "session", id: "local", cwd: "/other/live"}
      {type: "message", message: {content: $project}}
    ]
    let retained_bytes = (open --raw $retained)
    let destination = ($local | path join "omp/sessions" (session-encode-here $target))
    let native_parent = if $same_store {
      $parent
    } else {
      $destination | path join "000-parent.jsonl"
    }
    let native_artifact = (
      $native_parent
      | str replace --regex '\.jsonl$' ""
      | path join "output.bin"
    )
    let native_external = (
      $local
      | path join "omp/sessions" (session-encode-here $outside) "external.jsonl"
    )

    with-env (fixture-env $local) {
      let preview = (run-cli import $directory --assistant "omp" --target $target --no-backup)
      assert equal $preview.exit_code 0 $"($label): ($preview.stderr)"

      assert not (($destination | path join "fork.jsonl") | path exists) $label
      assert equal (open --raw $retained) $retained_bytes $label

      let import = (
        run-cli import $directory --assistant "omp" --target $target --no-backup --apply
      )
      assert equal $import.exit_code 0 $"($label): ($import.stderr)"

      let body = (
        open --raw ($destination | path join "fork.jsonl")
        | lines
        | each {|line| $line | from json }
      )
      assert equal ($body | get 0) {
        type: "session"
        id: "fork"
        cwd: ($target + "/worktree")
        parentSession: $native_parent
      } $label
      assert equal ($body | get 1.message.content) ("file://" + $target + "/notes.md") $label
      assert equal (
        open --raw $native_parent
        | from json
      ) {
        type: "session"
        id: "parent"
        cwd: $target
        timestamp: "2026-01-01T00:00:00Z"
      } $label
      assert equal (
        open --raw $native_artifact
        | into binary
      ) 0x[00 ff 80 0a] $label
      assert equal (
        open --raw $native_external
        | lines
        | each {|line| $line | from json }
      ) [
        {
          type: "session"
          id: "external"
          cwd: $outside
          parentSession: "parent"
        }
        {
          type: "message"
          message: {content: ($target + "/external.txt")}
        }
      ] $label
      assert equal (^stat -c "%y" ($destination | path join "fork.jsonl")) $timestamp $label
      assert equal (open --raw $retained) $retained_bytes $label
      let fork_bytes = (open --raw ($destination | path join "fork.jsonl"))

      let repeated = (
        run-cli import $directory --assistant "omp" --target $target --no-backup --apply
      )
      assert equal $repeated.exit_code 0 $"($label): ($repeated.stderr)"
      assert equal (open --raw ($destination | path join "fork.jsonl")) $fork_bytes $label
      assert equal (^stat -c "%y" ($destination | path join "fork.jsonl")) $timestamp $label
      assert equal (open --raw $retained) $retained_bytes $label
    }
  }
}

def "test selective CLI rejects ambiguous session selections" [] {
  let root = (mktemp -d)
  make-codex $root "/home/u/src/app" | ignore
  let cases = [
    ["retire" "/home/u/src/app"]
    ["retire" "/home/u/src/app" "--exact" "--session-ids" "one"]
    ["export" "/home/u/src/app" ($root | path join "bundle") "--exact" "--session-ids" "one"]
    ["export" "/home/u/src/app" ($root | path join "bundle") "--session-ids" ""]
    ["export" "/home/u/src/app" ($root | path join "bundle") "--exact" "--session-ids" ""]
    ["retire" "/home/u/src/app" "--session-ids" ""]
  ]

  with-env (fixture-env $root) {
    for args in $cases {
      let run = (run-cli ...$args)

      assert ($run.exit_code != 0) ($args | str join " ")
    }
  }
}
