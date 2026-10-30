# ==================================================================================================
# Agent Project Move: Actions
# ==================================================================================================
# Action records, directory merges, file copies and backups, and applying a plan.
# ==================================================================================================

use ./output.nu [plural print-table]
use ./rewrite.nu [file-uri json-escape rewrite-text]
use ./sqlite.nu [path-condition run-sql sql-quote sqlite-rows]

export def action [
  assistant: string
  store: string
  op: string
  path: string
  description: string
]: nothing -> record {
  {assistant: $assistant, store: $store, op: $op, path: $path, description: $description}
}

export def edit-action [
  assistant: string
  store: string
  path: string
  transform: closure
  description: string
]: nothing -> record {
  action $assistant $store edit $path $description
  | merge {transform: $transform}
}

export def copy-action [
  assistant: string
  store: string
  source: string
  target: string
  description: string
]: nothing -> record {
  action $assistant $store copy $source $description
  | merge {to: $target}
}

export def rename-action [
  assistant: string
  store: string
  source: string
  target: string
  description: string
]: nothing -> record {
  action $assistant $store rename $source $description
  | merge {to: $target}
}

export def sql-action [
  assistant: string
  store: string
  db: string
  statements: list<string>
  description: string
  --derived # Bring derived data in line before a source write ends its selection
  --rows-first # Delete rows before the files they reference
  --foreign-keys # Delete child rows through the schema's cascades
]: nothing -> record {
  action $assistant $store sql $db $description
  | merge {
    statements: $statements
    phase: (if $derived { "derived" } else { null })
    rows_first: $rows_first
    foreign_keys: $foreign_keys
  }
}

def json-column-statements [
  db: string
  table: string
  column: string
  old: string
  new: string
]: nothing -> list<string> {
  let plain = (sql-quote (json-escape $old))
  let uri = (sql-quote (json-escape (file-uri $old)))
  let query = (
    "SELECT rowid AS rid, " + $column + " AS value FROM " + $table
    + " WHERE instr(" + $column + ", " + $plain + ") > 0"
    + " OR instr(" + $column + ", " + $uri + ") > 0"
  )
  sqlite-rows $db $query
  | each {|row|
    let value = ($row.value | into string)
    let updated = (rewrite-text $value $old $new)
    if $updated == $value {
      null
    } else {
      (
        "UPDATE " + $table + " SET " + $column + " = " + (sql-quote $updated)
        + " WHERE rowid = " + ($row.rid | into string)
        + " AND " + $column + " = " + (sql-quote $value)
      )
    }
  }
  | compact
}

export def column-statements [
  table: string
  column: string
  old: string
  new: string
  --prefix: string = ""
  --collide
]: nothing -> list<string> {
  let condition = (path-condition $column [$old] --prefix $prefix)
  let value = (
    (sql-quote $prefix) + " || " + (sql-quote $new)
    + " || substr(" + $column + ", length(" + (sql-quote ($prefix + $old)) + ") + 1)"
  )
  let update = (
    "UPDATE " + $table + " SET " + $column + " = " + $value + " WHERE " + $condition
  )
  if $collide {
    let insert = ($update | str replace --regex '^UPDATE ' 'UPDATE OR IGNORE ')
    [$insert $"DELETE FROM ($table) WHERE ($condition)"]
  } else {
    [$update]
  }
}

# One action per path column, so a plain column is set-based and covers rows written before
# apply, while a JSON column is rewritten per row from its plan-time value.
export def column-actions [
  assistant: string
  columns: list<record>
  old: string
  new: string
]: nothing -> list<record> {
  mut actions = []
  for spec in $columns {
    let db = $spec.db
    if not ($db | path exists) { continue }
    let table = $spec.table
    let column = $spec.column
    let prefix = ($spec | get -o prefix | default "")
    let condition = (path-condition $column [$old] --prefix $prefix)
    let statements = if ($spec | get -o json | default false) {
      json-column-statements $db $table $column $old $new
    } else {
      let exists = (
        sqlite-rows $db (
          "SELECT EXISTS (SELECT 1 FROM " + $table + " WHERE " + $condition + ") AS found"
        )
        | get 0.found
        | into int
      )
      if $exists == 0 {
        []
      } else {
        let collide = ($spec | get -o collide | default false)
        column-statements $table $column $old $new --prefix $prefix --collide=$collide
      }
    }
    if ($statements | is-not-empty) {
      let description = $"rewrite ($table).($column)"
      $actions = ($actions | append (sql-action $assistant $table $db $statements $description))
    }
  }
  $actions
}

