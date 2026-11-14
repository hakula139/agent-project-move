#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Selective Transfer and Retirement Tests
# ==================================================================================================

use std/assert

use ./lib/sqlite.nu [sql-quote sqlite-rows]
use ./stores/claude.nu [encode-path]
use ./stores/omp.nu [memory-encode session-encode-here]

const SCRIPT = path self "agent-project-move.nu"

def fixture-env [root: string]: nothing -> record {
  {
    CLAUDE_CONFIG_DIR: ($root | path join "claude")
    CODEX_HOME: ($root | path join "codex")
    PI_CODING_AGENT_DIR: ($root | path join "omp")
    XDG_STATE_HOME: ($root | path join "state")
  }
}

def write-jsonl [file: string, rows: list<record>] {
  mkdir ($file | path dirname)
  $rows | each {|row| $row | to json --raw } | str join "\n" | save $file
}

def --wrapped run-cli [...args: string]: nothing -> record {
  ^$nu.current-exe $SCRIPT ...$args | complete
}

def make-codex [root: string, project: string]: nothing -> record {
  let dir = ($root | path join "codex")
  let db = ($dir | path join "state_5.sqlite")
  mkdir ($dir | path join "sessions")
  let rows = [
    {id: "parent", cwd: $project, parent: null}
    {id: "child", cwd: "/other/worker", parent: "parent"}
    {id: "other-child", cwd: "/another/worker", parent: "parent"}
    {id: "retained", cwd: $project, parent: null}
    {id: "nested", cwd: ($project | path join "sub"), parent: null}
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
      {type: "session_meta", payload: {id: $row.id, cwd: $row.cwd}}
      {type: "response_item", payload: {role: "user", content: $"body ($row.id)"}}
    ]
    write-jsonl $file $body
    let insert = (
      "INSERT INTO threads VALUES (" + (sql-quote $row.id) + ", "
      + (sql-quote $row.cwd) + ", " + (sql-quote $file) + ", 'shared', "
      + (sql-quote (if $row.id == "other-child" { $row.parent } else { null })) + ", 1, 1000); "
      + "INSERT INTO dependent VALUES (" + (sql-quote $row.id) + ");"
    )
    $insert | ^sqlite3 $db
  }
  let plain = ($dir | path join "sessions/parent.jsonl")
  let compressed = $plain + ".zst"
  ^zstd -q $plain -o $compressed
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
  {db: $db, history: $history, compressed: $compressed}
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
    {name: "prefix", flags: [], expected: ["child" "nested" "other-child" "parent" "retained"]}
    {name: "exact", flags: ["--exact"], expected: ["child" "other-child" "parent" "retained"]}
    {name: "parent", flags: ["--session-ids" "parent"], expected: ["child" "other-child" "parent"]}
    {name: "retained", flags: ["--session-ids" "retained"], expected: ["retained"]}
    {name: "child", flags: ["--session-ids" "child"], expected: ["child"]}
  ]

  with-env (fixture-env $root) {
    for case in $cases {
      let directory = ($root | path join $case.name)

      let scope = if $case.name == "child" { "/other" } else { $project }
      let run = (run-cli export $scope $directory --assistant codex ...$case.flags)
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
  "DELETE FROM dependent; DELETE FROM thread_spawn_edges; DELETE FROM threads; DELETE FROM projects;"
  | ^sqlite3 $target_fixture.db
  rm --recursive ($target | path join "codex/sessions")

  with-env (fixture-env $target) {
    let import = (run-cli import ($root | path join "parent") --assistant codex --apply)
    assert equal $import.exit_code 0 $import.stderr

    assert equal (sqlite-rows $target_fixture.db "SELECT id FROM threads ORDER BY id") [
      {id: "child"}
      {id: "other-child"}
      {id: "parent"}
    ]
    assert equal (sqlite-rows $target_fixture.db "SELECT * FROM thread_spawn_edges") [
      {parent_thread_id: "parent", child_thread_id: "child", status: "completed"}
    ]
    assert equal (open --raw $target_fixture.compressed | hash sha256) $bytes
    let export = (
      run-cli export $project ($root | path join "imported") --assistant codex --session-ids parent
    )
    assert equal $export.exit_code 0 $export.stderr

    assert equal (bundle-ids ($root | path join "imported") "codex" "threads") [
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
    let before = (open --raw $fixture.db | hash sha256)
    let backup_root = ($root | path join "state/agent-project-move")
    let flags = if $backup { [] } else { ["--no-backup"] }

    with-env (fixture-env $root) {
      let dry = (run-cli retire $project --assistant codex --session-ids parent ...$flags)
      assert equal $dry.exit_code 0 $dry.stderr

      assert equal (open --raw $fixture.db | hash sha256) $before
      assert ($fixture.compressed | path exists)
      assert not ($backup_root | path exists)

      let apply = (
        run-cli retire $project --assistant codex --session-ids parent --apply ...$flags
      )
      assert equal $apply.exit_code 0 $apply.stderr

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
      assert equal ($backup_root | path exists) $backup
      if $backup {
        let run_backup = (ls $backup_root | get name | first)
        assert (($run_backup | path join "manifest.json") | path exists)
        let saved = ($run_backup | path join ($fixture.compressed | str trim --left --char "/"))
        let saved_db = ($run_backup | path join ($fixture.db | str trim --left --char "/"))
        assert ($saved | path exists)
        assert equal (sqlite-rows $saved_db "SELECT id FROM threads ORDER BY id") [
          {id: "child"}
          {id: "nested"}
          {id: "other-child"}
          {id: "parent"}
          {id: "retained"}
        ]
      }

      let exact = (run-cli retire $project --assistant codex --exact --apply --no-backup)
      assert equal $exact.exit_code 0 $exact.stderr

      assert equal (sqlite-rows $fixture.db "SELECT id FROM threads") [{id: "nested"}]
      assert equal (sqlite-rows $fixture.db "SELECT id FROM projects") [{id: "shared"}]

      let last = (
        run-cli retire ($project | path join "sub") --assistant codex --exact --apply --no-backup
      )
      assert equal $last.exit_code 0 $last.stderr

      assert equal (sqlite-rows $fixture.db "SELECT id FROM threads") []
      assert equal (sqlite-rows $fixture.db "SELECT id FROM projects") []
    }
  }
}

def "test selective CLI rejects ambiguous retirement and backup bypass elsewhere" [] {
  let root = (mktemp -d)
  make-codex $root "/home/u/src/app" | ignore
  let cases = [
    ["retire" "/home/u/src/app"]
    ["retire" "/home/u/src/app" "--exact" "--session-ids" "one"]
    ["export" "/home/u/src/app" ($root | path join "bundle") "--exact" "--session-ids" "one"]
    ["export" "/home/u/src/app" ($root | path join "bundle") "--session-ids" ""]
    ["export" "/home/u/src/app" ($root | path join "bundle") "--exact" "--session-ids" ""]
    ["retire" "/home/u/src/app" "--session-ids" ""]
    ["prune" "--no-backup"]
    ["move" "/home/u/src/app" "/home/u/src/new" "--no-backup"]
    ["import" ($root | path join "bundle") "--no-backup"]
  ]

  with-env (fixture-env $root) {
    for args in $cases {
      let run = (run-cli ...$args)

      assert ($run.exit_code != 0) ($args | str join " ")
    }
  }
}

def make-claude [root: string, project: string]: nothing -> record {
  let config = ($root | path join "claude")
  let dir = ($config | path join "projects" (encode-path $project))
  let nested = ($config | path join "projects" (encode-path ($project | path join "sub")))
  for row in [
    {id: "parent", dir: $dir, cwd: $project}
    {id: "retained", dir: $dir, cwd: "/other/retained"}
    {id: "nested", dir: $nested, cwd: ($project | path join "sub")}
  ] {
    let body = [
      {type: "user", sessionId: $row.id, cwd: $row.cwd, message: {content: $row.id}}
    ]
    let visits = if $row.id == "parent" {
      [{type: "system", sessionId: $row.id, cwd: "/other/visited"}]
    } else { [] }
    write-jsonl ($row.dir | path join $"($row.id).jsonl") ($body ++ $visits)
  }
  let child = ($dir | path join "parent/subagents/agent-child.jsonl")
  write-jsonl $child [
    {type: "assistant", sessionId: "child", cwd: "/other/worker", message: {content: "child"}}
  ]
  mkdir ($dir | path join "memory")
  "shared memory" | save ($dir | path join "memory/MEMORY.md")
  mkdir ($config | path join "file-history/parent")
  "original artifact" | save ($config | path join "file-history/parent/file@v1")
  mkdir ($config | path join "file-history/child")
  "child artifact" | save ($config | path join "file-history/child/child@v1")
  write-jsonl ($config | path join "history.jsonl") [
    {sessionId: "parent", project: $project, display: "parent"}
    {sessionId: "retained", project: $project, display: "retained"}
    {sessionId: "nested", project: ($project | path join "sub"), display: "nested"}
  ]
  {
    projects: {
      ($project): {hasTrustDialogAccepted: true}
      ($project | path join "sub"): {hasTrustDialogAccepted: true}
    }
    githubRepoPaths: {"example/app": [$project ($project | path join "sub")]}
  } | to json | save ($config | path join ".claude.json")
  {dir: $dir, nested: $nested, child: $child, config: $config}
}

def "test Claude selected parents carry subagents and preserve shared project state" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-claude $root $project)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export $project $directory --assistant claude --session-ids parent)
    assert equal $export.exit_code 0 $export.stderr

    let entries = (open ($directory | path join "claude/entries.json"))
    assert equal ($entries.files | where kind == "projects" | get name | sort) [
      "memory/MEMORY.md"
      "parent.jsonl"
      "parent/subagents/agent-child.jsonl"
    ]
    assert equal ($entries.files | where kind == "projects" | get project | uniq) [$project]
    assert equal ($entries.files | where kind == "file-history" | get name | sort) [
      "child@v1" "file@v1"
    ]

    let apply = (
      run-cli retire $project --assistant claude --session-ids parent --apply --no-backup
    )
    assert equal $apply.exit_code 0 $apply.stderr

    assert not (($fixture.dir | path join "parent.jsonl") | path exists)
    assert not ($fixture.child | path exists)
    assert not (($fixture.config | path join "file-history/parent") | path exists)
    assert not (($fixture.config | path join "file-history/child") | path exists)
    assert (($fixture.dir | path join "retained.jsonl") | path exists)
    assert (($fixture.nested | path join "nested.jsonl") | path exists)
    assert equal (open --raw ($fixture.dir | path join "memory/MEMORY.md")) "shared memory"
    assert equal (
      open --raw ($fixture.config | path join "history.jsonl")
      | lines
      | each {|line| $line | from json | get sessionId }
    ) ["retained" "nested"]
    assert equal (
      open ($fixture.config | path join ".claude.json") | get projects | columns
    ) [$project ($project | path join "sub")]

    let final = (run-cli retire "/other/retained" --assistant claude --exact --apply --no-backup)
    assert equal $final.exit_code 0 $final.stderr

    assert not ($fixture.dir | path exists)
    assert (($fixture.nested | path join "nested.jsonl") | path exists)
    assert equal (
      open ($fixture.config | path join ".claude.json") | get projects | columns
    ) [($project | path join "sub")]
    assert equal (
      open ($fixture.config | path join ".claude.json") | get githubRepoPaths
    ) {"example/app": [($project | path join "sub")]}
  }
}

