#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: OMP Blob Transfer Tests
# ==================================================================================================

use std/assert

use ../lib/rewrite.nu [file-uri]
use ./omp.nu [session-encode-here]
use ./omp-blobs.nu [references rewrite-paths]

const SCRIPT = path self "../agent-project-move.nu"

def fixture-env [root: string]: nothing -> record {
  {
    CLAUDE_CONFIG_DIR: ($root | path join "claude")
    CODEX_HOME: ($root | path join "codex")
    PI_CODING_AGENT_DIR: ($root | path join "omp")
    TZ: "UTC"
    XDG_STATE_HOME: ($root | path join "state")
  }
}

def --wrapped run-cli [...args: string]: nothing -> record {
  ^$nu.current-exe $SCRIPT ...$args | complete
}

def write-jsonl [file: string, rows: list<record>] {
  mkdir ($file | path dirname)
  $rows
  | each {|row| $row | to json --raw }
  | str join "\n"
  | save --force $file
}

def escape-path-tokens [content: string, paths: list<string>, escape: string]: nothing -> string {
  mut encoded = $content
  for path in $paths {
    let token = ($path | to json --raw)
    let escaped = ($token | str replace --all "/" $escape)
    $encoded = ($encoded | str replace --all $token $escaped)
  }
  $encoded
}

def blob-row [data: binary, suffix: string]: nothing -> record {
  {
    id: ($data | hash sha256)
    data: $data
    suffix: $suffix
  }
}

def parent-rows [project: string, blob_root: string, prose_root: string, blobs: list<record>] {
  let display = ($blob_root | path join ($blobs.2.id + $blobs.2.suffix))
  [
    {
      type: "session"
      id: "parent"
      cwd: $project
    }
    {
      type: "message"
      message: {
        content: [
          {
            type: "image"
            data: $"blob:sha256:($blobs.0.id)"
          }
          {
            type: "text"
            text: $"Prior image ($blobs.3.id)($blobs.3.suffix). Historical root ($prose_root). Unrelated digest ($blobs.4.id)."
          }
        ]
        details: {
          files: [$display (file-uri $display)]
        }
      }
    }
    {
      type: "compaction"
      preserveData: {
        snapcompact: {
          frames: [{data: $"blob:sha256:($blobs.1.id)"}]
        }
      }
    }
  ]
}

def make-fixture [root: string, project: string = "/home/u/src/app"]: nothing -> record {
  let blobs = [
    (blob-row 0x[00 01 02 ff] ".png")
    (blob-row 0x[03 04 05 fe] ".webp")
    (blob-row 0x[06 07 08 fd] ".jpg")
    (blob-row 0x[09 0a 0b fc] ".png")
    (blob-row 0x[0c 0d 0e fb] ".png")
  ]
  let dir = ($root | path join "omp")
  let blob_root = ($dir | path join "blobs")
  let directory = ($dir | path join "sessions" (session-encode-here $project))
  let parent = ($directory | path join "parent.jsonl")
  let child = ($directory | path join "child.jsonl")
  let peer = ($directory | path join "peer.jsonl")
  mkdir $blob_root

  for blob in $blobs {
    $blob.data | save ($blob_root | path join $blob.id)
    $blob.data | save ($blob_root | path join ($blob.id + $blob.suffix))
  }

  let rows = (parent-rows $project $blob_root $blob_root $blobs)
  write-jsonl $parent $rows
  write-jsonl $child [
    {
      type: "session"
      id: "child"
      cwd: "/home/u/work/child"
      parentSession: "parent"
    }
    {
      type: "message"
      message: {
        content: [
          {
            type: "image"
            data: $"blob:sha256:($blobs.1.id)"
          }
        ]
      }
    }
  ]
  write-jsonl $peer [
    {
      type: "session"
      id: "peer"
      cwd: $project
    }
    {
      type: "message"
      message: {
        content: [
          {
            type: "text"
            text: $"Keep blob:sha256:($blobs.1.id)."
          }
        ]
      }
    }
  ]

  {
    project: $project
    root: $dir
    blob_root: $blob_root
    directory: $directory
    parent: $parent
    child: $child
    peer: $peer
    blobs: $blobs
  }
}

