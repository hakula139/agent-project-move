# ==================================================================================================
# Agent Project Move: OMP Blobs
# ==================================================================================================
# Selected attachments in OMP's content-addressed blob store.
# ==================================================================================================

use ../lib/actions.nu [same-content]
use ../lib/paths.nu [files-under valid-path]
use ../lib/rewrite.nu [file-uri json-escape]

const HASH = '^[a-f0-9]{64}$'
const NAME = '^[a-f0-9]{64}(?:\.[a-z0-9][a-z0-9._-]{0,31})?$'

def pool-files [root: string]: nothing -> list<record> {
  files-under $root
  | where {|file| ($file | path dirname) == $root and ($file | path basename) =~ $NAME }
  | each {|file|
    let name = ($file | path basename)
    {
      id: ($name | str substring 0..<64)
      name: $name
      path: $file
    }
  }
}

# Read references in OMP's native JSONL spelling, including existing alias names in prose.
export def references [files: list<string>, root: string]: nothing -> list<string> {
  let aliases = (pool-files $root | get name | where {|name| $name !~ $HASH })
  let roots = (
    [$root (file-uri $root)]
    | each {|path| json-escape $path | str escape-regex }
    | str join "|"
  )
  let absolute = ('(?:' + $roots + ')/(?<id>[a-f0-9]{64})\b')
  mut ids = []
  for file in $files {
    let text = (open --raw $file | into string)
    let native = ($text | parse --regex '\bblob:sha256:(?<id>[a-f0-9]{64})\b' | get id)
    let paths = ($text | parse --regex $absolute | get id)
    let names = (
      $text
      | parse --regex '(?<![A-Za-z0-9_])(?<name>[a-f0-9]{64}\.[a-z0-9][a-z0-9._-]{0,31})(?![A-Za-z0-9_.-])'
      | get name
      | each {|name|
        if $name in $aliases { $name } else { $name | str trim --right --char "." }
      }
      | where {|name| $name in $aliases }
      | each {|name| $name | str substring 0..<64 }
    )
    $ids = ($ids ++ $native ++ $paths ++ $names)
  }
  $ids | uniq | sort
}

def content-hash [file: string]: nothing -> string {
  ^sha256sum -- $file | split row " " | first
}

# Resolve selected IDs to verified canonical files and every safe alias in the local pool.
export def resolve-files [ids: list<string>, root: string]: nothing -> list<record> {
  for id in $ids {
    if $id !~ $HASH {
      error make --unspanned {msg: "Invalid OMP blob ID"}
    }
  }
  let inventory = (pool-files $root)
  mut files = []
  for id in ($ids | uniq | sort) {
    let canonical = ($root | path join $id)
    if not ($inventory | any {|file| $file.name == $id }) {
      error make --unspanned {msg: $"Missing canonical OMP blob ($id)"}
    }
    if (content-hash $canonical) != $id {
      error make --unspanned {msg: $"OMP blob content does not match its ID ($id)"}
    }
    for file in ($inventory | where id == $id | sort-by name) {
      if not (same-content $canonical $file.path) {
        error make --unspanned {msg: $"OMP blob alias differs from its canonical file ($file.name)"}
      }
      $files = ($files | append {
        kind: "blobs"
        project: ""
        name: $file.name
        source: $file.path
      })
    }
  }
  $files
}

# Validate external blob descriptors and bytes before any import action is applied.
export def verify-files [files: list<record>]: nothing -> nothing {
  let blobs = ($files | where kind == "blobs")
  let names = ($blobs | get name)
  if ($names | uniq | length) != ($names | length) {
    error make --unspanned {msg: "Duplicate OMP blob filename in bundle"}
  }
  for file in $blobs {
    if $file.name !~ $NAME or $file.project != "" {
      error make --unspanned {msg: "Invalid OMP blob descriptor"}
    }
    let origin = ($file | get -o origin_path)
    if not (valid-path $origin) {
      error make --unspanned {msg: "Invalid OMP blob origin path"}
    }
    if ($origin | path basename) != $file.name or ($origin | path dirname) == "/" {
      error make --unspanned {msg: "Invalid OMP blob origin path"}
    }
    let id = ($file.name | str substring 0..<64)
    if $id not-in $names {
      error make --unspanned {msg: $"Missing canonical OMP blob ($id) in bundle"}
    }
    if (content-hash $file.bundle) != $id {
      error make --unspanned {msg: $"OMP blob content does not match its ID ($id)"}
    }
  }
}