def make-omp [root: string, project: string]: nothing -> record {
  let dir = ($root | path join "omp/sessions" (session-encode-here $project))
  let memory = ($root | path join "state/omp/memories" (memory-encode $project))
  let parent_file = ($dir | path join "2026-01-01T00-00-00_parent.jsonl")
  let child_root = ($dir | path join "2026-01-01T00-00-00_parent")
  for row in [
    {id: "parent", cwd: $project, parentSession: null, file: $parent_file}
    {id: "child", cwd: $project, parentSession: "parent", file: ($child_root | path join "implementer/worker.jsonl")}
    {id: "grandchild", cwd: "/other/deeper", parentSession: ($child_root | path join "implementer/worker.jsonl"), file: ($child_root | path join "reviewer/worker.jsonl")}
    {id: "sibling", cwd: $project, parentSession: "parent", file: ($child_root | path join "auditor/agent.jsonl")}
    {id: "retained", cwd: $project, parentSession: null, file: ($dir | path join "retained.jsonl")}
  ] {
    write-jsonl $row.file [
      {type: "title", title: "A session title"}
      ($row | reject file | merge {type: "session", version: 3, timestamp: "2026-01-01T00:00:00Z"})
      {type: "message", id: "message", message: {role: "user", content: $row.id}}
    ]
  }
  "worker log" | save ($child_root | path join "implementer/worker.log")
  mkdir ($child_root | path join "implementer/worker")
  "child log" | save ($child_root | path join "implementer/worker/run.log")
  mkdir ($child_root | path join "reviewer/worker")
  {result: "child review"} | to json | save ($child_root | path join "reviewer/worker/result.json")
  {result: "review"} | to json | save ($child_root | path join "reviewer/result.json")
  "task notes" | save ($child_root | path join "notes.md")
  mkdir $memory
  "shared memory" | save ($memory | path join "MEMORY.md")
  {dir: $dir, memory: $memory, parent: $parent_file, children: $child_root}
}

