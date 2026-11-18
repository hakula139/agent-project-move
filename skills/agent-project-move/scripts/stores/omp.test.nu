#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: OMP Tests
# ==================================================================================================

use std/assert

use ../common.testlib.nu [fixture-env run-cli write-jsonl]
use ../lib/sqlite.nu [sql-quote]
use ./omp.nu [scan session-encode-here]

def "test OMP encodes session directories by location" [] {
  let cases = [
    {
      name: "a project under home"
      path: "/home/tester/src/app"
      encoded: "-src-app"
    }
    {
      name: "home itself"
      path: "/home/tester"
      encoded: "-"
    }
    {
      name: "a child of the temp root"
      path: "/tmp/omp-test"
      encoded: "-tmp-omp-test"
    }
    {
      name: "the temp root"
      path: "/tmp"
      encoded: "-tmp-"
    }
    {
      name: "a path outside both roots"
      path: "/opt/x"
      encoded: "--opt-x--"
    }
  ]

  with-env {
    HOME: "/home/tester"
    TMPDIR: "/tmp"
  } {
    for case in $cases {
      assert equal (session-encode-here $case.path) $case.encoded $case.name
    }
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

def "test selected OMP moves map nested and flat descendants while preserving peers" [] {
  let root = (mktemp -d | path expand)
  let project = "/home/u/src/app"
  let target = ($root | path join "moved")
  mkdir $target
  let fixture = (make-omp $root $project)
  let destination = ($root | path join "omp/sessions" (session-encode-here $target))
  let flat = ($fixture.dir | path join "flat.jsonl")
  let external = (
    $root | path join "omp/sessions" (session-encode-here "/other/external") "outside.jsonl"
  )
  write-jsonl $flat [
    {
      type: "session"
      id: "flat"
      cwd: "/other/flat"
      parentSession: $fixture.parent
    }
    {
      type: "message"
      path: $"($project)/flat.txt"
    }
  ]
  write-jsonl $external [
    {
      type: "session"
      id: "external"
      cwd: "/other/external"
      parentSession: $fixture.parent
    }
    {
      type: "message"
      path: $"($project)/external.txt"
    }
  ]
  mkdir ($fixture.dir | path join "flat")
  "flat artifact" | save ($fixture.dir | path join "flat/notes.md")
  let retained = ($fixture.dir | path join "retained.jsonl")
  rm $retained
  write-jsonl $retained [
    {
      type: "session"
      id: "retained"
      cwd: $project
    }
    {
      type: "message"
      path: $"($project)/peer.txt"
      parent: $fixture.parent
    }
  ]
  let retained_bytes = (open --raw $retained | into binary)
  let globals = (
    ["omp/agent.db" "omp/history.db" "omp/blobs/kept" "state/omp/memories/kept/MEMORY.md"]
    | each {|name|
      let file = ($root | path join $name)
      mkdir ($file | path dirname)
      $project | save $file
      {
        file: $file
        bytes: (open --raw $file | into binary)
      }
    }
    | collect
  )
  let child = ($fixture.children | path join "implementer/worker.jsonl")
  let checks = (
    (glob ($fixture.dir | path join "**/*") | where {|file| ($file | path type) == "file" })
    | where {|file| $file != $retained }
    | append $external
    | each {|file|
      let moved = if $file == $external {
        $external
      } else {
        $destination | path join ($file | path relative-to $fixture.dir)
      }
      mut expected = (open --raw $file | into string)
      if ($file | str ends-with ".jsonl") {
        $expected = (
          $expected | str replace --all ($project | to json --raw) ($target | to json --raw)
        )
        for name in ["flat" "external"] {
          $expected = (
            $expected
            | str replace ($"($project)/($name).txt" | to json --raw) (
              $"($target)/($name).txt" | to json --raw
            )
          )
        }
        for parent in [$fixture.parent $child] {
          let mapped = ($destination | path join ($parent | path relative-to $fixture.dir))
          let original = $'"parentSession":($parent | to json --raw)'
          let replacement = $'"parentSession":($mapped | to json --raw)'
          $expected = ($expected | str replace $original $replacement)
        }
      }
      {
        source: $file
        target: $moved
        expected: $expected
      }
    }
    | collect
  )

  let moved = (with-env (fixture-env $root) {
    run-cli move $project $target --assistant "omp" --session-ids "parent" --apply --no-backup
  })
  assert equal $moved.exit_code 0 $moved.stderr

  for check in $checks {
    assert equal (open --raw $check.target) $check.expected $check.target
    if $check.source != $check.target {
      assert not ($check.source | path exists) $check.source
    }
  }
  assert equal (open --raw $retained | into binary) $retained_bytes
  for original in $globals {
    assert equal (open --raw $original.file | into binary) $original.bytes $original.file
  }

  let args = [
    "move" $project $target "--assistant" "omp"
    "--session-ids" "parent,external,unknown" "--apply" "--no-backup"
  ]
  let repeated = (with-env (fixture-env $root) {
    run-cli ...$args
  })
  assert equal $repeated.exit_code 0 $repeated.stderr
  assert str contains $repeated.stdout "No changes."

  let root = (mktemp -d | path expand)
  let project = ($root | path join "source")
  let target = ($root | path join "moved")
  mkdir $target
  let fixture = (make-omp $project $project)
  let child = ($fixture.children | path join "implementer/worker.jsonl")
  let child_rows = (
    open --raw $child
    | lines
    | each {|line|
      let row = ($line | from json)
      if $row.type == "session" { $row | upsert parentSession $fixture.parent } else { $row }
    }
  )
  $child_rows
  | each {|row| $row | to json --raw }
  | str join "\n"
  | save --force $child
  let parent_bytes = (open --raw $fixture.parent | into binary)
  let destination = ($project | path join "omp/sessions" (session-encode-here $target))
  let moved_child = ($destination | path join ($child | path relative-to $fixture.dir))

  let moved = (with-env (fixture-env $project) {
    run-cli move $project $target --assistant "omp" --session-ids "child" --apply --no-backup
  })
  assert equal $moved.exit_code 0 $moved.stderr

  assert equal (open --raw $fixture.parent | into binary) $parent_bytes
  assert equal (
    open --raw $moved_child | lines | each {|line| $line | from json }
  ) ($child_rows | each {|row|
    if $row.type == "session" { $row | upsert cwd $target } else { $row }
  })
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
  let archive_name = "archived[1]*.jsonl"
  let archive = (
    $source | path join "omp/archive/sessions" (session-encode-here $project) $archive_name
  )
  let retained = ($fixture.dir | path join "retained.jsonl")
  let external_parent = ($fixture.dir | path join "external.jsonl")
  rm $retained
  write-jsonl $retained [
    {type: "session", id: "retained", cwd: $project, parentSession: $external_parent}
    {type: "message", message: {role: "user", content: $fixture.parent}}
  ]
  for file in (glob ($fixture.dir | path join "**/*.jsonl")) {
    ^touch -d "2026-01-01T00:00:00Z" $file
  }
  write-jsonl $archive [
    {type: "session", id: "archived", cwd: "/other/deeper", parentSession: $fixture.parent}
  ]
  ^touch -d "2026-01-02T00:00:00Z" $archive
  mkdir $moved

  let moved_dir = ($source | path join "omp/sessions" (session-encode-here $moved))
  let moved_archive = (
    $source | path join "omp/archive/sessions" (session-encode-here $moved) $archive_name
  )
  let child = ($fixture.children | path join "implementer/worker.jsonl")
  let artifact = ($fixture.children | path join "notes.md")
  $fixture.parent | save --force $artifact
  let move_checks = (
    (glob ($fixture.dir | path join "**/*.jsonl"))
    | append [$archive $artifact]
    | each {|file|
      let target = if $file == $archive {
        $moved_archive
      } else {
        $moved_dir | path join ($file | path relative-to $fixture.dir)
      }
      mut expected = (open --raw $file)
      if $file != $artifact {
        $expected = (
          $expected
          | str replace --all ($project | to json --raw) ($moved | to json --raw)
        )
        for parent in [$fixture.parent $child] {
          let mapped = ($moved_dir | path join ($parent | path relative-to $fixture.dir))
          $expected = (
            $expected
            | str replace ('"parentSession":' + ($parent | to json --raw)) (
              '"parentSession":' + ($mapped | to json --raw)
            )
          )
        }
      }
      {target: $target, expected: $expected}
    }
  )

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

      if $args.0 == "move" {
        for check in $move_checks {
          assert equal (open --raw $check.target) $check.expected $check.target
        }
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
      | path join "omp/archive/sessions" (session-encode-here "/other/deeper") $archive_name
    )
    assert ($archived | path exists)
    for path in ["omp/agent.db" "omp/history.db" "state/omp"] {
      assert not ($target | path join $path | path exists) $path
    }
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

def "test OMP moves preserve archives, explicit parentSession precedence, and non-UTF-8 errors" [] {
  let root = (mktemp -d | path expand)
  let project = "/home/u/src/app"
  let target = ($root | path join "moved")
  mkdir $target

  let session_dir = ($root | path join "omp/sessions" (session-encode-here $project))
  let archive_dir = ($root | path join "omp/archive/sessions" (session-encode-here $project))
  let target_session_dir = ($root | path join "omp/sessions" (session-encode-here $target))
  let target_archive_dir = ($root | path join "omp/archive/sessions" (session-encode-here $target))
  let other_dir = ($root | path join "omp/sessions" (session-encode-here "/o"))

  let container = ($session_dir | path join "00000000000000000000_container.jsonl")
  let external_parent = ($other_dir | path join "p.jsonl")
  let nested = ($session_dir | path join "00000000000000000000_container/nested.jsonl")
  let archived = ($archive_dir | path join "archived.jsonl")

  write-jsonl $container [
    {
      type: "session"
      id: "container"
      cwd: $project
    }
  ]
  write-jsonl $external_parent [
    {
      type: "session"
      id: "real-parent"
      cwd: "/o"
    }
  ]
  write-jsonl $nested [
    {
      type: "session"
      id: "nested"
      cwd: "/other/worker"
      parentSession: $external_parent
    }
    {
      type: "message"
      path: $"($project)/worker.txt"
    }
  ]
  write-jsonl $archived [
    {
      type: "session"
      id: "archived"
      cwd: $project
      parentSession: $external_parent
    }
  ]
  let nested_bytes = (open --raw $nested | into binary)

  let args = [
    "move" $project $target "--assistant" "omp"
    "--session-ids" "container,archived" "--apply"
  ]
  let selected_move = (with-env (fixture-env $root) {
    run-cli ...$args
  })
  assert equal $selected_move.exit_code 0 $selected_move.stderr

  let backup_dir = (
    ls ($root | path join "state/agent-project-move")
    | get name
    | first
  )
  let manifest = (open ($backup_dir | path join "manifest.json"))
  assert equal (
    $manifest
    | where path == $archived
    | get store
  ) [
    "archives"
    "archives"
  ]
  let relocated_nested = (
    $target_session_dir
    | path join "00000000000000000000_container/nested.jsonl"
  )
  assert equal (open --raw $relocated_nested | into binary) $nested_bytes
  assert (($target_session_dir | path join "00000000000000000000_container.jsonl") | path exists)
  assert equal (
    open --raw ($target_archive_dir | path join "archived.jsonl")
    | from json
  ) {
    type: "session"
    id: "archived"
    cwd: $target
    parentSession: $external_parent
  }

  let explicit_bundle = ($root | path join "explicit-bundle")
  with-env (fixture-env $root) {
    let exported = (
      run-cli export "/o" $explicit_bundle --assistant "omp" --session-ids "real-parent"
    )
    assert equal $exported.exit_code 0 $exported.stderr
  }
  assert equal (
    open ($explicit_bundle | path join "omp/entries.json")
    | get files
    | get session
    | sort
  ) [
    "archived"
    "nested"
    "real-parent"
  ]

  let default_root = (mktemp -d | path expand)
  let default_target = ($default_root | path join "moved")
  mkdir $default_target
  let default_dir = ($default_root | path join "omp/sessions" (session-encode-here $project))
  let outside_parent = ($project | path join "untracked-parent.jsonl")
  let session_file = ($default_dir | path join "main.jsonl")
  write-jsonl $session_file [
    {
      type: "session"
      id: "main"
      cwd: $project
      parentSession: $outside_parent
    }
  ]

  let default_move = (with-env (fixture-env $default_root) {
    run-cli move $project $default_target --assistant "omp" --apply --no-backup
  })
  assert equal $default_move.exit_code 0 $default_move.stderr

  let moved_main = (
    $default_root
    | path join "omp/sessions" (session-encode-here $default_target) "main.jsonl"
  )
  assert equal (open --raw $moved_main | from json) {
    type: "session"
    id: "main"
    cwd: $default_target
    parentSession: $outside_parent
  }

  let binary_root = (mktemp -d | path expand)
  let binary_dir = ($binary_root | path join "omp/sessions" (session-encode-here $project))
  let valid_parent = ($binary_dir | path join "valid.jsonl")
  let bad_child = ($binary_dir | path join "valid/corrupt.jsonl")
  write-jsonl $valid_parent [
    {
      type: "session"
      id: "valid"
      cwd: $project
    }
  ]
  mkdir ($bad_child | path dirname)
  (
    (
      {
        type: "session"
        id: "corrupt"
        cwd: $project
        parentSession: "valid"
      }
      | to json --raw
      | into binary
    )
    | bytes add --end 0x[0a 80 0a]
  ) | save $bad_child

  let bad_bytes = (open --raw $bad_child | into binary)
  for args in [
    ["move" $project $default_target "--session-ids" "valid"]
    ["move" $project $default_target "--apply" "--no-backup"]
  ] {
    let refused = (with-env (fixture-env $binary_root) {
      run-cli ...$args --assistant "omp"
    })
    assert not equal $refused.exit_code 0 ($args | str join " ")
    assert str contains $refused.stderr "Refusing to edit the binary file"
    assert equal (open --raw $bad_child | into binary) $bad_bytes
  }
}