def manifest-view [action: record]: nothing -> record {
  let view = ($action | select assistant store op path description)
  if $action.op in [rename copy] { $view | upsert to $action.to } else { $view }
}

export def same-content [left: string, right: string]: nothing -> bool {
  (^cmp -s $left $right | complete).exit_code == 0
}

export def same-tree [left: string, right: string]: nothing -> bool {
  (^diff -rq $left $right | complete).exit_code == 0
}

# Whether two paths name one directory, including two spellings of it on a case-insensitive volume.
export def same-directory [left: string, right: string]: nothing -> bool {
  if $left == $right { return true }
  if not (($left | path exists) and ($right | path exists)) { return false }
  let left_id = (^stat -L -c '%d:%i' $left | str trim)
  let right_id = (^stat -L -c '%d:%i' $right | str trim)
  $left_id == $right_id
}

export def merge-actions [
  assistant: string
  store: string
  source: string
  target: string
  description: string
  --skip (-s): list<string> = []
  --prefer-destination (-d) # Delete a colliding source file
]: nothing -> list<record> {
  if not ($source | path exists) { return [] }
  if (same-directory $source $target) { return [] }
  if $source in $skip { return [] }
  if not ($target | path exists) {
    return [(rename-action $assistant $store $source $target $description)]
  }

  let source_type = ($source | path type)
  let target_type = ($target | path type)
  if $source_type != $target_type {
    error make --unspanned {
      msg: $"Both ($source) and ($target) exist as different kinds"
      help: "Move or delete one of them, then rerun the move. Nothing was written."
    }
  }

  if $source_type != "dir" {
    if $prefer_destination {
      return [(action $assistant $store delete $source "destination wins")]
    }
    if (same-content $source $target) {
      return [(action $assistant $store delete $source "duplicate of the destination")]
    }
    error make --unspanned {
      msg: $"Both ($source) and ($target) exist with different content"
      help: "Keep one copy, moving or deleting the other, then rerun the move. Nothing was written."
    }
  }

  mut actions = []
  let entries = (ls -a $source | get name | each {|path| $path | path basename })
  for entry in $entries {
    let from = ($source | path join $entry)
    if $from in $skip { continue }
    let to = ($target | path join $entry)
    $actions = (
      $actions
      ++ (
        merge-actions $assistant $store $from $to $description --skip $skip
        --prefer-destination=$prefer_destination
      )
    )
  }
  $actions | append (action $assistant $store rmdir $source "remove emptied source directory")
}

export def decompress-file [path: string]: nothing -> string {
  let run = (^zstd -dc $path | complete)
  if $run.exit_code != 0 {
    error make --unspanned {
      msg: $"zstd failed to read ($path): ($run.stderr | str trim)"
      help: $"Check that ($path) is a valid zstd file."
    }
  }
  $run.stdout
}

def compress-file [content: string, target: string]: nothing -> nothing {
  let run = ($content | ^zstd -q -f -o $target | complete)
  if $run.exit_code != 0 {
    error make --unspanned {
      msg: $"zstd failed on ($target): ($run.stderr | str trim)"
      help: $"Check that ($target) is writable."
    }
  }
}

def write-file [path: string, content: any, --compress]: nothing -> nothing {
  let mode = (^stat -c %a $path | str trim)
  let temporary = (^mktemp $"($path).tmp.XXXXXXXXXX" | str trim)
  try {
    if $compress {
      compress-file $content $temporary
    } else {
      $content | save --force $temporary
    }
    ^chmod $mode $temporary
    ^touch -r $path $temporary
    mv --force $temporary $path
  } catch {|error|
    rm --force $temporary
    error make $error
  }
}

def edit-file [path: string, transform: closure]: nothing -> nothing {
  let compress = ($path | str ends-with ".zst")
  let content = if $compress { decompress-file $path } else { open --raw $path }
  if ($content | describe) != "string" {
    error make --unspanned {
      msg: $"Refusing to edit the binary file ($path)"
      help: "Convert the file to UTF-8, or move it by hand."
    }
  }
  let updated = (do $transform $content)
  if $updated == $content { return }
  write-file $path $updated --compress=$compress
}