def blob-names [blobs: list<record>]: nothing -> list<string> {
  $blobs
  | each {|blob| [$blob.id ($blob.id + $blob.suffix)] }
  | flatten
  | sort
}

def assert-blobs [root: string, blobs: list<record>] {
  for blob in $blobs {
    for name in [$blob.id ($blob.id + $blob.suffix)] {
      let file = ($root | path join $name)
      assert ($file | path exists) $name
      assert equal (open --raw $file | into binary) $blob.data $name
    }
  }
}

def "test OMP reference extraction decodes escaped locators and blob paths" [] {
  let root = (mktemp -d)
  let source = "/home/u/.omp/agent/blobs"
  let id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let escaped_id = (1..64 | each { '\u0061' } | str join)
  let alias = ($id + ".png")
  let native_expected = [
    {
      id: $id
      aliases: []
    }
  ]
  let alias_expected = [
    {
      id: $id
      aliases: [$alias]
    }
  ]
  let native = ({
    type: "message"
    data: $"blob:sha256:($id)"
  } | to json --raw)
  let path = ({
    type: "message"
    path: ($source | path join $alias)
  } | to json --raw)
  let uri = ({
    type: "message"
    path: (file-uri ($source | path join $alias))
  } | to json --raw)
  let cases = [
    {
      name: "native"
      content: $native
      expected: $native_expected
    }
    {
      name: "unicode native"
      content: (
        $native
        | str replace $id $escaped_id
        | str replace "blob:sha256:" ('\u0062lob\u003a' + 'sha256\u003a')
      )
      expected: $native_expected
    }
    {
      name: "escaped absolute path"
      content: ($path | str replace --all "/" '\/' | str replace $id $escaped_id)
      expected: $alias_expected
    }
    {
      name: "escaped file URI"
      content: ($uri | str replace --all "/" '\/' | str replace $id $escaped_id)
      expected: $alias_expected
    }
    {
      name: "embedded locator with terminal punctuation"
      content: ({
        type: "message"
        text: $"See blob:sha256:($id)."
      } | to json --raw)
      expected: $native_expected
    }
    {
      name: "documentary prefix literal"
      content: ({
        type: "message"
        text: 'const BLOB_PREFIX = "blob:sha256:"'
      } | to json --raw)
      expected: []
    }
  ]

  for case in $cases {
    let journal = ($root | path join ($case.name + ".jsonl"))
    $case.content | save $journal

    let found = (references [$journal] [$source])

    assert equal $found $case.expected $case.name
  }
}

def "test OMP export carries selected native and historical blob dependencies" [] {
  let root = (mktemp -d)
  let fixture = (make-fixture $root)
  let bundle = ($root | path join "bundle")
  let carried = ($fixture.blobs | first 4)

  let run = (with-env (fixture-env $root) {
    run-cli export $fixture.project $bundle --assistant "omp" --session-ids "parent"
  })
  assert equal $run.exit_code 0 $run.stderr

  let entries = (open ($bundle | path join "omp/entries.json"))
  let files = ($entries.files | where kind == "blobs")
  assert equal ($files | get -o name | sort) (blob-names $carried)
  assert equal ($entries.dependencies.sessions | get id | sort) ["child" "parent"]
  for file in $files {
    let source = ($fixture.blob_root | path join $file.name)
    let copy = ($bundle | path join "omp" $file.bundle)
    assert equal (open --raw $copy | into binary) (open --raw $source | into binary) $file.name
  }
}