def "test OMP file-only sessions preserve peers and shared memories until last retirement" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-omp $root $project)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export $project $directory --assistant omp --session-ids parent)
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

    let apply = (
      run-cli retire $project --assistant omp --session-ids parent --apply --no-backup
    )
    assert equal $apply.exit_code 0 $apply.stderr

    assert not ($fixture.parent | path exists)
    assert not ($fixture.children | path exists)
    assert (($fixture.dir | path join "retained.jsonl") | path exists)
    assert equal (open --raw ($fixture.memory | path join "MEMORY.md")) "shared memory"

    let final = (run-cli retire $project --assistant omp --exact --apply --no-backup)
    assert equal $final.exit_code 0 $final.stderr

    assert not ($fixture.memory | path exists)
  }
}

def "test an imported Codex id with different rollout content is rejected" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-codex $root $project)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export $project $directory --assistant codex --session-ids parent)
    assert equal $export.exit_code 0 $export.stderr

    "DELETE FROM thread_spawn_edges;" | ^sqlite3 $fixture.db

    let restore = (run-cli import $directory --assistant codex --apply)
    assert equal $restore.exit_code 0 $restore.stderr

    assert equal (sqlite-rows $fixture.db "SELECT * FROM thread_spawn_edges") [
      {parent_thread_id: "parent", child_thread_id: "child", status: "completed"}
    ]

    let same = (run-cli import $directory --assistant codex)
    assert equal $same.exit_code 0 $same.stderr
    assert str contains $same.stdout "Skipped"

    "UPDATE thread_spawn_edges SET parent_thread_id = 'retained';" | ^sqlite3 $fixture.db

    let relation_conflict = (run-cli import $directory --assistant codex --apply)

    assert ($relation_conflict.exit_code != 0) $relation_conflict.stdout
    assert equal (sqlite-rows $fixture.db "SELECT * FROM thread_spawn_edges") [
      {parent_thread_id: "retained", child_thread_id: "child", status: "completed"}
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
      {type: "response_item", payload: {role: "user", content: "different body"}}
      | to json --raw
    )
    let compression = ($changed | ^zstd -q -f -o $carried | complete)
    assert equal $compression.exit_code 0 $compression.stderr
    let before = (open --raw $fixture.db | hash sha256)

    let different = (run-cli import $directory --assistant codex --apply)

    assert ($different.exit_code != 0) $different.stdout
    assert equal (open --raw $fixture.db | hash sha256) $before
  }
}