def execute-action [action: record]: nothing -> nothing {
  match $action.op {
    'rename' => {
      mkdir ($action.to | path dirname)
      ^mv -T $action.path $action.to
    }
    'copy' => {
      mkdir ($action.to | path dirname)
      ^cp --preserve=mode,timestamps $action.path $action.to
    }
    'edit' => { edit-file $action.path $action.transform }
    'delete' => { rm --recursive --force $action.path }
    'rmdir' => { ^rmdir $action.path }
    _ => {
      error make --unspanned {
        msg: $"Unknown action ($action.op)"
        help: "Rerun with the version that planned this action."
      }
    }
  }
}

def backup-path [root: string, path: string]: nothing -> nothing {
  if not ($path | path exists) { return }
  let destination = ($root | path join ($path | str replace --regex '^/' ''))
  mkdir ($destination | path dirname)
  ^cp --recursive --preserve=mode,timestamps $path $destination
}

def backup-root []: nothing -> string {
  let base = ($env.XDG_STATE_HOME? | default --empty ($env.HOME | path join .local state))
  $base | path join agent-project-move
}

def run-sql-actions [actions: list<record>]: nothing -> nothing {
  for db in ($actions | where op == sql | get path | uniq) {
    let statements = (
      $actions
      | where op == sql
      | where path == $db
      | get statements
      | flatten
    )
    let foreign = (
      $actions
      | where path == $db
      | any {|action| ($action | get -o foreign_keys) == true }
    )
    run-sql $db $statements --foreign-keys=$foreign
  }
}

export def apply-all [actions: list<record>, --apply]: nothing -> nothing {
  if ($actions | is-empty) {
    print "No changes."
    return
  }

  # An assistant's row deletes run right before its own file deletes, so a failure leaves that
  # assistant's files or rows for the rerun and leaves later assistants untouched.
  let derived = ($actions | where {|action| ($action | get -o phase) == "derived" })
  let remaining = ($actions | where {|action| ($action | get -o phase) != "derived" })
  let groups = (
    $remaining
    | get assistant
    | uniq
    | each {|assistant|
      let group = ($remaining | where assistant == $assistant)
      let rows = ($group | where {|action| ($action | get -o rows_first) == true })
      let after = ($group | where {|action| ($action | get -o rows_first) != true })
      $rows ++ ($after | where op != sql) ++ ($after | where op == sql)
    }
  )
  let tail = ($groups | flatten)
  let ordered = ($derived ++ $tail)

  if not $apply {
    $ordered | each {|action| manifest-view $action | default "" to } | print-table
    let count = ($ordered | length)
    print $"Dry run: ($count) (plural $count 'action' 'actions') planned, nothing written. Rerun with --apply to write the plan. A backup goes to (backup-root) first."
    return
  }

  let stamp = (date now | format date '%Y%m%dT%H%M%S')
  let root = (backup-root)
  let backup_dir = ($root | path join $"($stamp)-($nu.pid)")
  let databases = ($actions | where op == sql | get path | uniq)
  mkdir $root
  ^chmod 700 $root
  mkdir $backup_dir
  ^chmod 700 $backup_dir
  $ordered
  | each {|action| manifest-view $action }
  | to json
  | save --force ($backup_dir | path join manifest.json)

  for action in ($actions | where op in [edit delete]) {
    backup-path $backup_dir $action.path
  }
  for db in $databases {
    let destination = ($backup_dir | path join ($db | str replace --regex '^/' ''))
    mkdir ($destination | path dirname)
    let run = (^sqlite3 $db $".backup '($destination)'" | complete)
    if $run.exit_code != 0 {
      error make --unspanned {
        msg: $"SQLite backup failed on ($db): ($run.stderr | str trim)"
        help: $"Close the assistant that uses ($db) and rerun the same command."
      }
    }
  }
  print $"Backed up to ($backup_dir)"

  run-sql-actions $derived
  for action in $tail {
    if $action.op == sql {
      run-sql-actions [$action]
    } else {
      execute-action $action
    }
  }

  let count = ($actions | length)
  print $"Applied ($count) (plural $count 'action' 'actions')."
  print $"Run 'agent-project-move scan' to check the result, and keep ($backup_dir) until you have."
}
