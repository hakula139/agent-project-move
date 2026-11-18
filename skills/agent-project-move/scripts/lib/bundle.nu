# ==================================================================================================
# Agent Project Move: Bundles
# ==================================================================================================
# The export bundle format shared by every store and the entry point.
# ==================================================================================================

use ./paths.nu [safe-relative-path]

export def bundle-table [bundle: record, table: string]: nothing -> record {
  $bundle.tables
  | where table == $table
  | get -o 0
  | default {
    columns: []
    rows: []
  }
}

export def require-empty-directory [directory: string]: nothing -> nothing {
  if ($directory | path exists) and (ls --all $directory | is-not-empty) {
    error make --unspanned {
      msg: $"Export directory is not empty: ($directory)"
      help: "Choose a new or empty directory for the bundle."
    }
  }
}

export def write-bundle [directory: string, bundle: record]: nothing -> nothing {
  let base = ($directory | path join $bundle.assistant)
  mkdir $base
  ^chmod 700 $base
  if ($bundle.files | is-not-empty) {
    mkdir ($base | path join "files")
  }

  let files = (
    $bundle.files
    | each {|file|
      let key = $"($file.kind)|($file.project)|($file.name)"
      let name = $"($key | hash sha256 | str substring 0..<40)-($file.name | path basename)"
      let relative = ("files" | path join $name)
      let target = ($base | path join $relative)

      ^cp --preserve=timestamps $file.source $target
      ^chmod 600 $target

      $file
      | reject source
      | upsert bundle $relative
    }
  )

  $bundle
  | upsert files $files
  | to json
  | save --force ($base | path join "entries.json")
  ^chmod 600 ($base | path join "entries.json")
}

export def read-bundle [directory: string, assistant: string]: nothing -> any {
  let base = ($directory | path join $assistant)
  let entries = ($base | path join "entries.json")
  if not ($entries | path exists) { return null }

  let data = (open $entries)
  if ($data | get -o assistant) != $assistant {
    error make --unspanned {msg: $"Bundle assistant does not match ($assistant)"}
  }
  let files = (
    $data.files
    | each {|file|
      let relative = ($file | get -o bundle)
      let name = ($file | get -o name)
      if not (safe-relative-path $relative) or not (safe-relative-path $name) {
        error make --unspanned {
          msg: $"Invalid relative path in ($entries)"
          help: "Re-export the bundle from a trusted source host, then rerun the import."
        }
      }
      if ($file | get -o kind) == "file-history" and (
        not (safe-relative-path ($file | get -o session))
        or (($file | get -o session) | str contains "/")
      ) {
        error make --unspanned {
          msg: $"Invalid session path in ($entries)"
          help: "Re-export the bundle from a trusted source host, then rerun the import."
        }
      }
      let parts = ($relative | split row "/")
      mut current = $base
      for part in $parts {
        $current = ($current | path join $part)
        if ($current | path exists --no-symlink) and ($current | path type) == "symlink" {
          error make --unspanned {
            msg: $"Bundle refuses symlink entry ($current)"
            help: "Re-export the bundle from a trusted source host, then rerun the import."
          }
        }
      }
      let path = ($base | path join $relative)
      if not ($path | path exists) or ($path | path type) != "file" {
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
