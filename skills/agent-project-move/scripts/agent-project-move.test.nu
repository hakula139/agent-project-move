#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: CLI and Bundle Tests
# ==================================================================================================

use std/assert

use ./common.testlib.nu [fixture-env run-cli write-jsonl]
use ./stores/omp.nu [session-encode-here]

def "test exports require a new or empty bundle directory" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let session = ($root | path join "omp/sessions" (session-encode-here $project) "one.jsonl")
  write-jsonl $session [{type: "session", id: "one", cwd: $project}]
  let cases = [
    {
      state: "new"
      entry: null
    }
    {
      state: "empty"
      entry: null
    }
    {
      state: "visible"
      entry: "claude/entries.json"
    }
    {
      state: "hidden"
      entry: ".keep"
    }
  ]

  with-env (fixture-env $root) {
    for case in $cases {
      let directory = ($root | path join $case.state)
      if $case.state != "new" { mkdir $directory }
      if $case.entry != null {
        let entry = ($directory | path join $case.entry)
        mkdir ($entry | path dirname)
        "existing bundle bytes" | save $entry
      }

      let exported = (run-cli export $project $directory --assistant "omp")
      if $case.entry == null {
        assert equal $exported.exit_code 0 $exported.stderr

        let entries = (open ($directory | path join "omp/entries.json"))
        assert equal ($entries.files | get name) ["one.jsonl"] $case.state
      } else {
        assert not equal $exported.exit_code 0 $case.state

        assert equal (
          open --raw ($directory | path join $case.entry)
        ) "existing bundle bytes" $case.state
        assert equal (
          ls --all $directory | get name | path basename
        ) [($case.entry | path split | first)] $case.state
      }
    }
  }
}

def "test legacy bundle file origins cannot direct imports" [] {
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

  assert equal ($entries.files | get name | sort) ["recording.jsonl" "recording/notes.md"]
  assert ($entries.files | all {|file| "origin_path" not-in ($file | columns) })

  for mode in ["normal" "hostile" "legacy"] {
    let target = ($root | path join $mode)
    let destination = ($target | path join "omp/sessions" (session-encode-here $project))
    let files = (
      $entries.files
      | each {|file|
        match $mode {
          "hostile" => ($file | insert origin_path $protected)
          "legacy" => ($file | insert origin_path ($session_dir | path join $file.name))
          _ => $file
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

  mv ($directory | path join "omp") ($directory | path join "claude")
  let target = ($root | path join "mismatched-assistant")

  let rejected = (with-env (fixture-env $target) {
    run-cli import $directory --assistant "claude" --apply --no-backup
  })
  assert not equal $rejected.exit_code 0

  assert not ($target | path exists)
  assert equal (open --raw $protected) "protected content"
}

def "test selective CLI rejects ambiguous session selections" [] {
  let root = (mktemp -d)
  let project = "/home/u/src/app"
  let bundle = ($root | path join "bundle")
  let target = ($root | path join "moved")
  mkdir $target
  let both = ["--exact" "--session-ids" "one"]
  let exclusive = "--exact and --session-ids are mutually exclusive"
  let empty = "--session-ids requires at least one session ID"
  let cases = [
    {
      args: ["retire" $project]
      error: "retire requires --exact or --session-ids"
    }
    {
      args: ["retire" $project ...$both]
      error: $exclusive
    }
    {
      args: ["export" $project $bundle ...$both]
      error: $exclusive
    }
    {
      args: ["move" $project $target ...$both]
      error: $exclusive
    }
    {
      args: ["export" $project $bundle "--session-ids" ""]
      error: $empty
    }
    {
      args: ["export" $project $bundle "--exact" "--session-ids" ""]
      error: $exclusive
    }
    {
      args: ["retire" $project "--session-ids" ""]
      error: $empty
    }
  ]

  with-env (fixture-env $root) {
    for case in $cases {
      let run = (run-cli ...$case.args)
      let label = ($case.args | str join " ")

      assert not equal $run.exit_code 0 $label
      assert str contains $run.stderr $case.error $label
    }
  }
}
