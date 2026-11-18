#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Codex Tests
# ==================================================================================================

use std/assert
use std-rfc/str

use ../common.testlib.nu [fixture-env run-cli write-jsonl]
use ../lib/sqlite.nu [sql-quote sqlite-rows]

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

def make-codex [root: string, project: string, --encoding: string = "UTF-8"]: nothing -> record {
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
    $"
    PRAGMA encoding = (sql-quote $encoding);
    CREATE TABLE projects \(id TEXT PRIMARY KEY, path TEXT\);
    CREATE TABLE threads \(id TEXT PRIMARY KEY, cwd TEXT, rollout_path TEXT,
      project_id TEXT REFERENCES projects\(id\), attached_thread_parent_id TEXT,
      updated_at INTEGER, updated_at_ms INTEGER\);
    CREATE TABLE thread_spawn_edges \(parent_thread_id TEXT NOT NULL,
      child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL\);
    CREATE TABLE dependent \(thread_id TEXT REFERENCES threads\(id\) ON DELETE CASCADE\);
    INSERT INTO projects VALUES \('shared', (sql-quote $project)\);
    "
    | str dedent
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
    let insert = (
      $"
      INSERT INTO threads VALUES \(($id), ($cwd), ($rollout), 'shared', ($parent), 1, 1000\);
      INSERT INTO dependent VALUES \(($id)\);
      "
      | str dedent
    )
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
    "
    CREATE TABLE thread_history_projection_state (thread_id TEXT);
    CREATE TABLE thread_turns (thread_id TEXT);
    CREATE TABLE thread_items (thread_id TEXT);
    CREATE TABLE thread_realtime_items (thread_id TEXT);
    CREATE TRIGGER clear_realtime AFTER DELETE ON thread_history_projection_state
    BEGIN DELETE FROM thread_realtime_items WHERE thread_id = OLD.thread_id; END;
    "
    | str dedent
  )
  $projection_schema | ^sqlite3 $history
  let values = "('parent'), ('child'), ('other-child'), ('retained'), ('nested')"
  for table in [
    "thread_history_projection_state" "thread_turns" "thread_items" "thread_realtime_items"
  ] {
    $"INSERT INTO ($table) VALUES ($values);"
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

  (
    "
    DELETE FROM dependent;
    DELETE FROM thread_spawn_edges;
    DELETE FROM threads;
    DELETE FROM projects;
    "
    | str dedent
  ) | ^sqlite3 $fixture.db
  rm --recursive $sessions
}

def bundle-thread-ids [directory: string]: nothing -> list {
  open ($directory | path join "codex/entries.json")
  | get tables
  | where table == "threads"
  | get 0.rows
  | get -o id
  | sort
}

def make-target-codex [root: string, project: string]: nothing -> record {
  let fixture = (make-codex $root $project)
  (
    "
    DROP TABLE projects;
    CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, metadata TEXT, position INTEGER,
      created_at_ms INTEGER, updated_at_ms INTEGER);
    CREATE TABLE project_roots (project_id TEXT, position INTEGER, path TEXT);
    ALTER TABLE threads ADD COLUMN sandbox_policy TEXT;
    ALTER TABLE threads ADD COLUMN agent_path TEXT;
    "
    | str dedent
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
  let root_path = (sql-quote $project)
  let worktree_path = (sql-quote ($project + "/worktree"))
  let agent_path = (sql-quote ($project + "/logical-agent"))
  (
    $"
    INSERT INTO projects VALUES \('shared', 'Example', ($metadata), 2, 1001, 2002\);
    INSERT INTO project_roots VALUES
      \('shared', 0, ($root_path)\),
      \('shared', 1, ($worktree_path)\);
    UPDATE threads SET sandbox_policy = ($policy), agent_path = ($agent_path);
    "
    | str dedent
  ) | ^sqlite3 $fixture.db

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

      assert equal (bundle-thread-ids $directory) $case.expected $case.name
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

    assert equal (bundle-thread-ids $imported) [
      "child" "other-child" "parent"
    ]
  }

  for fault in ["null" "numeric" "missing-field" "missing-plain" "missing-compressed"] {
    let source = ($root | path join $fault)
    let broken = (make-codex $source $project)
    let id = if $fault == "missing-compressed" { "parent" } else { "retained" }
    let directory = ($source | path join "rejected")
    if $fault == "missing-field" {
      "ALTER TABLE threads DROP COLUMN rollout_path;" | ^sqlite3 $broken.db
    } else if $fault == "numeric" {
      "
      ALTER TABLE threads RENAME COLUMN rollout_path TO original_rollout_path;
      ALTER TABLE threads ADD COLUMN rollout_path;
      UPDATE threads SET rollout_path = original_rollout_path;
      UPDATE threads SET rollout_path = 42 WHERE id = 'retained';
      "
      | ^sqlite3 $broken.db
    } else if $fault == "null" {
      "UPDATE threads SET rollout_path = NULL WHERE id = 'retained';" | ^sqlite3 $broken.db
    } else {
      let file = if $fault == "missing-compressed" {
        $broken.compressed
      } else {
        $source | path join "codex/sessions/retained.jsonl"
      }
      rm $file
    }

    with-env (fixture-env $source) {
      let rejected = (run-cli export $project $directory --assistant "codex" --session-ids $id)
      assert not equal $rejected.exit_code 0 $fault

      assert not ($directory | path exists) $fault
      if $fault != "missing-field" {
        let valid = ($source | path join "valid")
        let exported = (
          run-cli export $project $valid --assistant "codex" --session-ids "nested"
        )
        assert equal $exported.exit_code 0 $"($fault): ($exported.stderr)"

        assert equal (bundle-thread-ids $valid) ["nested"] $fault
      }
    }
  }
}