def "test identical Claude sessions still import and validate their file history" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-claude $root $project)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export $project $directory --assistant claude --session-ids parent)
    assert equal $export.exit_code 0 $export.stderr
    rm --recursive ($fixture.config | path join "file-history")

    let import = (run-cli import $directory --assistant claude --apply)
    assert equal $import.exit_code 0 $import.stderr

    assert equal (
      open --raw ($fixture.config | path join "file-history/parent/file@v1")
    ) "original artifact"
    assert equal (
      open --raw ($fixture.config | path join "file-history/child/child@v1")
    ) "child artifact"

    "different artifact" | save --force ($fixture.config | path join "file-history/child/child@v1")

    let conflict = (run-cli import $directory --assistant claude --apply)

    assert ($conflict.exit_code != 0) $conflict.stdout
    assert equal (
      open --raw ($fixture.config | path join "file-history/child/child@v1")
    ) "different artifact"
  }
}

def "test OMP imports compare session header ids when filenames change" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-omp $root $project)
  let directory = ($root | path join "bundle")
  let renamed = ($fixture.dir | path join "renamed.jsonl")

  with-env (fixture-env $root) {
    let export = (run-cli export $project $directory --assistant omp --session-ids parent)
    assert equal $export.exit_code 0 $export.stderr
    mv $fixture.parent $renamed

    let same = (run-cli import $directory --assistant omp --apply)
    assert equal $same.exit_code 0 $same.stderr

    assert not ($fixture.parent | path exists)
    assert ($renamed | path exists)

    let changed = (
      open --raw $renamed | lines | each {|line| $line | from json }
      | each {|row|
        if $row.type == "message" {
          $row | update message.content "different body"
        } else { $row }
      }
    )
    rm $renamed
    write-jsonl $renamed $changed

    let conflict = (run-cli import $directory --assistant omp --apply)

    assert ($conflict.exit_code != 0) $conflict.stdout
    assert not ($fixture.parent | path exists)
  }
}