def "test OMP import preserves blob bytes and maps only complete dependency paths" [] {
  let root = (mktemp -d)
  let fixture = (make-fixture ($root | path join "source"))
  let bundle = ($root | path join "bundle")
  let target = ($root | path join "target")
  let target_blobs = ($target | path join "omp/blobs")
  let display = ($fixture.blob_root | path join ($fixture.blobs.2.id + $fixture.blobs.2.suffix))
  let original = (open --raw $fixture.parent | into string)
  let encoded = (escape-path-tokens $original [$display] '\u002f')
  escape-path-tokens $encoded [(file-uri $display)] '\/' | save --force $fixture.parent

  let exported = (with-env (fixture-env ($root | path join "source")) {
    run-cli export $fixture.project $bundle --assistant "omp" --session-ids "parent"
  })
  assert equal $exported.exit_code 0 $exported.stderr

  let imported = (with-env (fixture-env $target) {
    run-cli import $bundle --assistant "omp" --apply
  })
  assert equal $imported.exit_code 0 $imported.stderr

  let parent = (glob ($target | path join "omp/sessions/*/parent.jsonl") | first)
  assert-blobs $target_blobs ($fixture.blobs | first 4)
  assert equal (
    ls $target_blobs | get name | path basename | sort
  ) (blob-names ($fixture.blobs | first 4))
  let expected = (
    parent-rows $fixture.project $target_blobs $fixture.blob_root $fixture.blobs
    | each {|row| $row | to json --raw }
    | str join "\n"
  )
  assert equal (open --raw $parent | into string) $expected

  let repeated = (with-env (fixture-env $target) {
    run-cli import $bundle --assistant "omp" --apply
  })
  assert equal $repeated.exit_code 0 $repeated.stderr
  assert str contains $repeated.stdout "No changes."

  let changed = ($expected | str replace "Prior image" "Local note")
  $changed | save --force $parent

  let conflict = (with-env (fixture-env $target) {
    run-cli import $bundle --assistant "omp" --apply
  })
  assert not equal $conflict.exit_code 0

  assert equal (open --raw $parent | into string) $changed
  assert-blobs $target_blobs ($fixture.blobs | first 4)
}

def "test OMP target imports keep local blob paths under an enclosing project root" [] {
  let root = (mktemp -d)
  let source = ($root | path join "source")
  let fixture = (make-fixture $source $source)
  let bundle = ($root | path join "bundle")
  let target = ($root | path join "target")
  let project = ($root | path join "work/app")
  let target_blobs = ($target | path join "omp/blobs")
  mkdir $project

  let exported = (with-env (fixture-env $source) {
    run-cli export $fixture.project $bundle --assistant "omp" --session-ids "parent"
  })
  assert equal $exported.exit_code 0 $exported.stderr

  let imported = (with-env (fixture-env $target) {
    run-cli import $bundle --assistant "omp" --target $project --apply
  })
  assert equal $imported.exit_code 0 $imported.stderr

  let parent = (glob ($target | path join "omp/sessions/*/parent.jsonl") | first)
  assert-blobs $target_blobs ($fixture.blobs | first 4)
  let expected = (
    parent-rows ($project | path expand) $target_blobs $fixture.blob_root $fixture.blobs
    | each {|row| $row | to json --raw }
    | str join "\n"
  )
  assert equal (open --raw $parent | into string) $expected
}

def "test OMP import rejects canonical and alias collisions before any copy" [] {
  let root = (mktemp -d)
  let fixture = (make-fixture ($root | path join "source"))
  let bundle = ($root | path join "bundle")
  let first = $fixture.blobs.0
  let cases = [$first.id ($first.id + $first.suffix)]

  let exported = (with-env (fixture-env ($root | path join "source")) {
    run-cli export $fixture.project $bundle --assistant "omp" --session-ids "parent"
  })
  assert equal $exported.exit_code 0 $exported.stderr

  for name in $cases {
    let target = ($root | path join $name)
    let blobs = ($target | path join "omp/blobs")
    let conflict = ($blobs | path join $name)
    mkdir $blobs
    0x[ff fe fd fc] | save $conflict

    let imported = (with-env (fixture-env $target) {
      run-cli import $bundle --assistant "omp" --apply
    })
    assert not equal $imported.exit_code 0 $name

    assert equal (open --raw $conflict | into binary) 0x[ff fe fd fc] $name
    assert equal (ls $blobs | get name | path basename) [$name] $name
    assert not (($target | path join "omp/sessions") | path exists) $name
    assert not (($target | path join "state") | path exists) $name
  }
}

