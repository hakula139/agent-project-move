# Design

`agent-project-move` treats an assistant store as a set of records keyed by absolute paths. A move rewrites those keys in place, a prune deletes the records of paths that no longer exist, a retirement removes selected session copies, and a transfer copies them to another host. This page explains their invariants and the shape every action takes.

## Invariants

The final state after a `move <old> <new>` is that no structured path field refers to `<old>` or below, every moved session resumes from `<new>`, nothing is duplicated, and memory waiting for consolidation sits in `memory/incoming/`. These rules follow:

- **Plan from current state.** Selection and every decision read what is on disk now, never what a previous run was expected to do. A transcript is selected because a record's `cwd` is under `<old>`, whatever its first line says. A rerun after a partial failure therefore converges on the same final state, and no step may make a rerun fail forever, as a key collision would.
- **Rewrite sources of truth and drop derived data.** Transcripts, rollouts, and session rows are rewritten. Anything an assistant derives from them is deleted instead: Claude's `sessions-index.json` when a project directory merges, and Codex's `thread_history` projections when a rewritten rollout changes byte lengths. Nothing derived is maintained by hand.
- **A Claude project directory's identity is its name.** A directory moves or participates in a default prefix export only when its name encodes `<old>` or a path under it. Its owner is the recorded `cwd` whose encoding equals its name, which need not be any transcript's first `cwd`. Transcripts elsewhere that merely reference `<old>` are edited in place during a move and stay in their directory. Exact and ID-selected exports preserve each selected transcript's physical project owner.
- **Rewrite values generically.** Every JSON string token equal to `<old>` or starting with `<old>/` is rewritten, as a key or a value, at any depth, plain or as a `file://` URI, while every other byte round-trips untouched. Each assistant release adds record kinds, so a field list would never stay complete.
- **Match and record one spelling each.** `<old>` matches as an exact, case-sensitive string prefix, and each rewritten value takes the spelling the working directory reports at the destination.
- **Derive destinations from where files land.** An import sets `rollout_path` and similar fields to the path it writes the file to on the target, without mapping the source host's roots.
- **Missing means gone.** A path under a mount root (`/Volumes/<name>`, `/mnt/<name>`, `/media/<user>/<name>`, `/run/media/<user>/<name>`) counts as missing only when that root is mounted. A missing subpath or worktree of a repository that still exists is a move target, because its sessions belong to the repository's history.

A backup makes a mistake restorable. An applied run copies everything it edits or deletes, backs up every database, and writes a manifest of every action in order. Only an explicit `retire --no-backup` skips this recovery material.

## Session selection

Default exports select paths equal to the argument or under it. Claude preserves its directory-based prefix export, carrying the whole owning directory and its session dependencies. `--exact` selects sessions whose recorded cwd equals the path, while `--session-ids` selects the given IDs under the path. The options are mutually exclusive, and retirement requires one of them. Session selection follows dependent descendants, even when their cwd differs, without adding ancestors or siblings.

Each store normalizes its session identities, recorded cwds, parent relationships, physical files, and project ownership before selection. Missing or invalid IDs never participate in the relationship graph. Physical project ownership stays separate from a visited cwd. A selected session owns its transcript and its same-stem artifact subtree. Shared project metadata is removed only after its remaining references are accounted for, using exact owners during retirement. Prune retains its missing-path semantics and shares session deletion helpers with retirement.

## Actions

Each store returns plain records, and none of them writes. An action is `{assistant, store, op, path, description}` plus the fields its operation needs:

| Operation | Extra fields               | Effect                                                                                                  |
| --------- | -------------------------- | ------------------------------------------------------------------------------------------------------- |
| `rename`  | `to`                       | Atomic `mv`. Merging into an existing directory renames entry by entry and then removes the emptied one |
| `rmdir`   |                            | Removes a directory a merge emptied, aborting when anything else remains                                |
| `edit`    | `transform`                | Reads the current file at apply time, transforms it, and replaces it atomically, keeping its mtime      |
| `copy`    | `to`, optional `transform` | Copies a bundle file or atomically writes its transformed content, preserving mode and timestamps       |
| `delete`  |                            | Removes a file or directory that a prune or a listed discard owns                                       |
| `sql`     | `db`, `statements`         | One `sqlite3 -bail` run per action, each in its own transaction                                         |

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

A prune's SQL actions turn on `PRAGMA foreign_keys` so the schema's cascades delete child rows. Planning opens every database read-only.

## Backup layout

An applied run creates `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/` and its `<timestamp>-<pid>/` directory with mode 0700:

- `manifest.json` lists every action in order, including each rename's `to`.
- Each edited or deleted file is copied under the same absolute path, with its leading `/` removed.
- Each database is copied with `sqlite3 .backup`.

[Restore](../../skills/agent-project-move/SKILL.md#restore) has the procedure for putting the previous state back.

## Transfer

`export <old> <dir>` writes one subdirectory per assistant that records selected state for `<old>`, with the files and rows it holds unchanged, plus `entries.json` listing rows with their column names. It only reads state, so it needs no `--apply`.

Each file descriptor records its exported source in `origin_path`. This field is provenance metadata and does not control import destinations. Older bundles may omit it.

`import <dir>` plans the merge:

- Directories are encoded with the target's own rules and `HOME`, and carried `rollout_path` values point at the copied files.
- A row is inserted unless its unique key already exists. Every other constraint stays fatal, and a failing row aborts that database's whole load.
- Existing session IDs are checked against their transcripts before skipping copies, including decoded compressed Codex rollouts and OMP IDs from session headers. A differing transcript aborts before writing. Dependent file history and Codex parent edges are reconciled even when the session already exists.
- A repeated import requires identical transcript content after the import's explicit file mapping. Rewritten paths count as a content difference, so reconcile or re-export moved sessions before importing them again.
- OMP rollout rows map to imported files by header ID, so identical nested filenames stay distinct. Shared memory for an already imported session set stays in place, while a memory-only bundle still imports.
- A carried OMP header's path-valued `parentSession` is mapped to the known imported parent file. Other header and message bytes stay unchanged, and external parent identities remain opaque.
- An existing target file with identical content counts as done.
- Each carried table is checked at plan time: the import aborts before writing when the target lacks a carried column, or requires a not-null column without a default that the bundle does not fill.

Codex trust blocks are not carried, so the target asks for trust once on the first resume. A bundle carries no Codex history projection, because rewriting the rollout invalidates its byte offsets.

## Merges and memory staging

When two Claude project directories merge, the unique transcripts from both sides are kept and `sessions-index.json` is deleted. If the destination already has a `memory/` directory, the source's memory lands in `<destination>/memory/incoming/<source-encoded-name>/` untouched, for consolidation by hand. Otherwise it moves in directly, dropping identical duplicates. OMP memory collisions keep the destination file and delete the source copy. The script never merges memory content itself.

## Safety

See [Safety model](../../README.md#safety-model) for the concurrency requirements.

- **A file-phase failure needs the backup.** Rewritten transcripts no longer name the subpaths that selected their directories, so restore from the run's backup and rerun. An SQL-phase failure recovers from a plain rerun.
