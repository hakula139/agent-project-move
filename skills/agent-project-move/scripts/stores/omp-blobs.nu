# ==================================================================================================
# Agent Project Move: OMP Blobs
# ==================================================================================================
# Selected session dependencies in OMP's content-addressed blob store.
# ==================================================================================================

use ../lib/actions.nu [same-content]
use ../lib/paths.nu [files-under valid-path]
use ../lib/rewrite.nu [file-uri json-escape rewrite-exact-paths]

const HASH = '^[a-f0-9]{64}$'
const NAME = '^[a-f0-9]{64}(?:\.[a-z0-9][a-z0-9._-]{0,31})?$'

# --------------------------------------------------------------------------------------------------
# References
# --------------------------------------------------------------------------------------------------

def strings [value: any]: nothing -> list<string> {
  let shape = ($value | describe)
  if $shape == "string" {
    [$value]
  } else if ($shape | str starts-with "record") {
    $value
    | transpose key value
    | each {|entry| (strings $entry.key) ++ (strings $entry.value) }
    | flatten
  } else if ($shape | str starts-with "list") or ($shape | str starts-with "table") {
    $value
    | each {|entry| strings $entry }
    | flatten
  } else {
    []
  }
}

def normalize-refs [refs: list<record>]: nothing -> list<record> {
  $refs
  | group-by id
  | transpose id refs
  | each {|group|
    {
      id: $group.id
      aliases: ($group.refs | get aliases | flatten | uniq | sort)
    }
  }
  | sort-by id
}

def possible-reference [text: string, prefixes: list<string>]: nothing -> bool {
  $text =~ '(blob:|[a-f0-9]{64})' or (
    $prefixes | any {|prefix| $text | str contains ($prefix + "/") }
  )
}

def text-references [text: string, prefixes: list<string>]: nothing -> list<record> {
  if not (possible-reference $text $prefixes) { return [] }
  for prefix in $prefixes {
    if ($text | str starts-with ($prefix + "/")) {
      let name = ($text | str substring (($prefix | str length) + 1)..)
      if $name =~ $NAME {
        return [{
          id: ($name | str substring 0..<64)
          aliases: (if $name =~ $HASH { [] } else { [$name] })
        }]
      }
    }
  }
  if ($text | str starts-with "blob:") {
    if $text !~ '^blob:sha256:[a-f0-9]{64}$' {
      error make --unspanned {msg: "Unsupported or malformed OMP blob locator"}
    }
    return [{
      id: ($text | str substring 12..)
      aliases: []
    }]
  }

  mut refs = []
  let locators = (
    $text
    | parse --regex '\bblob:(?<algorithm>[A-Za-z0-9_-]+):(?<suffix>[A-Za-z0-9_./:-]*)'
  )
  for locator in $locators {
    if $locator.algorithm == "sha256" and $locator.suffix == "" { continue }
    let id = ($locator.suffix | str trim --right --char ".")
    if $locator.algorithm != "sha256" or $id !~ $HASH {
      error make --unspanned {msg: "Unsupported or malformed OMP blob locator"}
    }
    $refs = ($refs | append {
      id: $id
      aliases: []
    })
  }

  let aliases = (
    $text
    | parse --regex '(?<![A-Za-z0-9_])(?<name>[a-f0-9]{64}\.[a-z0-9][a-z0-9._-]{0,31})(?![A-Za-z0-9_.-])'
    | get name
  )
  for name in $aliases {
    let name = ($name | str trim --right --char ".")
    $refs = ($refs | append {
      id: ($name | str substring 0..<64)
      aliases: [$name]
    })
  }

  for prefix in $prefixes {
    let pattern = (
      '(?<![A-Za-z0-9_/.-])' + ($prefix | str escape-regex)
      + '/(?<name>[A-Za-z0-9_.-]+)(?![A-Za-z0-9_./-])'
    )
    for match in ($text | parse --regex $pattern) {
      let name = ($match.name | str trim --right --char ".")
      if $name !~ $NAME {
        error make --unspanned {msg: "Unsupported OMP blob filename reference"}
      }
      let aliases = if $name =~ $HASH { [] } else { [$name] }
      $refs = ($refs | append {
        id: ($name | str substring 0..<64)
        aliases: $aliases
      })
    }
  }

  normalize-refs $refs
}