def "test nested OMP retirement backs up artifacts at their original relative paths" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-omp $root $project)
  let artifacts = [
    {name: "implementer/worker.log", body: "worker log"}
    {name: "notes.md", body: "task notes"}
    {name: "reviewer/result.json", body: ({result: "review"} | to json)}
  ]

  with-env (fixture-env $root) {
    let apply = (run-cli retire $project --assistant omp --session-ids parent --apply)
    assert equal $apply.exit_code 0 $apply.stderr

    let backup = (ls ($root | path join "state/agent-project-move") | get name | first)
    let subtree = ($backup | path join ($fixture.children | str trim --left --char "/"))
    for artifact in $artifacts {
      assert equal (open --raw ($subtree | path join $artifact.name)) $artifact.body
    }
    assert (($subtree | path join "implementer/worker.jsonl") | path exists)
    assert (($subtree | path join "reviewer/worker.jsonl") | path exists)
    assert (($fixture.dir | path join "retained.jsonl") | path exists)
  }
}

def make-omp-dbs [root: string, project: string, --empty]: nothing -> record {
  let agent = ($root | path join "omp/agent.db")
  let history = ($root | path join "omp/history.db")
  mkdir ($agent | path dirname)
  (
    "CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, rollout_path TEXT); "
    + "CREATE TABLE stage1_outputs (thread_id TEXT PRIMARY KEY, summary TEXT); "
    + "CREATE TABLE jobs (kind TEXT, job_key TEXT, result TEXT, PRIMARY KEY(kind, job_key));"
  ) | ^sqlite3 $agent
  (
    "CREATE TABLE history (id INTEGER PRIMARY KEY, session_id TEXT, cwd TEXT, prompt TEXT); "
    + "CREATE TABLE session_titles (session_id TEXT PRIMARY KEY, title TEXT); "
    + "CREATE TABLE session_recaps (id INTEGER PRIMARY KEY, session_id TEXT, cwd TEXT, "
    + "created_at INTEGER, recap TEXT); "
    + "CREATE VIRTUAL TABLE history_fts USING fts5(prompt, content='history', content_rowid='id');"
  ) | ^sqlite3 $history
  if not $empty {
    for row in [
      {id: "parent", cwd: $project, name: "2026-01-01T00-00-00_parent.jsonl"}
      {id: "child", cwd: $project, name: "2026-01-01T00-00-00_parent/implementer/worker.jsonl"}
      {id: "grandchild", cwd: "/other/deeper", name: "2026-01-01T00-00-00_parent/reviewer/worker.jsonl"}
      {id: "retained", cwd: $project, name: "retained.jsonl"}
    ] {
      let id = (sql-quote $row.id)
      let cwd = (sql-quote $row.cwd)
      let rollout = (
        $root | path join "omp/sessions" (session-encode-here $project) $row.name | sql-quote $in
      )
      (
        $"INSERT INTO threads VALUES \(($id), ($cwd), ($rollout)\); "
        + $"INSERT INTO stage1_outputs VALUES \(($id), ($id)\); "
        + $"INSERT INTO jobs VALUES \('summary', ($id), ($id)\);"
      ) | ^sqlite3 $agent
      (
        $"INSERT INTO history\(session_id, cwd, prompt\) VALUES \(($id), ($cwd), ($id)\); "
        + $"INSERT INTO session_titles VALUES \(($id), ($id)\); "
        + $"INSERT INTO session_recaps\(session_id, cwd, created_at, recap\) VALUES \(($id), ($cwd), 1, ($id)\);"
      ) | ^sqlite3 $history
    }
  }
  {agent: $agent, history: $history}
}