def "test OMP import rejects corrupted carried blob files before session writes" [] {
  let root = (mktemp -d)

  for kind in ["canonical" "alias"] {
    let base = ($root | path join $kind)
    let source = ($base | path join "source")
    let fixture = (make-fixture $source)
    let bundle = ($base | path join "bundle")
    let target = ($base | path join "target")
    let name = if $kind == "canonical" {
      $fixture.blobs.0.id
    } else {
      $fixture.blobs.0.id + $fixture.blobs.0.suffix
    }

    let exported = (with-env (fixture-env $source) {
      run-cli export $fixture.project $bundle --assistant "omp" --session-ids "parent"
    })
    assert equal $exported.exit_code 0 $exported.stderr

    let entries = (open ($bundle | path join "omp/entries.json"))
    let file = ($entries.files | where name == $name | first)
    0x[ff fe fd fc] | save --force ($bundle | path join "omp" $file.bundle)

    let imported = (with-env (fixture-env $target) {
      run-cli import $bundle --assistant "omp" --apply
    })
    assert not equal $imported.exit_code 0 $kind

    assert not (($target | path join "omp") | path exists) $kind
    assert not (($target | path join "state") | path exists) $kind
  }
}

def "test OMP dependency repair changes only requested complete blob path tokens" [] {
  let blob = (blob-row 0x[00 01 02 ff] ".png")
  let source = "/home/u"
  let target = "/home/v/.omp/agent/blobs"
  let name = ($blob.id + $blob.suffix)
  let original = {
    cwd: "/home/u/src/app"
    unrelated: "/home/u/notes.txt"
    locator: $"blob:sha256:($blob.id)"
    prose: $"Historical file /home/u/($name)."
    descendants: [
      ($source | path join $blob.id "unrelated")
      ($source | path join $name "unrelated")
      (file-uri ($source | path join $name "unrelated"))
    ]
    files: [
      ($source | path join $blob.id)
      ($source | path join $name)
      (file-uri ($source | path join $name))
    ]
  }
  let expected = ($original | update files [
    ($target | path join $blob.id)
    ($target | path join $name)
    (file-uri ($target | path join $name))
  ])
  let request = {
    version: 1
    assistant: "omp"
    path: "/home/u/src/app"
    source_blob_root: $source
    sessions: [
      {
        id: "selected"
        blobs: [
          {
            id: $blob.id
            aliases: [$name]
          }
        ]
      }
    ]
  }
  let original_json = ($original | to json --raw)
  let expected_json = ($expected | to json --raw)
  let known_paths = ($original.files | first 2)
  let encoded = (escape-path-tokens $original_json $known_paths '\u002f')
  let encoded = (escape-path-tokens $encoded [($original.files | last)] '\/')
  let encoded_token = (
    $original.files.0 | to json --raw | str replace --all "/" '\u002f'
  )
  let unicode_hash = (
    $blob.id
    | split chars
    | each {|char| '\u00' + ($char | encode utf-8 | encode hex | str lowercase) }
    | str join
  )
  let encoded = (
    $encoded
    | str replace $encoded_token ($encoded_token | str replace $blob.id $unicode_hash)
  )
  let unchanged = [$original.cwd $original.unrelated]
  let encoded = (escape-path-tokens $encoded $unchanged '\u002f')
  let encoded_expected = (escape-path-tokens $expected_json $unchanged '\u002f')
  let cases = [
    {
      name: "only requested dependency paths"
      request: $request
      content: $original_json
      expected: $expected_json
    }
    {
      name: "zero dependencies"
      request: ($request | update sessions.0.blobs [])
      content: $original_json
      expected: $original_json
    }
    {
      name: "escaped tokens preserve unrelated bytes"
      request: $request
      content: $encoded
      expected: $encoded_expected
    }
  ]

  for case in $cases {
    let repaired = (rewrite-paths $case.content $case.request $target)

    assert equal $repaired $case.expected $case.name
  }
}