export def references [files: list<string>, roots: list<string>]: nothing -> list<record> {
  let prefixes = (
    $roots
    | uniq
    | each {|root| [$root (file-uri $root)] }
    | flatten
    | uniq
  )
  let escaped_prefixes = ($prefixes | each {|prefix| json-escape $prefix })
  mut refs = []
  for file in ($files | uniq | sort) {
    let content = try {
      open --raw $file | into string
    } catch {
      error make --unspanned {msg: $"Cannot read OMP dependency journal ($file) as UTF-8"}
    }

    for line in ($content | lines | enumerate) {
      if ($line.item | str trim) == "" { continue }
      let value = try {
        $line.item | from json
      } catch {
        error make --unspanned {
          msg: $"Invalid OMP dependency journal record at ($file):($line.index + 1)"
        }
      }
      if not (($value | describe) | str starts-with "record") {
        error make --unspanned {
          msg: $"Expected an OMP journal record at ($file):($line.index + 1)"
        }
      }
      if not (possible-reference ($value | to json --raw) $escaped_prefixes) { continue }

      for text in (strings $value) {
        $refs = ($refs ++ (text-references $text $prefixes))
      }
    }
  }
  normalize-refs $refs
}

# --------------------------------------------------------------------------------------------------
# Requests
# --------------------------------------------------------------------------------------------------

def require-keys [value: any, keys: list<string>]: nothing -> nothing {
  if not (($value | describe) | str starts-with "record") {
    error make --unspanned {msg: "Invalid OMP dependency request record"}
  }
  if ($value | columns | sort) != ($keys | sort) {
    error make --unspanned {msg: "Unknown or missing OMP dependency request fields"}
  }
}

def normalized-absolute [value: any]: nothing -> bool {
  if not (valid-path $value) { return false }
  $value == ($value | path expand --no-symlink)
}

export def validate-request [request: any]: nothing -> record {
  require-keys $request ["version" "assistant" "path" "source_blob_root" "sessions"]
  if ($request.version | describe) != "int" or $request.version != 1 or (
    $request.assistant != "omp"
  ) {
    error make --unspanned {msg: "Unsupported OMP dependency request version or assistant"}
  }
  if not (normalized-absolute $request.path) or (
    not (normalized-absolute $request.source_blob_root) or $request.source_blob_root == "/"
  ) {
    error make --unspanned {msg: "OMP dependency request paths must be normalized absolute paths"}
  }
  if not (($request.sessions | describe) =~ '^(list|table)') {
    error make --unspanned {msg: "OMP dependency request sessions must be a list"}
  }

  mut ids = []
  for session in $request.sessions {
    require-keys $session ["id" "blobs"]
    if ($session.id | describe) != "string" or $session.id !~ '^[A-Za-z0-9_-]{1,128}$' {
      error make --unspanned {msg: "Invalid OMP dependency request session identity"}
    }
    if $session.id in $ids {
      error make --unspanned {msg: "Duplicate OMP dependency request session identity"}
    }
    $ids = ($ids | append $session.id)
    if not (($session.blobs | describe) =~ '^(list|table)') {
      error make --unspanned {msg: "OMP dependency request blobs must be a list"}
    }

    mut hashes = []
    for blob in $session.blobs {
      require-keys $blob ["id" "aliases"]
      if ($blob.id | describe) != "string" or $blob.id !~ $HASH or $blob.id in $hashes {
        error make --unspanned {msg: "Invalid or duplicate OMP dependency blob identity"}
      }
      $hashes = ($hashes | append $blob.id)
      if not (($blob.aliases | describe) =~ '^list') {
        error make --unspanned {msg: "OMP dependency aliases must be a list"}
      }
      if ($blob.aliases | uniq | length) != ($blob.aliases | length) {
        error make --unspanned {msg: "Duplicate OMP dependency alias"}
      }
      for alias in $blob.aliases {
        if ($alias | describe) != "string" or $alias !~ $NAME or (
          not ($alias | str starts-with ($blob.id + "."))
        ) {
          error make --unspanned {msg: "Invalid OMP dependency alias"}
        }
      }
    }
  }

  $request
  | update sessions {
    $in
    | each {|session| $session | update blobs { normalize-refs $in } }
    | sort-by id
  }
}

export def read-request [file: string]: nothing -> record {
  let request = try {
    open --raw $file | from json
  } catch {
    error make --unspanned {msg: "Cannot read OMP dependency request JSON"}
  }
  validate-request $request
}

def requested-blobs [request: record]: nothing -> list<record> {
  normalize-refs ($request.sessions | get blobs | flatten)
}