def "test OMP selection transfers disjoint cwd rows and their associated records" [] {
  let root = (mktemp -d)
  let source = ($root | path join "source")
  let target = ($root | path join "target")
  let project = "/home/u/src/app"
  make-omp $source $project | ignore
  let source_dbs = (make-omp-dbs $source $project)
  let target_dbs = (make-omp-dbs $target $project --empty)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $source) {
    let export = (run-cli export $project $directory --assistant omp --session-ids parent)
    assert equal $export.exit_code 0 $export.stderr
  }
  with-env (fixture-env $target) {
    let import = (run-cli import $directory --assistant omp --apply)
    assert equal $import.exit_code 0 $import.stderr
  }

  for spec in [
    {db: $target_dbs.agent, table: "threads", key: "id"}
    {db: $target_dbs.agent, table: "stage1_outputs", key: "thread_id"}
    {db: $target_dbs.agent, table: "jobs", key: "job_key"}
    {db: $target_dbs.history, table: "history", key: "session_id"}
    {db: $target_dbs.history, table: "session_titles", key: "session_id"}
    {db: $target_dbs.history, table: "session_recaps", key: "session_id"}
  ] {
    let rows = (sqlite-rows $spec.db $"SELECT ($spec.key) AS id FROM ($spec.table) ORDER BY id")

    assert equal $rows [{id: "child"} {id: "grandchild"} {id: "parent"}] $spec.table
  }

  let threads = (sqlite-rows $target_dbs.agent "SELECT id, rollout_path FROM threads ORDER BY id")
  for thread in $threads {
    assert str contains $thread.rollout_path ($target | path join "omp/sessions")
    let id = (
      open --raw $thread.rollout_path | lines | each {|line| $line | from json }
      | where type == "session" | first | get id
    )
    assert equal $id $thread.id
  }

  with-env (fixture-env $source) {
    let apply = (
      run-cli retire $project --assistant omp --session-ids parent --apply --no-backup
    )
    assert equal $apply.exit_code 0 $apply.stderr
  }

  assert equal (sqlite-rows $source_dbs.agent "SELECT id FROM threads") [{id: "retained"}]
  assert equal (sqlite-rows $source_dbs.agent "SELECT job_key FROM jobs") [{job_key: "retained"}]
  assert equal (sqlite-rows $source_dbs.history "SELECT session_id FROM history") [
    {session_id: "retained"}
  ]
}

def "test selecting a Codex child preserves its parent and sibling sessions" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-codex $root $project)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export "/other" $directory --assistant codex --session-ids child)
    assert equal $export.exit_code 0 $export.stderr

    assert equal (bundle-ids $directory "codex" "threads") ["child"]
    let edge = (
      open ($directory | path join "codex/entries.json")
      | get tables | where table == "thread_spawn_edges" | get 0.rows
    )
    assert equal $edge [
      {parent_thread_id: "parent", child_thread_id: "child", status: "completed"}
    ]

    let apply = (
      run-cli retire "/other" --assistant codex --session-ids child --apply --no-backup
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
  "DELETE FROM dependent; DELETE FROM thread_spawn_edges; DELETE FROM threads; DELETE FROM projects;"
  | ^sqlite3 $target_fixture.db
  rm --recursive ($target | path join "codex/sessions")

  with-env (fixture-env $target) {
    let import = (run-cli import $directory --assistant codex --apply)
    assert equal $import.exit_code 0 $import.stderr

    assert equal (sqlite-rows $target_fixture.db "SELECT id FROM threads") [{id: "child"}]
    assert equal (sqlite-rows $target_fixture.db "SELECT * FROM thread_spawn_edges") [
      {parent_thread_id: "parent", child_thread_id: "child", status: "completed"}
    ]
  }
}