def "test live Codex retirement preserves peers and removes dependent rows with backups" [] {
  let root = (mktemp -d)
  let project = ($root | path join "live")
  mkdir $project
  let fixture = (make-codex $root $project)

  let args = ["retire" $project "--session-ids" "parent"]
  let saved = (apply-codex $root $fixture.db $args true)

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

    let saved_rollout = ($saved | path join ($fixture.compressed | str trim --left --char "/"))
    assert ($saved_rollout | path exists)

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

def "test Codex mutations honor backup choice and preserve unrelated imports" [] {
  for operation in ["move" "import"] {
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
    let backup = $operation == "import"
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
        ] $operation
        assert equal (sqlite-rows $fixture.db "SELECT * FROM thread_spawn_edges") [
          {
            parent_thread_id: "parent"
            child_thread_id: "child"
            status: "completed"
          }
        ] $operation
        assert equal (
          sqlite-rows $fixture.db "SELECT * FROM dependent"
        ) [{thread_id: "retained"}] $operation
        assert equal (open --raw $retained) $retained_body $operation
        assert ($fixture.compressed | path exists) $operation
        assert (($target | path join "codex/sessions/child.jsonl") | path exists) $operation
      } else {
        assert equal (sqlite-rows $fixture.db "SELECT cwd FROM threads WHERE id = 'parent'") [
          {cwd: $moved}
        ] $operation
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

    assert equal (bundle-thread-ids $directory) ["child"]

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

  let manifest = ($directory | path join "codex/entries.json")
  let edge = {
    parent_thread_id: "parent"
    child_thread_id: "child"
    status: "completed"
  }
  open $manifest
  | update tables {
    $in | each {|entry|
      if $entry.table == "thread_spawn_edges" {
        $entry | reject --optional encoding | update rows [$edge]
      } else {
        $entry
      }
    }
  }
  | to json
  | save --force $manifest

  with-env (fixture-env $target) {
    let import = (run-cli import $directory --assistant "codex" --apply)
    assert equal $import.exit_code 0 $import.stderr

    assert equal (sqlite-rows $target_fixture.db "SELECT id FROM threads") [{id: "child"}]
    assert equal (sqlite-rows $target_fixture.db "SELECT * FROM thread_spawn_edges") [$edge]
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

def "test selected Codex moves bound rows and rollouts to the session closure" [] {
  for compressed in [false true] {
    let root = (mktemp -d | path expand)
    let project = "/home/u/src/app"
    let target = ($root | path join "moved")
    mkdir $target
    let fixture = (make-target-codex $root $project)
    let plain = ($fixture.compressed | str replace --regex '\.zst$' '')
    if not $compressed {
      ^zstd -dc $fixture.compressed | save $plain
      rm $fixture.compressed
    }
    let canonical = if $compressed { $fixture.compressed } else { $plain }
    let sessions = ($root | path join "codex/sessions")
    let child = ($sessions | path join "child.jsonl")
    let child_rows = [
      {
        type: "session_meta"
        payload: {
          id: "child"
          cwd: "/other/worker"
        }
      }
      {
        type: "response_item"
        payload: {
          path: $"($project)/child.txt"
          prose: $"Mention ($project)"
        }
      }
    ]
    rm $child
    write-jsonl $child $child_rows
    let desktop = ($root | path join "codex/.codex-global-state.json")
    {saved: [$project]} | to json | save $desktop
    let desktop_bytes = (open --raw $desktop | into binary)
    let rows = (sqlite-rows $fixture.db "SELECT * FROM threads ORDER BY id")
    let projects = (sqlite-rows $fixture.db "SELECT * FROM projects")
    let roots = (sqlite-rows $fixture.db "SELECT * FROM project_roots ORDER BY position")
    let edges = (sqlite-rows $fixture.db "SELECT * FROM thread_spawn_edges")
    let peers = (
      ["retained" "nested" "other-child"]
      | each {|id|
        let file = ($sessions | path join $"($id).jsonl")
        {
          file: $file
          bytes: (open --raw $file | into binary)
        }
      }
      | collect
    )
    let expected_parent = [
      {
        type: "session_meta"
        payload: {
          id: "parent"
          cwd: $target
          timestamp: "2026-01-01T00:00:00.123456789Z"
        }
      }
      {
        type: "response_item"
        payload: {
          path: $"($target)/file.txt"
          uri: $"file://($target)/file.txt"
          sibling: $"($project)-peer/file.txt"
        }
      }
    ]

    let moved = (with-env (fixture-env $root) {
      run-cli move $project $target --assistant "codex" --session-ids "parent" --apply --no-backup
    })
    assert equal $moved.exit_code 0 $moved.stderr

    assert equal (sqlite-rows $fixture.db "SELECT * FROM threads ORDER BY id") (
      $rows | each {|row|
        if $row.id in ["parent" "child" "other-child"] {
          $row | merge {
            cwd: (if $row.id == "parent" { $target } else { $row.cwd })
            sandbox_policy: ({writable_roots: [$target]} | to json --raw)
          }
        } else {
          $row
        }
      }
    )
    let parent_body = if $compressed { ^zstd -dc $canonical } else { open --raw $canonical }
    assert equal ($parent_body | lines | each {|line| $line | from json }) $expected_parent
    assert equal (open --raw $child | lines | each {|line| $line | from json }) (
      $child_rows | update 1.payload.path $"($target)/child.txt"
    )
    for peer in $peers {
      assert equal (open --raw $peer.file | into binary) $peer.bytes $peer.file
    }
    for table in [
      "thread_history_projection_state" "thread_turns" "thread_items" "thread_realtime_items"
    ] {
      assert equal (sqlite-rows $fixture.history $"SELECT * FROM ($table) ORDER BY thread_id") [
        {thread_id: "nested"}
        {thread_id: "other-child"}
        {thread_id: "retained"}
      ] $table
    }
    assert equal (sqlite-rows $fixture.db "SELECT * FROM projects") $projects
    assert equal (sqlite-rows $fixture.db "SELECT * FROM project_roots ORDER BY position") $roots
    assert equal (sqlite-rows $fixture.db "SELECT * FROM thread_spawn_edges") $edges
    assert equal (open --raw $desktop | into binary) $desktop_bytes
    let stable = (open --raw $fixture.db | hash sha256)

    let args = [
      "move" $project $target "--assistant" "codex"
      "--session-ids" "parent,child,unknown" "--apply" "--no-backup"
    ]
    let repeated = (with-env (fixture-env $root) {
      run-cli ...$args
    })
    assert equal $repeated.exit_code 0 $repeated.stderr
    assert str contains $repeated.stdout "No changes."
    assert equal (open --raw $fixture.db | hash sha256) $stable
  }

  let root = (mktemp -d | path expand)
  let project = "/home/u/src/app"
  let target = ($root | path join "moved")
  mkdir $target
  let fixture = (make-codex $root $project)
  rm $fixture.compressed
  let state = (open --raw $fixture.db | hash sha256)
  let history = (open --raw $fixture.history | hash sha256)

  let rejected = (with-env (fixture-env $root) {
    run-cli move $project $target --assistant "codex" --session-ids "parent" --apply --no-backup
  })
  assert not equal $rejected.exit_code 0

  assert equal (open --raw $fixture.db | hash sha256) $state
  assert equal (open --raw $fixture.history | hash sha256) $history
}

def "test exact Codex moves keep nested project sessions and tolerate missing projections" [] {
  let root = (mktemp -d | path expand)
  let project = "/home/u/src/app"
  let target = ($root | path join "moved")
  let fixture = (make-codex $root $project)
  let child = ($root | path join "codex/sessions/child.jsonl")
  let nested = ($root | path join "codex/sessions/nested.jsonl")
  let before = (open --raw $nested)
  {
    type: "response_item"
    payload: {path: ($project | path join "linked.txt")}
  }
  | to json --raw
  | $"\n($in)"
  | save --append $child
  "ALTER TABLE threads ADD COLUMN sandbox_policy TEXT;" | ^sqlite3 $fixture.db
  "DROP TABLE thread_items;" | ^sqlite3 $fixture.history
  mkdir $target

  let moved = (with-env (fixture-env $root) {
    run-cli move $project $target --assistant "codex" --exact --apply --no-backup
  })
  assert equal $moved.exit_code 0 $moved.stderr

  assert equal (sqlite-rows $fixture.db "SELECT id, cwd FROM threads ORDER BY id") [
    {id: "child", cwd: "/other/worker"}
    {id: "nested", cwd: "/home/u/src/app/sub"}
    {id: "other-child", cwd: "/another/worker"}
    {id: "parent", cwd: $target}
    {id: "retained", cwd: $target}
  ]
  let linked = (open --raw $child | lines | last | from json)
  assert equal $linked.payload.path ($target | path join "linked.txt")
  assert equal (open --raw $nested) $before
  assert equal (
    sqlite-rows $fixture.history "SELECT thread_id FROM thread_turns ORDER BY thread_id"
  ) [{thread_id: "nested"} {thread_id: "other-child"}]
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

  (
    "
    DELETE FROM dependent WHERE thread_id != 'retained';
    DELETE FROM thread_spawn_edges;
    DELETE FROM threads WHERE id != 'retained';
    UPDATE projects SET id = 'live';
    UPDATE project_roots SET project_id = 'live';
    UPDATE threads SET project_id = 'live';
    "
    | str dedent
  ) | ^sqlite3 $destination.db

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
  let local_agent = (sql-quote ($project + "/local-agent"))
  (
    $"
    UPDATE projects SET metadata = ($opaque);
    UPDATE threads SET sandbox_policy = ($policy), agent_path = ($local_agent);
    "
    | str dedent
  ) | ^sqlite3 $destination.db

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
    let target_sql = (sql-quote $target)
    let worktree_sql = (sql-quote ($target + "/worktree"))
    (
      $"
      INSERT INTO projects VALUES \('shared', 'Local', '{}', 9, 3003, 4004\);
      INSERT INTO project_roots VALUES
        \('shared', 0, ($worktree_sql)\),
        \('shared', 1, ($target_sql)\);
      "
      | str dedent
    ) | ^sqlite3 $destination.db
    let conflicting = (open --raw $destination.db | hash sha256)

    let refused = (
      run-cli import $directory --assistant "codex" --target $target --no-backup --apply
    )
    assert ($refused.exit_code != 0) $refused.stdout
    assert str contains $refused.stderr "different roots"

    assert equal (open --raw $destination.db | hash sha256) $conflicting
    assert not (($sessions | path join "parent.jsonl.zst") | path exists)

    (
      "
      DELETE FROM project_roots WHERE project_id = 'shared';
      DELETE FROM projects WHERE id = 'shared';
      "
      | str dedent
    ) | ^sqlite3 $destination.db
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

def "test Codex rejects directory rollout paths and backs up single-quote database paths" [] {
  let root = (mktemp -d | path expand)
  let project = "/home/u/src/app"
  let target = ($root | path join "moved")
  mkdir $target
  let fixture = (make-codex $root $project)

  let retained_rollout = ($root | path join "codex/sessions/retained.jsonl")
  rm $retained_rollout
  mkdir $retained_rollout
  rm $fixture.compressed
  mkdir $fixture.compressed
  let db_before = (open --raw $fixture.db | hash sha256)

  for id in ["retained" "parent"] {
    let move_rejected = (with-env (fixture-env $root) {
      run-cli move $project $target --assistant "codex" --session-ids $id --apply --no-backup
    })
    assert not equal $move_rejected.exit_code 0 $id
    assert str contains $move_rejected.stderr "no rollout file" $id

    let bundle_dir = ($root | path join $"bundle-($id)")
    let export_rejected = (with-env (fixture-env $root) {
      run-cli export $project $bundle_dir --assistant "codex" --session-ids $id
    })
    assert not equal $export_rejected.exit_code 0 $id
  }
  assert equal (open --raw $fixture.db | hash sha256) $db_before

  let quoted_root = ($root | path join "owner's-home")
  let quoted_fixture = (make-target-codex $quoted_root $project)
  let saved = (apply-codex $quoted_root $quoted_fixture.db ["move" $project $target] true)
  let saved_db = ($saved | path join ($quoted_fixture.db | str trim --left --char "/"))
  let saved_history = ($saved | path join ($quoted_fixture.history | str trim --left --char "/"))
  assert ($saved_db | path exists)
  assert ($saved_history | path exists)
  let logged = (
    open --raw ($quoted_root | path join "sqlite-backups.jsonl")
    | lines
    | each {|line| $line | from json | last }
  )
  assert equal $logged [
    $".backup ($saved_history | to json --raw)"
    $".backup ($saved_db | to json --raw)"
  ]
}

def create-feedback-table [db: string] {
  "
  CREATE TABLE guardian_review_feedback (
    id INTEGER PRIMARY KEY,
    thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
    record BLOB NOT NULL,
    note TEXT,
    score REAL
  );
  "
  | str dedent
  | ^sqlite3 $db
}

def "test Codex transfers selected feedback and retains its bytes after source retirement" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let source = (make-codex $root $project)
  create-feedback-table $source.db
  "
  INSERT INTO guardian_review_feedback VALUES
    (11, 'child', X'00ff80fe41', 'it''s' || char(0) || 'text', 1.2345678901234567),
    (12, 'retained', X'', NULL, NULL),
    (13, 'other-child', X'6180', NULL, NULL);
  "
  | str dedent
  | ^sqlite3 $source.db
  let cases = [
    {
      name: "project"
      scope: "/other/worker"
      flags: []
      ids: [11]
    }
    {
      name: "selected"
      scope: $project
      flags: ["--session-ids" "parent"]
      ids: [11 13]
    }
  ]
  let ids = "SELECT id FROM guardian_review_feedback ORDER BY id"
  let record = (
    "
    SELECT typeof(record) AS kind, hex(record) AS bytes, hex(note) AS note,
      score = 1.2345678901234567 AS exact_score
    FROM guardian_review_feedback WHERE id = 11
    "
    | str dedent
  )
  let expected = {
    kind: "blob"
    bytes: "00FF80FE41"
    note: "697427730074657874"
    exact_score: 1
  }

  for case in $cases {
    let bundle = ($root | path join $case.name)
    let target = ($bundle + "-target")
    let destination = (make-codex $target $project)
    clear-codex-sessions $destination
    create-feedback-table $destination.db

    with-env (fixture-env $root) {
      let export = (run-cli export $case.scope $bundle --assistant "codex" ...$case.flags)
      assert equal $export.exit_code 0 $export.stderr
    }

    with-env (fixture-env $target) {
      let import = (run-cli import $bundle --assistant "codex" --apply)
      assert equal $import.exit_code 0 $import.stderr
      assert equal (sqlite-rows $destination.db $ids | get id) $case.ids $case.name
      assert equal (sqlite-rows $destination.db $record) [$expected] $case.name
    }
  }

  let target = ($root | path join "selected-target")
  let db = ($target | path join "codex/state_5.sqlite")
  let bundle = ($root | path join "selected")
  with-env (fixture-env $root) {
    let retired = (run-cli retire $project --assistant "codex" --session-ids "parent" --apply)
    assert equal $retired.exit_code 0 $retired.stderr
    assert equal (sqlite-rows $source.db $ids | get id) [12]
    assert equal (sqlite-rows $db $record) [$expected]
  }

  with-env (fixture-env $target) {
    "DELETE FROM guardian_review_feedback WHERE id = 11;" | ^sqlite3 $db
    let repair = (run-cli import $bundle --assistant "codex" --apply)
    assert equal $repair.exit_code 0 $repair.stderr
    assert equal (sqlite-rows $db $record) [$expected]

    let before = (open --raw $db | hash sha256)
    let again = (run-cli import $bundle --assistant "codex" --apply)
    assert equal $again.exit_code 0 $again.stderr
    assert equal (open --raw $db | hash sha256) $before

    "UPDATE guardian_review_feedback SET record = X'00ff80fe42' WHERE id = 11;" | ^sqlite3 $db
    let changed = (open --raw $db | hash sha256)
    let conflict = (run-cli import $bundle --assistant "codex" --apply)
    assert not equal $conflict.exit_code 0
    assert str contains $conflict.stderr "guardian_review_feedback"
    assert equal (open --raw $db | hash sha256) $changed
  }
}

def "test Codex rejects incompatible feedback schemas and malformed rows before copying files" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let source = (make-codex $root $project)
  create-feedback-table $source.db
  "INSERT INTO guardian_review_feedback VALUES (1, 'retained', X'01', NULL, NULL);"
  | ^sqlite3 $source.db
  let bundle = ($root | path join "bundle")
  with-env (fixture-env $root) {
    let export = (run-cli export $project $bundle --assistant "codex" --session-ids "retained")
    assert equal $export.exit_code 0 $export.stderr
  }

  let target = ($root | path join "target")
  let destination = (make-codex $target $project)
  clear-codex-sessions $destination
  let db = $destination.db
  let sessions = ($target | path join "codex/sessions")

  with-env (fixture-env $target) {
    for fault in ["missing-table" "required-column" "malformed-literal"] {
      if $fault == "required-column" {
        create-feedback-table $db
        "ALTER TABLE guardian_review_feedback ADD COLUMN reason TEXT NOT NULL;" | ^sqlite3 $db
      } else if $fault == "malformed-literal" {
        "ALTER TABLE guardian_review_feedback DROP COLUMN reason;" | ^sqlite3 $db
        let path = ($bundle | path join "codex/entries.json")
        open $path
        | update tables {|entry|
          $entry.tables | each {|table|
            if $table.table == "guardian_review_feedback" {
              $table | update rows.0.record "1 + 1"
            } else {
              $table
            }
          }
        }
        | to json
        | save --force $path
      }

      let before = (open --raw $db | hash sha256)
      let rejected = (run-cli import $bundle --assistant "codex" --apply)
      assert not equal $rejected.exit_code 0 $fault
      assert equal (open --raw $db | hash sha256) $before $fault
      assert not ($sessions | path exists) $fault
    }
  }
}

def "test Codex literal transfers require matching SQLite text encodings" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let source = (make-codex $root $project --encoding "UTF-16le")
  create-feedback-table $source.db
  let query = "SELECT id, thread_id, hex(note) AS note FROM guardian_review_feedback"
  "
  INSERT INTO guardian_review_feedback VALUES (1, 'retained', X'01', 'é' || char(0), NULL);
  "
  | str dedent
  | ^sqlite3 $source.db
  let bundle = ($root | path join "bundle")
  let entries = ($bundle | path join "codex/entries.json")

  with-env (fixture-env $root) {
    let export = (run-cli export $project $bundle --assistant "codex" --session-ids "retained")
    assert equal $export.exit_code 0 $export.stderr
  }
  let manifest = (open $entries)
  assert equal $manifest.state_encoding "UTF-16le"
  let cases = [
    {
      name: "mismatch"
      encoding: "UTF-8"
      manifest: $manifest
      error: "this host uses UTF-8"
    }
    {
      name: "missing"
      encoding: "UTF-16le"
      manifest: ($manifest | reject state_encoding)
      error: "SQLite text encoding unspecified"
    }
  ]

  for case in $cases {
    let target = ($root | path join $case.name)
    let destination = (make-codex $target $project --encoding $case.encoding)
    clear-codex-sessions $destination
    create-feedback-table $destination.db
    let before = (open --raw $destination.db | hash sha256)
    $case.manifest | to json | save --force $entries

    with-env (fixture-env $target) {
      let rejected = (run-cli import $bundle --assistant "codex" --apply)
      assert not equal $rejected.exit_code 0 $case.name
      assert str contains $rejected.stderr $case.error
    }
    assert equal (open --raw $destination.db | hash sha256) $before $case.name
    assert not ($target | path join "codex/sessions" | path exists) $case.name
  }

  let target = ($root | path join "missing")
  $manifest | to json | save --force $entries
  with-env (fixture-env $target) {
    let imported = (run-cli import $bundle --assistant "codex" --apply)
    assert equal $imported.exit_code 0 $imported.stderr
  }
  let db = ($target | path join "codex/state_5.sqlite")
  assert equal (sqlite-rows $db $query) [{id: 1, thread_id: "retained", note: "E9000000"}]
}
