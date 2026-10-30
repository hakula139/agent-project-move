# Design

`agent-project-move` treats an assistant store as a set of records keyed by absolute paths. A move rewrites those keys in place, a prune deletes the records of paths that no longer exist, and a transfer copies them to another host. This page explains the invariants behind those three operations and the shape every action takes.

## Invariants

The final state after a `move <old> <new>` is that no structured path field refers to `<old>` or below, every moved session resumes from `<new>`, nothing is duplicated, and memory waiting for consolidation sits in `memory/incoming/`. Six rules follow:

- **Plan from current state.** Selection and every decision read what is on disk now, never what a previous run was expected to do. A transcript is selected because a record's `cwd` is under `<old>`, whatever its first line says. A rerun after a partial failure therefore converges on the same final state, and no step may make a rerun fail forever, as a key collision would.
- **Rewrite sources of truth and drop derived data.** Transcripts, rollouts, and session rows are rewritten. Anything an assistant derives from them is deleted instead: Claude's `sessions-index.json` when a project directory merges, and Codex's `thread_history` projections when a rewritten rollout changes byte lengths. Nothing derived is maintained by hand.
- **A Claude project directory's identity is its name.** A directory moves or exports only when its name encodes `<old>` or a path under it. Its owner is the recorded `cwd` whose encoding equals its name, which need not be any transcript's first `cwd`. Transcripts elsewhere that merely reference `<old>` are edited in place and stay in their directory.
- **Rewrite values generically.** Every JSON string token equal to `<old>` or starting with `<old>/` is rewritten, as a key or a value, at any depth, plain or as a `file://` URI, while every other byte round-trips untouched. Each assistant release adds record kinds, so a field list would never stay complete.
- **Derive destinations from where files land.** An import sets `rollout_path` and similar fields to the path it writes the file to on the target, without mapping the source host's roots.
- **Missing means gone.** A path under a mount root (`/Volumes/<name>`, `/mnt/<name>`) counts as missing only when that root is mounted. A missing subpath or worktree of a repository that still exists is a move target, because its sessions belong to the repository's history.

A backup makes a mistake restorable. An applied run copies everything it edits or deletes, backs up every database, and writes a manifest of every action in order.

## Actions

Each store returns plain records, and none of them writes. An action is `{assistant, store, op, path, description}` plus the fields its operation needs:

| Operation | Extra fields       | Effect                                                                                                  |
| --------- | ------------------ | ------------------------------------------------------------------------------------------------------- |
| `rename`  | `to`               | Atomic `mv`. Merging into an existing directory renames entry by entry and then removes the emptied one |
| `rmdir`   |                    | Removes a directory a merge emptied, aborting when anything else remains                                |
| `edit`    | `transform`        | Reads the current file at apply time, transforms it, and replaces it atomically, keeping its mtime      |
| `copy`    | `to`               | Writes a file from an export bundle, preserving mode and timestamps                                     |
| `delete`  |                    | Removes a file or directory that a prune or a listed discard owns                                       |
| `sql`     | `db`, `statements` | One `sqlite3 -bail` run per action, each in its own transaction                                         |

`edit` runs at apply time, so a change another process made between plan and apply survives. Binary files are never edited.

Rows are matched with `substr`, because `LIKE` folds case and treats `_` and `%` as wildcards. A move emits one set-based `UPDATE` per declared path column:

```sql
UPDATE t SET c = '<new>' || substr(c, length('<old>') + 1)
WHERE c = '<old>' OR substr(c, 1, length('<old>') + 1) = '<old>/'
```

A row written between plan and apply is therefore covered too. A key collision uses `UPDATE OR IGNORE` then `DELETE`, so the destination row wins.

## Apply order

A dry run prints the order below and stops. `--apply` writes a backup, runs the derived statements, then every remaining action in this order:

1. **Derived statements**, which delete data that a source rewrite invalidates. They run first because a source write ends their selection, so an interrupted apply still converges on the rerun.
2. **Per assistant, the row actions that must precede files**, such as a prune's row deletes, so a failure leaves that assistant's files or rows for the rerun.
3. **Per assistant, file actions**, then the rest of that assistant's statements.

Each SQL action runs as its own `sqlite3 -bail` transaction, with `PRAGMA busy_timeout = 5000` and `BEGIN IMMEDIATE`, so a move issues one per path column and an import one per database. A prune adds `PRAGMA foreign_keys = ON` so the schema's cascades delete child rows. Planning opens every database read-only.

## Backup layout

An applied run creates `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/<timestamp>-<pid>/` with mode 0700:

- `manifest.json` lists every action in order, including each rename's `to`.
- Each edited or deleted file is copied under the same absolute path, with its leading `/` removed.
- Each database is copied with `sqlite3 .backup`.

Restoring reverses the renames and `rmdir`s in reverse order, then restores the databases and copies the files back. [Restore](../../skills/agent-project-move/SKILL.md#restore) has the procedure.

## Transfer

`export <old> <dir>` writes one subdirectory per assistant with the files and rows recorded for `<old>`, unchanged, plus `entries.json` listing rows with their column names. It only reads state, so it needs no `--apply`.

`import <dir>` plans the merge:

- Directories are encoded with the target's own rules and `HOME`, and carried `rollout_path` values point at the copied files.
- A row is inserted unless its unique key already exists, so a rerun after the move plans nothing. Every other constraint stays fatal, and a failing row aborts that database's whole load.
- A store whose sessions the target already holds is skipped, memory included. The identity set is rows plus, for OMP, session files by relative path, and it counts only when non-empty, so a bundle holding only memory still imports.
- A session file the target holds is skipped wherever it lives, while a memory file at the same path with different content aborts.
- An existing target file with identical content counts as done.
- Each carried table is checked at plan time: the import aborts before writing when the target lacks a carried column, or requires a not-null column without a default that the bundle does not fill.

Codex trust blocks are not carried, so the target asks for trust once on the first resume. A bundle carries no Codex history projection, because rewriting the rollout invalidates its byte offsets.

## Merges and memory staging

When two Claude project directories merge, the unique transcripts from both sides are kept and `sessions-index.json` is deleted. If the destination already has a `memory/` directory, the source's memory lands in `<destination>/memory/incoming/<encoded-source>/` untouched, for consolidation by a memory-consolidation skill or by hand. Otherwise it moves in directly, dropping identical duplicates. OMP memory collisions keep the destination file and delete the source copy. The script never merges memory content itself.

## Safety

- **No process check.** Running assistants already share these stores. SQLite serializes writers, session files are appended only by their own session and keep receiving appends across a rename, and `~/.claude.json` is a last-writer-wins document that concurrent sessions already rewrite.
- **Close sessions before applying.** An `edit` replaces a file through a temporary file, so a session writing at that moment loses those writes.
- **A file-phase failure needs the backup.** Rewritten transcripts no longer name the subpaths that selected their directories, so restore from the run's backup and rerun. An SQL-phase failure recovers from a plain rerun.