def "test selecting a Claude subagent preserves its parent and other project files" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-claude $root $project)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export "/other" $directory --assistant claude --session-ids child)
    assert equal $export.exit_code 0 $export.stderr

    let entries = (open ($directory | path join "claude/entries.json"))
    assert equal ($entries.files | where kind == "projects" | get name | sort) [
      "memory/MEMORY.md"
      "parent/subagents/agent-child.jsonl"
    ]
    assert equal ($entries.files | where kind == "file-history" | get name) ["child@v1"]

    let apply = (
      run-cli retire "/other" --assistant claude --session-ids child --apply --no-backup
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

def "test selecting an OMP child carries only its descendants and own artifact subtree" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let fixture = (make-omp $root $project)
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export $project $directory --assistant omp --session-ids child)
    assert equal $export.exit_code 0 $export.stderr

    assert equal (
      open ($directory | path join "omp/entries.json")
      | get files | where kind == "sessions" | get name | sort
    ) [
      "2026-01-01T00-00-00_parent/implementer/worker.jsonl"
      "2026-01-01T00-00-00_parent/implementer/worker/run.log"
      "2026-01-01T00-00-00_parent/reviewer/worker.jsonl"
      "2026-01-01T00-00-00_parent/reviewer/worker/result.json"
    ]

    let apply = (
      run-cli retire $project --assistant omp --session-ids child --apply --no-backup
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
    assert equal (open --raw ($fixture.memory | path join "MEMORY.md")) "shared memory"
  }
}

def "test OMP rows without session ids cannot widen exact selection to protected sessions" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  make-omp $root $project | ignore
  let dbs = (make-omp-dbs $root $project)
  let protected = (
    $root | path join "omp/sessions" (session-encode-here "/safe/project") "protected.jsonl"
  )
  write-jsonl $protected [{type: "session", id: "protected", cwd: "/safe/project"}]
  let original = (open --raw $protected)
  (
    "INSERT INTO history(session_id, cwd, prompt) VALUES (NULL, " + (sql-quote $project)
    + ", 'selected metadata'), (NULL, '/safe/project', 'protected metadata');"
  ) | ^sqlite3 $dbs.history
  let directory = ($root | path join "bundle")

  with-env (fixture-env $root) {
    let export = (run-cli export $project $directory --assistant omp --exact)
    assert equal $export.exit_code 0 $export.stderr

    let entries = (open ($directory | path join "omp/entries.json"))
    assert not ("protected.jsonl" in ($entries.files | get name))

    let apply = (run-cli retire $project --assistant omp --exact --apply --no-backup)
    assert equal $apply.exit_code 0 $apply.stderr

    assert equal (open --raw $protected) $original
    assert equal (
      sqlite-rows $dbs.history "SELECT prompt FROM history WHERE cwd = '/safe/project'"
    ) [{prompt: "protected metadata"}]
  }
}

def "test default OMP export preserves path metadata without session ids" [] {
  let root = (mktemp -d)
  let source = ($root | path join "source")
  let target = ($root | path join "target")
  let project = "/home/u/src/app"
  let source_dbs = (make-omp-dbs $source $project --empty)
  let target_dbs = (make-omp-dbs $target $project --empty)
  let directory = ($root | path join "bundle")
  let key = (sql-quote ("global:" + $project))
  $"INSERT INTO jobs VALUES \('summary', ($key), 'global memory'\);" | ^sqlite3 $source_dbs.agent
  (
    "INSERT INTO history(session_id, cwd, prompt) VALUES (NULL, "
    + (sql-quote $project) + ", 'path prompt');"
  ) | ^sqlite3 $source_dbs.history

  with-env (fixture-env $source) {
    let export = (run-cli export $project $directory --assistant omp)
    assert equal $export.exit_code 0 $export.stderr
  }
  with-env (fixture-env $target) {
    let import = (run-cli import $directory --assistant omp --apply)
    assert equal $import.exit_code 0 $import.stderr
  }

  assert equal (sqlite-rows $target_dbs.agent "SELECT * FROM jobs") [
    {kind: "summary", job_key: ("global:" + $project), result: "global memory"}
  ]
  assert equal (sqlite-rows $target_dbs.history "SELECT session_id, cwd, prompt FROM history") [
    {session_id: null, cwd: $project, prompt: "path prompt"}
  ]
}

