#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: OMP Blob Transfer Tests
# ==================================================================================================

use std/assert

use ../lib/rewrite.nu [file-uri]
use ./omp-blobs.nu [references]
use ./omp.nu [session-encode-here]

const SCRIPT = path self "../agent-project-move.nu"

def run-cli [root: string, args: list<string>]: nothing -> record {
  with-env {
    PI_CODING_AGENT_DIR: ($root | path join "source agent")
    XDG_STATE_HOME: ($root | path join "state")
    TZ: "UTC"
  } {
    ^$nu.current-exe $SCRIPT ...$args | complete
  }
}

def write-jsonl [file: string, rows: list<record>] {
  mkdir ($file | path dirname)
  $rows
  | each {|row| $row | to json --raw }
  | str join "\n"
  | save $file
}

def parent-rows [project: string, root: string, prose_root: string, blobs: list<record>] {
  let display = ($root | path join ($blobs.0.id + $blobs.0.suffix))
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
            text: $"Prior image ($blobs.2.id)($blobs.2.suffix). Historical root ($prose_root). Unrelated digest ($blobs.3.id)."
          }
        ]
        details: {
          files: [$display (file-uri $display) (file-uri ($root | path join $blobs.4.id))]
        }
      }
    }
    {
      type: "compaction"
      preserveData: {snapcompact: {frames: [{data: $"blob:sha256:($blobs.1.id)"}]}}
    }
  ]
}

def make-fixture [root: string, project: string = "/home/u/src/app"]: nothing -> record {
  let pool = ($root | path join "source agent/blobs")
  let directory = ($root | path join "source agent/sessions" (session-encode-here $project))
  let blobs = (
    [0x[00 01 02 ff] 0x[03 04 05 fe] 0x[06 07 08 fd] 0x[09 0a 0b fc] 0x[0c 0d 0e fb]]
    | enumerate
    | each {|row|
      {
        id: ($row.item | hash sha256)
        data: $row.item
        suffix: (if $row.index == 1 { ".webp" } else { ".png" })
      }
    }
  )
  mkdir $pool

  for blob in $blobs {
    $blob.data | save ($pool | path join $blob.id)
    $blob.data | save ($pool | path join ($blob.id + $blob.suffix))
  }

  let parent = ($directory | path join "parent.jsonl")
  let child = ($directory | path join "child.jsonl")
  let peer = ($directory | path join "peer.jsonl")
  write-jsonl $parent (parent-rows $project $pool $pool $blobs)
  write-jsonl $child [
    {
      type: "session"
      id: "child"
      cwd: "/home/u/work/child"
      parentSession: "parent"
    }
    {
      type: "message"
      data: $"blob:sha256:($blobs.1.id)"
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
      data: $"blob:sha256:($blobs.3.id)"
    }
  ]
  {
    project: $project
    pool: $pool
    parent: $parent
    child: $child
    peer: $peer
    blobs: $blobs
    selected: [$blobs.0 $blobs.1 $blobs.2 $blobs.4]
  }
}

def blob-names [blobs: list<record>]: nothing -> list<string> {
  $blobs
  | each {|blob| [$blob.id ($blob.id + $blob.suffix)] }
  | flatten
  | sort
}

def assert-blobs [pool: string, blobs: list<record>] {
  assert equal (ls $pool | get name | path basename | sort) (blob-names $blobs)
  for blob in $blobs {
    for name in [$blob.id ($blob.id + $blob.suffix)] {
      assert equal (open --raw ($pool | path join $name) | into binary) $blob.data $name
    }
  }
}

def "test OMP export carries only selected native and historical blob dependencies" [] {
  let root = (mktemp -d)
  let fixture = (make-fixture $root)
  let bundle = ($root | path join "bundle")

  let run = (run-cli $root [
    "export" $fixture.project $bundle "--assistant" "omp" "--session-ids" "parent"
  ])
  assert equal $run.exit_code 0 $run.stderr

  let entries = (open ($bundle | path join "omp/entries.json"))
  assert equal (
    $entries.files
    | where kind == "blobs"
    | get name
    | sort
  ) (blob-names $fixture.selected)
  assert equal (
    $entries.files
    | get -o session
    | compact
    | sort
  ) ["child" "parent"]
  for file in ($entries.files | where kind == "blobs") {
    assert equal (
      open --raw ($bundle | path join "omp" $file.bundle) | into binary
    ) (open --raw ($fixture.pool | path join $file.name) | into binary)
  }

  for component in ['quote"agent' 'back\slash-agent'] {
    let pool = ($root | path join $component "blobs")
    let journal = ($root | path join $"($component).jsonl")
    let blob = $fixture.blobs.0
    mkdir $pool
    $blob.data | save ($pool | path join $blob.id)
    write-jsonl $journal [
      {
        type: "message"
        path: ($pool | path join $blob.id)
      }
    ]

    assert equal (references [$journal] $pool) [$blob.id] $component
  }
}

