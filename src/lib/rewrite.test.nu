#!/usr/bin/env nu

# ==================================================================================================
# Agent Project Move: Rewrites Tests
# ==================================================================================================

use std/assert

use ./rewrite.nu [file-uri offsets-kept rewrite-text]

def "test path rewrites cover JSON string tokens" [] {
  let cases = [
    {
      name: "an exact value"
      content: '{"p":"/work/app"}'
      expected: '{"p":"/work/new"}'
    }
    {
      name: "a child value"
      content: '{"p":"/work/app/sub"}'
      expected: '{"p":"/work/new/sub"}'
    }
    {
      name: "a sibling"
      content: '{"p":"/work/apple"}'
      expected: '{"p":"/work/apple"}'
    }
    {
      name: "a path inside free text"
      content: '{"p":"see /work/app/x"}'
      expected: '{"p":"see /work/app/x"}'
    }
    {
      name: "a path without a leading quote"
      content: '{"p":"x/work/app"}'
      expected: '{"p":"x/work/app"}'
    }
    {
      name: "an escaped quoted path"
      content: '{"p":"\"/work/app\""}'
      expected: '{"p":"\"/work/app\""}'
    }
    {
      name: "a key"
      content: '{"/work/app":1}'
      expected: '{"/work/new":1}'
    }
    {
      name: "a nested value"
      content: '{"a":[{"b":"/work/app/x"}]}'
      expected: '{"a":[{"b":"/work/new/x"}]}'
    }
    {
      name: "a file URI"
      content: '{"p":"file:///work/app/sub"}'
      expected: '{"p":"file:///work/new/sub"}'
    }
    {
      name: "a file URI sibling"
      content: '{"p":"file:///work/application"}'
      expected: '{"p":"file:///work/application"}'
    }
    {
      name: "adjacent plain and URI values"
      content: '["/work/app","file:///work/app"]'
      expected: '["/work/new","file:///work/new"]'
    }
  ]

  for case in $cases {
    assert equal (rewrite-text $case.content "/work/app" "/work/new") $case.expected $case.name
  }
}

def "test file URIs follow the url crate spelling" [] {
  let cases = [
    {
      name: "a hyphenated old path"
      old: "/home/u/src/old-app"
      new: "/home/u/work/new-app"
      value: "file:///home/u/src/old-app/src"
      expected: "file:///home/u/work/new-app/src"
    }
    {
      name: "an underscored old path"
      old: "/home/u/src/my_app"
      new: "/home/u/work/my_app"
      value: "file:///home/u/src/my_app"
      expected: "file:///home/u/work/my_app"
    }
    {
      name: "a space and non-ASCII path"
      old: "/work/a b/café"
      new: "/work/c d/cafe"
      value: "file:///work/a%20b/caf%C3%A9/sub"
      expected: "file:///work/c%20d/cafe/sub"
    }
    {
      name: "a literal percent"
      old: "/work/app"
      new: "/work/new"
      value: "file:///work/app/100%25"
      expected: "file:///work/new/100%25"
    }
    {
      name: "a backslash in the path"
      old: '/work/a\b'
      new: '/work/c\d'
      value: "file:///work/a%5Cb/x"
      expected: "file:///work/c%5Cd/x"
    }
    {
      name: "a sub-delimiter in the path"
      old: "/work/a+b"
      new: "/work/c@d"
      value: "file:///work/a+b/x"
      expected: "file:///work/c@d/x"
    }
  ]

  for case in $cases {
    let content = '{"p":"' + $case.value + '"}'
    let expected = '{"p":"' + $case.expected + '"}'
    assert equal (rewrite-text $content $case.old $case.new) $expected $case.name
  }
}

def "test offsets survive only same-length moves" [] {
  let cases = [
    {name: "a same-length move", old: "/work/src", new: "/work/new", kept: true}
    {name: "a non-ASCII path", old: "/work/café", new: "/work/cafe", kept: false}
    {name: "a space the URI spelling escapes", old: "/work/a b", new: "/work/a-b", kept: false}
    {name: "a space on both sides", old: "/work/a b", new: "/work/c d", kept: true}
    {name: "a quote the JSON escapes", old: '/work/a"b', new: "/work/a b", kept: false}
    {name: "a backslash the JSON escapes", old: '/work/a\b', new: "/work/a b", kept: false}
    {name: "a tab the JSON escapes", old: "/work/a\tb", new: "/work/a b", kept: false}
  ]

  for case in $cases {
    assert equal (offsets-kept $case.old $case.new) $case.kept $case.name
  }
}