def "test flat OMP forks keep parent links after importing to a different state root" [] {
  let root = (mktemp -d)
  let source = ($root | path join "source")
  let target = ($root | path join "target")
  let project = "/home/u/src/app"
  let fixture = (make-omp $source $project)
  for row in [
    {id: "path-fork", parentSession: $fixture.parent}
    {id: "id-fork", parentSession: "parent"}
  ] {
    let file = ($fixture.dir | path join $"($row.id).jsonl")
    write-jsonl $file [
      ($row | merge {type: "session", cwd: $project})
      {type: "message", message: {role: "user", content: $fixture.parent}}
    ]
    let content = (open --raw $file)
    "  " + $content + "\n\n" | save --force $file
  }
  let directory = ($root | path join "bundle")

  with-env (fixture-env $source) {
    let export = (run-cli export $project $directory --assistant omp --session-ids parent)
    assert equal $export.exit_code 0 $export.stderr
  }
  with-env (fixture-env $target) {
    let import = (run-cli import $directory --assistant omp --apply)
    assert equal $import.exit_code 0 $import.stderr

    let destination = ($target | path join "omp/sessions" (session-encode-here $project))
    for row in [
      {id: "path-fork", parent: ($destination | path join "2026-01-01T00-00-00_parent.jsonl")}
      {id: "id-fork", parent: "parent"}
    ] {
      let parent = (
        open --raw ($destination | path join $"($row.id).jsonl")
        | lines | first | from json | get parentSession
      )
      assert equal $parent $row.parent $row.id
      let original = (open --raw ($fixture.dir | path join $"($row.id).jsonl"))
      let expected = if $row.id == "path-fork" {
        let old = ('"parentSession":' + ($fixture.parent | to json --raw))
        let new = ('"parentSession":' + ($row.parent | to json --raw))
        $original | str replace $old $new
      } else { $original }
      assert equal (open --raw ($destination | path join $"($row.id).jsonl")) $expected
    }

    let repeated = (run-cli import $directory --assistant omp --apply)
    assert equal $repeated.exit_code 0 $repeated.stderr
    let exported = ($root | path join "target-bundle")
    let export = (run-cli export $project $exported --assistant omp --session-ids parent)
    assert equal $export.exit_code 0 $export.stderr

    let names = (open ($exported | path join "omp/entries.json") | get files | get name)
    assert ("path-fork.jsonl" in $names)
    assert ("id-fork.jsonl" in $names)
  }
}

def "test OMP retirement removes recap titles without requiring a history row" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let dbs = (make-omp-dbs $root $project --empty)
  for id in ["selected" "retained"] {
    let value = (sql-quote $id)
    (
      $"INSERT INTO session_titles VALUES \(($value), ($value)\); "
      + "INSERT INTO session_recaps(session_id, cwd, created_at, recap) VALUES ("
      + $value + ", " + (sql-quote $project) + ", 1, " + $value + ");"
    ) | ^sqlite3 $dbs.history
  }

  with-env (fixture-env $root) {
    let apply = (
      run-cli retire $project --assistant omp --session-ids selected --apply --no-backup
    )
    assert equal $apply.exit_code 0 $apply.stderr

    assert equal (sqlite-rows $dbs.history "SELECT session_id, title FROM session_titles") [
      {session_id: "retained", title: "retained"}
    ]
    assert equal (sqlite-rows $dbs.history "SELECT session_id, recap FROM session_recaps") [
      {session_id: "retained", recap: "retained"}
    ]
  }
}