def "test OMP import maps native blob paths and preserves collision and repeat behavior" [] {
  let root = (mktemp -d)
  let source = ($root | path join "source")
  let target = ($root | path join "target")
  let fixture = (make-fixture $source)
  let bundle = ($root | path join "bundle")
  let pool = ($target | path join "source agent/blobs")
  let exported = (run-cli $source [
    "export" $fixture.project $bundle "--assistant" "omp" "--session-ids" "parent"
  ])
  assert equal $exported.exit_code 0 $exported.stderr

  let imported = (run-cli $target ["import" $bundle "--assistant" "omp" "--apply"])
  assert equal $imported.exit_code 0 $imported.stderr

  assert-blobs $pool $fixture.selected
  let parent = (glob ($target | path join "source agent/sessions/*/parent.jsonl") | first)
  let expected = (
    parent-rows $fixture.project $pool $fixture.pool $fixture.blobs
    | each {|row| $row | to json --raw }
    | str join "\n"
  )
  assert equal (open --raw $parent | into string) $expected
  let repeated = (run-cli $target ["import" $bundle "--assistant" "omp" "--apply"])
  assert equal $repeated.exit_code 0 $repeated.stderr
  assert str contains $repeated.stdout "No changes."

  let changed = ($expected | str replace "Prior image" "Local note")
  $changed | save --force $parent
  let conflict = (run-cli $target ["import" $bundle "--assistant" "omp" "--apply"])
  assert not equal $conflict.exit_code 0
  assert equal (open --raw $parent | into string) $changed

  for name in [$fixture.blobs.0.id ($fixture.blobs.0.id + $fixture.blobs.0.suffix)] {
    let other = ($root | path join $name)
    let other_pool = ($other | path join "source agent/blobs")
    mkdir $other_pool
    0x[ff fe fd fc] | save ($other_pool | path join $name)
    let collision = (run-cli $other ["import" $bundle "--assistant" "omp" "--apply"])
    assert not equal $collision.exit_code 0 $name
    assert equal (ls $other_pool | get name | path basename) [$name]
    assert equal (open --raw ($other_pool | path join $name) | into binary) 0x[ff fe fd fc]
    assert not (($other | path join "source agent/sessions") | path exists)
  }

  let enclosing = ($root | path join "enclosing")
  let nested = (make-fixture $enclosing $enclosing)
  let mapped_bundle = ($root | path join "mapped-bundle")
  let mapped_target = ($root | path join "mapped-target")
  let mapped_project = ($root | path join "work/app")
  let mapped_pool = ($mapped_target | path join "source agent/blobs")
  mkdir $mapped_project
  let exported = (run-cli $enclosing [
    "export" $enclosing $mapped_bundle "--assistant" "omp" "--session-ids" "parent"
  ])
  assert equal $exported.exit_code 0 $exported.stderr

  let imported = (run-cli $mapped_target [
    "import" $mapped_bundle "--assistant" "omp" "--target" $mapped_project "--apply"
  ])
  assert equal $imported.exit_code 0 $imported.stderr

  let parent = (glob ($mapped_target | path join "source agent/sessions/*/parent.jsonl") | first)
  let expected = (
    parent-rows ($mapped_project | path expand) $mapped_pool $nested.pool $nested.blobs
    | each {|row| $row | to json --raw }
    | str join "\n"
  )
  assert equal (open --raw $parent | into string) $expected
  assert-blobs $mapped_pool $nested.selected
}

def "test OMP transfer rejects missing or corrupt blob bytes before writing" [] {
  let root = (mktemp -d)
  let cases = [
    [stage fault part];
    ["source" "missing" "canonical"]
    ["source" "corrupt" "canonical"]
    ["source" "corrupt" "alias"]
    ["bundle" "missing" "canonical"]
    ["bundle" "missing" "alias"]
    ["bundle" "corrupt" "canonical"]
    ["bundle" "corrupt" "alias"]
    ["bundle" "relative-origin" "canonical"]
    ["bundle" "wrong-name-origin" "canonical"]
    ["bundle" "root-origin" "canonical"]
  ]
  for case in $cases {
    let label = ($case | values | str join "-")
    let base = ($root | path join $label)
    let source = ($base | path join "source")
    let target = ($base | path join "target")
    let fixture = (make-fixture $source)
    let bundle = ($base | path join "bundle")
    let name = if $case.part == "canonical" {
      $fixture.blobs.0.id
    } else {
      $fixture.blobs.0.id + $fixture.blobs.0.suffix
    }
    if $case.stage == "source" {
      let file = ($fixture.pool | path join $name)
      if $case.fault == "missing" {
        rm $file
      } else {
        0x[ff fe fd fc] | save --force $file
      }
    }

    let exported = (run-cli $source [
      "export" $fixture.project $bundle "--assistant" "omp" "--session-ids" "parent"
    ])
    if $case.stage == "source" {
      assert not equal $exported.exit_code 0 $label
      assert not ($bundle | path exists) $label
      continue
    }
    assert equal $exported.exit_code 0 $exported.stderr

    let manifest = ($bundle | path join "omp/entries.json")
    let entries = (open $manifest)
    let file = ($entries.files | where name == $name | first)
    let incoming = ($bundle | path join "omp" $file.bundle)
    if $case.fault == "missing" {
      rm $incoming
    } else if $case.fault == "corrupt" {
      0x[ff fe fd fc] | save --force $incoming
    } else {
      let origin = match $case.fault {
        "relative-origin" => ($"relative/($name)")
        "wrong-name-origin" => ($fixture.pool | path join "different-name")
        "root-origin" => ($"/($name)")
      }
      $entries
      | update files {
        $in | each {|entry|
          if $entry.name == $name {
            $entry | upsert origin_path $origin
          } else {
            $entry
          }
        }
      }
      | to json
      | save --force $manifest
    }
    let imported = (run-cli $target ["import" $bundle "--assistant" "omp" "--apply"])
    assert not equal $imported.exit_code 0 $label
    assert not (($target | path join "source agent") | path exists) $label
    assert not (($target | path join "state") | path exists) $label
  }
}