def "test OMP supplemental transfer repairs accepted sessions after source retirement" [] {
  let root = (mktemp -d)
  let source = ($root | path join "source")
  let target = ($root | path join "target")
  let fixture = (make-fixture $source)
  let request = ($root | path join "request.json")
  let bundle = ($root | path join "bundle")
  let target_blobs = ($target | path join "omp/blobs")
  let parent = ($target | path join "omp" ($fixture.parent | path relative-to $fixture.root))
  let child = ($parent | path dirname | path join "child.jsonl")
  let display = ($fixture.blob_root | path join ($fixture.blobs.2.id + $fixture.blobs.2.suffix))
  let content = (open --raw $fixture.parent | into string)
  let encoded = (escape-path-tokens $content [$display] '\u002f')
  let original = (escape-path-tokens $encoded [(file-uri $display)] '\/')
  mkdir ($parent | path dirname)
  $original | save $parent
  ^cp $fixture.child $child
  rm $fixture.parent $fixture.child

  let requested = (with-env (fixture-env $target) {
    (
      run-cli dependencies $fixture.project $request
        --assistant "omp"
        --session-ids "parent"
        --source-blob-root $fixture.blob_root
    )
  })
  assert equal $requested.exit_code 0 $requested.stderr

  let data = (open $request)
  assert equal ($data.sessions | get id | sort) ["child" "parent"]
  assert equal (
    $data.sessions | get blobs | flatten | get id | uniq | sort
  ) ($fixture.blobs | first 4 | get id | sort)
  assert equal (open --raw $parent | into string) $original
  assert not ($target_blobs | path exists)

  let exported = (with-env (fixture-env $source) {
    run-cli export $fixture.project $bundle --assistant "omp" --dependencies-from $request
  })
  assert equal $exported.exit_code 0 $exported.stderr

  let entries = (open ($bundle | path join "omp/entries.json"))
  assert equal ($entries.files | get kind | uniq) ["blobs"]
  assert equal ($entries.files | get name | sort) (blob-names ($fixture.blobs | first 4))

  let preview = (with-env (fixture-env $target) {
    run-cli import $bundle --assistant "omp" --repair-dependencies
  })
  assert equal $preview.exit_code 0 $preview.stderr
  assert equal (open --raw $parent | into string) $original
  assert not ($target_blobs | path exists)

  let changed = (
    $original + "\n" + ({
      type: "message"
      message: {
        content: [
          {
            type: "image"
            data: $"blob:sha256:($fixture.blobs.4.id)"
          }
        ]
      }
    } | to json --raw)
  )
  $changed | save --force $parent

  let mismatched = (with-env (fixture-env $target) {
    run-cli import $bundle --assistant "omp" --repair-dependencies --apply
  })
  assert not equal $mismatched.exit_code 0

  assert equal (open --raw $parent | into string) $changed
  assert not ($target_blobs | path exists)
  $original | save --force $parent

  let imported = (with-env (fixture-env $target) {
    run-cli import $bundle --assistant "omp" --repair-dependencies --apply
  })
  assert equal $imported.exit_code 0 $imported.stderr

  assert-blobs $target_blobs ($fixture.blobs | first 4)
  let expected = (
    parent-rows $fixture.project $target_blobs $fixture.blob_root $fixture.blobs
    | each {|row| $row | to json --raw }
    | str join "\n"
  )
  assert equal (open --raw $parent | into string) $expected
  let repeated = (with-env (fixture-env $target) {
    run-cli import $bundle --assistant "omp" --repair-dependencies --apply
  })
  assert equal $repeated.exit_code 0 $repeated.stderr
  assert str contains $repeated.stdout "No changes."

  let retired = (with-env (fixture-env $source) {
    run-cli retire $fixture.project --assistant "omp" --dependencies-from $request --apply
  })
  assert equal $retired.exit_code 0 $retired.stderr

  let retained = [$fixture.blobs.1 $fixture.blobs.4]
  assert equal (
    ls $fixture.blob_root | get name | path basename | sort
  ) (blob-names $retained)
  assert-blobs $fixture.blob_root $retained
  assert ($fixture.peer | path exists)
  assert-blobs $target_blobs ($fixture.blobs | first 4)
}

def "test OMP selected retirement preserves shared historical dependencies" [] {
  let root = (mktemp -d)
  let fixture = (make-fixture $root)
  let original = (open --raw $fixture.peer | into string)

  let run = (with-env (fixture-env $root) {
    run-cli retire $fixture.project --assistant "omp" --session-ids "parent" --apply
  })
  assert equal $run.exit_code 0 $run.stderr

  assert not ($fixture.parent | path exists)
  assert not ($fixture.child | path exists)
  assert equal (open --raw $fixture.peer | into string) $original
  let retained = [$fixture.blobs.1 $fixture.blobs.4]
  assert equal (
    ls $fixture.blob_root | get name | path basename | sort
  ) (blob-names $retained)
  assert-blobs $fixture.blob_root $retained
}

