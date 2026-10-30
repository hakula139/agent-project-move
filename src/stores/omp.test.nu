#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: OMP Tests
# ==================================================================================================

use std/assert

use ./omp.nu *

def "test OMP encodes session directories by location" [] {
  let cases = [
    {name: "a project under home", path: "/home/tester/src/app", encoded: "-src-app"}
    {name: "home itself", path: "/home/tester", encoded: "-"}
    {name: "a child of the temp root", path: "/tmp/omp-test", encoded: "-tmp-omp-test"}
    {name: "the temp root", path: "/tmp", encoded: "-tmp-"}
    {name: "a path outside both roots", path: "/opt/x", encoded: "--opt-x--"}
  ]

  with-env {HOME: "/home/tester", TMPDIR: "/tmp"} {
    for case in $cases {
      assert equal (session-encode-here $case.path) $case.encoded $case.name
    }
  }
}

def "test OMP encodes memory directories from the absolute path" [] {
  let cases = [
    {
      name: "a project under home"
      path: "/home/tester/src/app"
      encoded: "--home-tester-src-app--"
    }
    {
      name: "a path under the temp root"
      path: "/tmp/omp-test"
      encoded: "--tmp-omp-test--"
    }
    {
      name: "a path outside both roots"
      path: "/opt/x"
      encoded: "--opt-x--"
    }
  ]

  for case in $cases {
    assert equal (memory-encode $case.path) $case.encoded $case.name
  }
}