def "test OMP blob export supplements accepted sessions after source files are gone" [] {
  let root = (mktemp -d)
  let source = ($root | path join "source")
  let target = ($root | path join "target")
  let fixture = (make-fixture $source)
  let ids = ($root | path join "ids.txt")
  let bundle = ($root | path join "bundle")
  let pool = ($target | path join "source agent/blobs")
  let directory = ($target | path join "source agent/sessions/accepted")
  let parent = ($directory | path join "parent.jsonl")
  let original = (open --raw $fixture.parent | into string)
  mkdir $directory
  ^cp $fixture.parent $parent
  ^cp $fixture.child ($directory | path join "child.jsonl")
  rm --recursive ($source | path join "source agent/sessions")
  $fixture.selected
  | get id
  | str join "\n"
  | save $ids

  let exported = (run-cli $source ["export-blobs" $ids $bundle])
  assert equal $exported.exit_code 0 $exported.stderr
  let imported = (run-cli $target ["import" $bundle "--assistant" "omp" "--apply"])
  assert equal $imported.exit_code 0 $imported.stderr

  assert-blobs $pool $fixture.selected
  assert equal (open --raw $parent | into string) $original
  let args = ["move" $fixture.pool $pool "--assistant" "omp"]
  let preview = (run-cli $target $args)
  assert equal $preview.exit_code 0 $preview.stderr
  assert equal (open --raw $parent | into string) $original

  let moved = (run-cli $target ($args | append "--apply"))
  assert equal $moved.exit_code 0 $moved.stderr
  let expected = (
    parent-rows $fixture.project ($pool | path expand) $fixture.pool $fixture.blobs
    | each {|row| $row | to json --raw }
    | str join "\n"
  )
  assert equal (open --raw $parent | into string) $expected
  let repeated = (run-cli $target ($args | append "--apply"))
  assert equal $repeated.exit_code 0 $repeated.stderr
  assert str contains $repeated.stdout "No changes."
  let again = (run-cli $target ["import" $bundle "--assistant" "omp" "--apply"])
  assert equal $again.exit_code 0 $again.stderr
  assert str contains $again.stdout "No changes."
}

def "test OMP blob ID files trim and deduplicate IDs and reject invalid lines" [] {
  let root = (mktemp -d)
  let fixture = (make-fixture $root)
  let ids = ($root | path join "ids.txt")
  let bundle = ($root | path join "bundle")
  let id = $fixture.blobs.0.id
  $"\n ($id) \n($id)\n" | save $ids

  let run = (run-cli $root ["export-blobs" $ids $bundle])
  assert equal $run.exit_code 0 $run.stderr
  let entries = (open ($bundle | path join "omp/entries.json"))
  assert equal ($entries.files | get name | sort) (blob-names [$fixture.blobs.0])

  for invalid in [($id | str uppercase) "../outside" $"blob:sha256:($id)"] {
    let target = ($root | path join "invalid-bundle")
    $"($id)\n($invalid)\n" | save --force $ids
    let failed = (run-cli $root ["export-blobs" $ids $target])
    assert not equal $failed.exit_code 0 $invalid
    assert not ($target | path exists)
    assert-blobs $fixture.pool $fixture.blobs
  }
}

def "test OMP session retirement preserves the global blob pool" [] {
  let root = (mktemp -d)
  let fixture = (make-fixture $root)
  let peer = (open --raw $fixture.peer | into string)

  let retired = (run-cli $root [
    "retire" $fixture.project "--assistant" "omp" "--session-ids" "parent" "--apply"
  ])
  assert equal $retired.exit_code 0 $retired.stderr

  assert not ($fixture.parent | path exists)
  assert not ($fixture.child | path exists)
  assert equal (open --raw $fixture.peer | into string) $peer
  assert-blobs $fixture.pool $fixture.blobs
}
