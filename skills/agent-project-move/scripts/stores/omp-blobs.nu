# ==================================================================================================
# Agent Project Move: OMP Blobs
# ==================================================================================================
# Selected attachments in OMP's content-addressed blob store.
# ==================================================================================================

use ../lib/actions.nu [read-utf8]
use ../lib/paths.nu [files-under valid-path]

const NAME = '^[a-f0-9]{64}(?:\.[a-z0-9][a-z0-9._-]{0,31})?$'
# Match complete runs without lookaround, which can exhaust the backtracking limit on long lines.
const REFERENCE = '(?<locator>\bblob:sha256:)?(?<id>[a-f0-9]{64,})'

def blob-id [name: string]: nothing -> string {
  $name | str substring 0..<64
}

def check-hash [file: string, id: string]: nothing -> nothing {
  if (open --raw $file | hash sha256) != $id {
    error make --unspanned {msg: $"OMP blob content does not match its ID ($id): ($file)"}
  }
}

# Match known pool IDs anywhere in the journal. Explicit locators also detect missing blobs.
export def export-files [journals: list<string>, root: string]: nothing -> list<record> {
  let inventory = (
    files-under $root
    | where {|file| ($file | path dirname) == $root }
    | path basename
    | where {|name| $name =~ $NAME }
    | group-by {|name| blob-id $name }
  )
  let ids = (
    $journals
    | each {|file|
      read-utf8 $file
      | parse --regex $REFERENCE
      | where {|ref| ($ref.id | str length) == 64 }
      | where {|ref| $ref.locator != null or ($inventory | get -o $ref.id) != null }
      | get id
    }
    | flatten
    | uniq
    | sort
  )

  $ids
  | each {|id|
    let names = ($inventory | get -o $id | default [])
    if $id not-in $names {
      error make --unspanned {msg: $"Missing canonical OMP blob ($id)"}
    }
    $names
    | sort
    | each {|name|
      let source = ($root | path join $name)
      check-hash $source $id
      {
        kind: "blobs"
        project: ""
        name: $name
        source: $source
      }
    }
  }
  | collect
  | flatten
}

# Validate external blob descriptors and bytes before any import action is applied.
export def import-roots [bundle: record]: nothing -> list<string> {
  let blobs = ($bundle.files | where kind == "blobs")
  if ($blobs | is-empty) { return [] }

  let names = ($blobs | get name)
  if ($names | uniq | length) != ($names | length) {
    error make --unspanned {msg: "Duplicate OMP blob filename in bundle"}
  }
  for file in $blobs {
    if $file.name !~ $NAME or $file.project != "" {
      error make --unspanned {msg: "Invalid OMP blob descriptor"}
    }
    let id = (blob-id $file.name)
    if $id not-in $names {
      error make --unspanned {msg: $"Missing canonical OMP blob ($id) in bundle"}
    }
    check-hash $file.bundle $id
  }

  let roots = if "blob_root" in $bundle {
    [$bundle.blob_root]
  } else {
    # Older bundles recorded the source path on each blob entry.
    $blobs
    | each {|file|
      let origin = ($file | get -o origin_path)
      if not (valid-path $origin) or ($origin | path basename) != $file.name {
        error make --unspanned {msg: "Invalid OMP blob origin path"}
      }
      $origin | path dirname
    }
    | collect
    | uniq
  }

  if not ($roots | all {|root| (valid-path $root) and $root != "/" }) {
    error make --unspanned {msg: "Invalid OMP blob root"}
  }
  $roots
}
