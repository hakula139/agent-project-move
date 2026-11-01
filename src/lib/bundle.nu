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
  ^chmod 700 $base
  if ($bundle.files | is-not-empty) {
    mkdir ($base | path join files)
  }
  let files = (
    $bundle.files
    | each {|file|
      let key = $"($file.kind)|($file.project)|($file.name)"
      let name = (sha1-hex $key) + "-" + ($file.name | path basename)
      let relative = ([files $name] | path join)
      let target = ($base | path join $relative)

      ^cp --preserve=timestamps $file.source $target
      ^chmod 600 $target
      $file | reject source | upsert bundle $relative
    }
  )

  $bundle
  | upsert files $files
  | to json
  | save --force ($base | path join entries.json)
  ^chmod 600 ($base | path join entries.json)
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
        error make --unspanned {
          msg: $"Bundle incomplete: missing ($path)"
          help: "Recopy the bundle from the source host, then rerun the import."
        }
      }
      $file | upsert bundle $path
    }
  )
  $data | upsert files $files
}