export def rewrite-paths [
  content: string
  request: record
  root: string
  --source-root: string
]: nothing -> string {
  let source = ($source_root | default $request.source_blob_root)
  let roots = ([$source $request.source_blob_root] | uniq)
  let blobs = (requested-blobs $request)
  if ($blobs | is-empty) { return $content }
  let prefixes = (
    $roots
    | each {|prefix| [$prefix (file-uri $prefix)] }
    | flatten
    | each {|prefix| json-escape ($prefix + "/") }
  )
  let names = (
    $blobs
    | each {|blob| [$blob.id] ++ $blob.aliases }
    | flatten
  )
  let mappings = (
    $roots
    | each {|source|
      $names | each {|name|
        {
          old: ($source | path join $name)
          new: ($root | path join $name)
        }
      }
    }
    | flatten
  )

  $content
  | split row "\n"
  | each {|line|
    if ($line | str trim) == "" { return $line }
    let normalized = try {
      $line | from json | to json --raw
    } catch {
      error make --unspanned {msg: "Invalid OMP journal record while repairing dependency paths"}
    }
    if not ($prefixes | any {|prefix| $normalized | str contains $prefix }) { return $line }
    rewrite-exact-paths $line $mappings
  }
  | str join "\n"
}

# --------------------------------------------------------------------------------------------------
# Blob files
# --------------------------------------------------------------------------------------------------

def require-regular [path: string]: nothing -> nothing {
  if ($path | path type) != "file" {
    error make --unspanned {msg: $"Missing or non-regular OMP blob file ($path)"}
  }
}

def content-hash [file: string]: nothing -> string {
  ^sha256sum -- $file
  | split row " "
  | first
}

export def resolve-files [request: record, root: string]: nothing -> list<record> {
  let inventory = (
    files-under $root
    | where {|file| ($file | path dirname) == $root }
  )
  mut files = []
  for blob in (requested-blobs $request) {
    let canonical = ($root | path join $blob.id)
    require-regular $canonical
    if (content-hash $canonical) != $blob.id {
      error make --unspanned {msg: $"OMP blob content does not match its address: ($canonical)"}
    }

    let aliases = (
      $inventory
      | where {|file|
        let name = ($file | path basename)
        ($name | str starts-with ($blob.id + ".")) and $name =~ $NAME
      }
      | each {|file| $file | path basename }
    )
    let names = ([$blob.id] ++ $blob.aliases ++ $aliases | uniq | sort)
    for name in $names {
      let source = ($root | path join $name)
      require-regular $source
      if not (same-content $canonical $source) {
        error make --unspanned {msg: $"OMP blob alias differs from its canonical file: ($source)"}
      }
      $files = ($files | append {
        kind: "blobs"
        project: ""
        name: $name
        source: $source
      })
    }
  }
  $files
}

export def retirement-files [request: record, root: string]: nothing -> list<string> {
  let ids = (requested-blobs $request | get id)
  files-under $root
  | where {|file|
    let name = ($file | path basename)
    (
      ($file | path dirname) == $root and $name =~ $NAME
      and ($name | str substring 0..<64) in $ids
    )
  }
  | each {|file|
    let id = ($file | path basename | str substring 0..<64)
    if (content-hash $file) != $id {
      error make --unspanned {msg: $"OMP blob content does not match its address: ($file)"}
    }
    $file
  }
}

export def verify-files [request: record, files: list<record>]: nothing -> nothing {
  let blobs = (requested-blobs $request)
  let carried = ($files | where kind == "blobs")
  let names = ($carried | get name)
  if ($names | uniq | length) != ($names | length) {
    error make --unspanned {msg: "Duplicate OMP blob files in bundle"}
  }
  for file in $carried {
    if $file.project != "" or $file.name !~ $NAME {
      error make --unspanned {msg: "Invalid OMP blob bundle destination"}
    }
    let id = ($file.name | str substring 0..<64)
    if $id not-in ($blobs | get id) {
      error make --unspanned {msg: "OMP bundle contains a blob absent from the request"}
    }
    require-regular $file.bundle
    if (content-hash $file.bundle) != $id {
      error make --unspanned {msg: "OMP blob bundle content does not match its address"}
    }
  }
  for blob in $blobs {
    for name in ([$blob.id] ++ $blob.aliases) {
      if $name not-in $names {
        error make --unspanned {msg: $"OMP bundle is missing a required blob file: ($name)"}
      }
    }
  }
}
