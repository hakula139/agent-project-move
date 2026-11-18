#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Claude Code Tests
# ==================================================================================================

use std/assert

use ../common.testlib.nu [fixture-env run-cli write-jsonl]
use ./claude.nu [encode-path]

const SCRIPT_DIR = path self "."

const FIXTURES = ($SCRIPT_DIR | path join "fixtures/claude-encoding")

def "test Claude encodes project directory names" [] {
  for case in (
    glob ($FIXTURES | path join "*/case.nuon")
    | sort
  ) {
    let expected = (open $case)
    let name = (
      $case
      | path dirname
      | path basename
    )

    assert equal (encode-path $expected.path) $expected.encoded $name
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

def "test selected Claude moves preserve peers and shared project state" [] {
  for selected in ["parent" "child"] {
    let root = (mktemp -d | path expand)
    let project = "/home/u/src/app"
    let target = ($root | path join "moved")
    mkdir $target
    let fixture = (make-claude $root $project)
    let destination = ($fixture.config | path join "projects" (encode-path $target))
    let parent = ($fixture.dir | path join "parent.jsonl")
    let retained = ($fixture.dir | path join "retained.jsonl")
    rm $retained
    write-jsonl $retained [
      {
        type: "user"
        sessionId: "retained"
        cwd: $project
      }
    ]
    let child = (open --raw $fixture.child | from json)
    $child
    | upsert cwd $"($project)/worker"
    | to json --raw
    | save --force $fixture.child
    let child_artifact = ($fixture.dir | path join "parent/subagents/agent-child/notes.md")
    mkdir ($child_artifact | path dirname)
    $project | save $child_artifact
    let external = (
      $fixture.config
      | path join "projects" (encode-path "/other/external") "parent/subagents/agent-external.jsonl"
    )
    write-jsonl $external [
      {
        type: "assistant"
        sessionId: "external"
        cwd: "/other/external"
        path: $project
      }
    ]
    let unchanged = (
      [
        $retained
        ($fixture.nested | path join "nested.jsonl")
        ($fixture.dir | path join "memory/MEMORY.md")
        ($fixture.dir | path join "memory/notes.jsonl")
        ($fixture.dir | path join "sessions-index.json")
        ($fixture.config | path join "history.jsonl")
        ($fixture.config | path join ".claude.json")
        ($fixture.config | path join "file-history/parent/file@v1")
        ($fixture.config | path join "file-history/child/child@v1")
      ]
      | each {|file|
        {
          file: $file
          bytes: (open --raw $file | into binary)
        }
      }
      | collect
    )
    let parent_bytes = (open --raw $parent | into string)
    let artifact_names = if $selected == "parent" {
      ["parent/output.json" "parent/output.jsonl" "parent/subagents/agent-child/notes.md"]
    } else {
      ["parent/subagents/agent-child/notes.md"]
    }
    let artifacts = (
      $artifact_names
      | each {|name|
        {
          name: $name
          bytes: (open --raw ($fixture.dir | path join $name) | into binary)
        }
      }
      | collect
    )
    if $selected == "parent" {
      mkdir $destination
      "conflicting transcript" | save ($destination | path join "parent.jsonl")

      let args = [
        "move" $project $target "--assistant" "claude"
        "--session-ids" $selected "--apply" "--no-backup"
      ]
      let rejected = (with-env (fixture-env $root) {
        run-cli ...$args
      })
      assert not equal $rejected.exit_code 0

      assert equal (open --raw $parent) $parent_bytes
      assert equal (open --raw ($destination | path join "parent.jsonl")) "conflicting transcript"
      for artifact in $artifacts {
        assert equal (
          open --raw ($fixture.dir | path join $artifact.name) | into binary
        ) $artifact.bytes
      }
      rm ($destination | path join "parent.jsonl")
    }

    let moved = (with-env (fixture-env $root) {
      run-cli move $project $target --assistant "claude" --session-ids $selected --apply --no-backup
    })
    assert equal $moved.exit_code 0 $moved.stderr

    let imported_child = ($destination | path join "parent/subagents/agent-child.jsonl")
    assert equal (open --raw $imported_child | from json) (
      $child
      | merge {
        cwd: $"($target)/worker"
        message: {
          content: [
            {
              type: "tool_use"
              id: "read-child"
              name: "Read"
              input: {file_path: $target}
            }
          ]
        }
      }
    )
    assert not ($fixture.child | path exists)
    for artifact in $artifacts {
      assert equal (
        open --raw ($destination | path join $artifact.name) | into binary
      ) $artifact.bytes
      assert not (($fixture.dir | path join $artifact.name) | path exists)
    }
    if $selected == "parent" {
      assert not ($parent | path exists)
      assert equal (
        open --raw ($destination | path join "parent.jsonl")
      ) ($parent_bytes | str replace ($project | to json --raw) ($target | to json --raw))
      assert equal (open --raw $external | from json) {
        type: "assistant"
        sessionId: "external"
        cwd: "/other/external"
        path: $target
      }
    } else {
      assert equal (open --raw $parent) $parent_bytes
      assert equal (open --raw ($fixture.dir | path join "parent/output.json")) (
        $'{ "cwd": "($project)", "sessionId": "artifact" }'
      )
      assert equal (open --raw $external | from json) {
        type: "assistant"
        sessionId: "external"
        cwd: "/other/external"
        path: $project
      }
    }
    for original in $unchanged {
      assert equal (open --raw $original.file | into binary) $original.bytes $original.file
    }

    let repeated = (with-env (fixture-env $root) {
      run-cli move $project $target --assistant "claude" --session-ids $selected --apply --no-backup
    })
    assert equal $repeated.exit_code 0 $repeated.stderr
    assert str contains $repeated.stdout "No changes."
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
    assert equal (
      $shared | each {|name| open --raw ($fixture.dir | path join $name) }
    ) $shared_contents
    assert equal ($state | each {|name| open --raw ($fixture.config | path join $name) }) $originals

    let final = (run-cli retire "/other/retained" --assistant "claude" --exact --apply --no-backup)
    assert equal $final.exit_code 0 $final.stderr

    assert not (($fixture.dir | path join "retained.jsonl") | path exists)
    assert (($fixture.nested | path join "nested.jsonl") | path exists)
    assert equal (
      $shared | each {|name| open --raw ($fixture.dir | path join $name) }
    ) $shared_contents
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
    {
      name: "same owner"
      owner: $project
      artifact: true
      succeeds: true
    }
    {
      name: "other owner"
      owner: "/home/u/other"
      artifact: true
      succeeds: false
    }
    {
      name: "already imported"
      owner: "/home/u/other"
      artifact: false
      succeeds: true
    }
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

def "test Claude carries subagent meta sidecars and resolves parentAgentId hierarchies" [] {
  let root = (mktemp -d | path expand)
  let project = "/home/u/src/app"
  let target = ($root | path join "moved")
  mkdir $target
  let fixture = (make-claude $root $project)
  let subagents = ($fixture.dir | path join "parent/subagents")

  {
    agentType: "implementer"
    spawnDepth: 1
  }
  | to json --raw
  | save ($subagents | path join "agent-child.meta.json")

  let grandchild = ($subagents | path join "agent-grandchild.jsonl")
  write-jsonl $grandchild [
    {
      type: "assistant"
      sessionId: "grandchild"
      cwd: "/other/grandchild"
      path: $"($project)/deep.txt"
    }
  ]
  {
    agentType: "reviewer"
    parentAgentId: "child"
    spawnDepth: 2
  }
  | to json --raw
  | save ($subagents | path join "agent-grandchild.meta.json")

  let sibling = ($subagents | path join "agent-sibling.jsonl")
  write-jsonl $sibling [
    {
      type: "assistant"
      sessionId: "sibling"
      cwd: "/other/sibling"
      path: $"($project)/sibling.txt"
    }
  ]
  {
    agentType: "researcher"
    spawnDepth: 1
  }
  | to json --raw
  | save ($subagents | path join "agent-sibling.meta.json")

  let child_transcript = (open --raw $fixture.child | from json)
  $child_transcript
  | upsert cwd $"($project)/worker"
  | to json --raw
  | save --force $fixture.child

  let bundle = ($root | path join "bundle")
  with-env (fixture-env $root) {
    let exported = (run-cli export $project $bundle --assistant "claude" --session-ids "child")
    assert equal $exported.exit_code 0 $exported.stderr
  }

  let exported_names = (
    open ($bundle | path join "claude/entries.json")
    | get files
    | where kind == "projects"
    | get name
    | sort
  )
  assert equal $exported_names [
    "parent/subagents/agent-child.jsonl"
    "parent/subagents/agent-child.meta.json"
    "parent/subagents/agent-grandchild.jsonl"
    "parent/subagents/agent-grandchild.meta.json"
  ]

  let import_root = ($root | path join "imported")
  with-env (fixture-env $import_root) {
    let imported = (
      run-cli import $bundle --assistant "claude" --target $target --apply --no-backup
    )
    assert equal $imported.exit_code 0 $imported.stderr

    let imported_dir = ($import_root | path join "claude/projects" (encode-path $target))
    assert (
      ($imported_dir | path join "parent/subagents/agent-grandchild.meta.json")
      | path exists
    )
    assert equal (
      open --raw ($imported_dir | path join "parent/subagents/agent-grandchild.jsonl")
      | from json
      | get path
    ) $"($target)/deep.txt"

    let retired = (
      run-cli retire $target --assistant "claude" --session-ids "child" --apply --no-backup
    )
    assert equal $retired.exit_code 0 $retired.stderr

    for name in $exported_names {
      assert not (($imported_dir | path join $name) | path exists) $name
    }
  }

  let sibling_bytes = (open --raw $sibling | into binary)
  let sibling_meta_bytes = (
    open --raw ($subagents | path join "agent-sibling.meta.json") | into binary
  )

  let moved = (with-env (fixture-env $root) {
    run-cli move $project $target --assistant "claude" --session-ids "child" --apply --no-backup
  })
  assert equal $moved.exit_code 0 $moved.stderr

  let destination = ($fixture.config | path join "projects" (encode-path $target))
  for name in $exported_names {
    assert (($destination | path join $name) | path exists) $name
    assert not (($fixture.dir | path join $name) | path exists) $name
  }
  assert equal (
    open --raw ($destination | path join "parent/subagents/agent-grandchild.jsonl")
    | from json
    | get path
  ) $"($target)/deep.txt"
  assert equal (open --raw $sibling | into binary) $sibling_bytes
  assert equal (
    open --raw ($subagents | path join "agent-sibling.meta.json") | into binary
  ) $sibling_meta_bytes
}