def "test OMP retirement rejects unreadable retained references before deleting sessions" [] {
  let root = (mktemp -d)
  let fixture = (make-fixture $root)
  let original = (open --raw $fixture.parent | into string)
  "\n{invalid" | save --append $fixture.peer

  let run = (with-env (fixture-env $root) {
    run-cli retire $fixture.project --assistant "omp" --session-ids "parent" --apply
  })
  assert not equal $run.exit_code 0

  assert equal (open --raw $fixture.parent | into string) $original
  assert ($fixture.child | path exists)
  assert-blobs $fixture.blob_root $fixture.blobs
  assert not (($root | path join "state") | path exists)
}

def "test OMP dependency requests reject unsupported schemas and escaping names" [] {
  let root = (mktemp -d)
  let fixture = (make-fixture $root)
  let request = ($root | path join "request.json")

  let requested = (with-env (fixture-env $root) {
    (
      run-cli dependencies $fixture.project $request
        --assistant "omp"
        --session-ids "parent"
        --source-blob-root $fixture.blob_root
    )
  })
  assert equal $requested.exit_code 0 $requested.stderr

  let original = (open $request)
  let cases = [
    {
      name: "unknown version"
      data: ($original | update version 2)
    }
    {
      name: "unknown field"
      data: ($original | upsert extra true)
    }
    {
      name: "escaping alias"
      data: ($original | update sessions.0.blobs.0.aliases ["../outside.png"])
    }
    {
      name: "malformed blob id"
      data: ($original | update sessions.0.blobs.0.id "../outside")
    }
    {
      name: "relative source root"
      data: ($original | update source_blob_root "blobs")
    }
    {
      name: "different project"
      data: ($original | update path "/home/u/src/other")
    }
  ]

  for case in $cases {
    let bad = ($root | path join ($case.name + ".json"))
    let bundle = ($root | path join ($case.name + "-bundle"))
    $case.data | to json | save $bad

    let run = (with-env (fixture-env $root) {
      run-cli export $fixture.project $bundle --assistant "omp" --dependencies-from $bad
    })
    assert not equal $run.exit_code 0 $case.name

    assert not ($bundle | path exists) $case.name
    assert-blobs $fixture.blob_root $fixture.blobs
  }
}

def "test OMP export rejects invalid locators and incomplete dependency files" [] {
  let root = (mktemp -d)
  let cases = [
    "unknown locator"
    "malformed exact locator"
    "missing canonical"
    "missing referenced alias"
    "corrupt alias"
  ]

  for case in $cases {
    let base = ($root | path join $case)
    let fixture = (make-fixture $base)
    let bundle = ($base | path join "bundle")
    let blob = $fixture.blobs.2
    let canonical = ($fixture.blob_root | path join $blob.id)
    let alias = ($fixture.blob_root | path join ($blob.id + $blob.suffix))
    match $case {
      "unknown locator" => {
        let content = (open --raw $fixture.parent | into string)
        $content
        | str replace "blob:sha256:" "blob:sha512:"
        | save --force $fixture.parent
      }
      "malformed exact locator" => {
        let content = (open --raw $fixture.parent | into string)
        $content
        | str replace $"blob:sha256:($fixture.blobs.0.id)" $"blob:sha256:($fixture.blobs.0.id)."
        | save --force $fixture.parent
      }
      "missing canonical" => {
        rm $canonical
      }
      "missing referenced alias" => {
        rm $alias
      }
      "corrupt alias" => {
        0x[ff fe fd fc] | save --force $alias
      }
    }

    let run = (with-env (fixture-env $base) {
      run-cli export $fixture.project $bundle --assistant "omp" --session-ids "parent"
    })
    assert not equal $run.exit_code 0 $case

    assert not ($bundle | path exists) $case
  }
}
