# ==================================================================================================
# Agent Project Move: Bundles
# ==================================================================================================
# The export bundle format shared by every store and the entry point.
# ==================================================================================================

export def sha1-hex [text: string]: nothing -> string {
  $text | ^sha1sum | split row ' ' | first
}

export def bundle-table [bundle: record, table: string]: nothing -> record {
  $bundle.tables | where table == $table | get -o 0 | default {columns: [], rows: []}
}

export def write-bundle [directory: string, bundle: record]: nothing -> nothing {
  let base = ($directory | path join $bundle.assistant)
  mkdir $base
  mut files = []

  for file in $bundle.files {
    let key = $"($file.kind)|($file.project)|($file.name)"
    let name = (sha1-hex $key) + "-" + ($file.name | path basename)
    let relative = ([files $name] | path join)
    let target = ($base | path join $relative)
    mkdir ($target | path dirname)

    ^cp --preserve=mode,timestamps $file.source $target
    $files = ($files | append ($file | reject source | upsert bundle $relative))
  }

  $bundle
  | upsert files $files
  | to json
  | save --force ($base | path join entries.json)
}

export def read-bundle [directory: string, assistant: string]: nothing -> any {
  let base = ($directory | path join $assistant)
  let entries = ($base | path join entries.json)
  if not ($entries | path exists) { return null }

  let data = (open $entries)
  let files = (
    $data.files
    | each {|file|
      let path = ($base | path join $file.bundle)
      if not ($path | path exists) {
        error make {msg: $"Bundle incomplete: missing ($path). Recopy the bundle before importing."}
      }
      $file | upsert source $path | upsert bundle $path
    }
  )
  $data | upsert files $files
}
