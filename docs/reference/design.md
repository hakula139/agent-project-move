# Design

`agent-project-move` treats assistant stores as records keyed by absolute paths. This page records constraints shared by the store adapters and executor. See the [skill](../../skills/agent-project-move/SKILL.md) for operating procedures and [Assistant stores](stores.md) for format-specific behavior.

## Invariants

After a `move <old> <new>`, rewritten session paths use `<new>` and moved project directories use its encoding. These rules follow:

- **Plan from current state.** Selection and every decision read what is on disk now, never what a previous run was expected to do. A transcript is selected because a record's `cwd` is under `<old>`, whatever its first line says. A rerun after a partial failure therefore converges on the same final state, and no step may make a rerun fail forever, as a key collision would.
- **Rewrite sources of truth and drop derived data.** Transcripts, rollouts, and session rows are rewritten. Codex's `thread_history` projections are deleted when a rollout is rewritten. Nothing derived is maintained by hand.
- **A Claude project directory's identity is its name.** A directory moves only when its name encodes `<old>` or a path under it. Its owner is identified by matching its name against encoded recorded paths, configuration project keys, and the explicit source path. Transcripts elsewhere that merely reference `<old>` are edited in place during a move and stay in their directory. Exports preserve each selected transcript's physical project owner.
- **Rewrite values generically.** In rewritten files, every JSON string token equal to `<old>` or starting with `<old>/` is rewritten, as a key or a value, at any depth, plain or as a `file://` URI, while every other byte round-trips untouched. Each assistant release adds record kinds, so a field list would never stay complete.
- **Match and record one spelling each.** `<old>` matches as an exact, case-sensitive string prefix, and each rewritten value takes the spelling the working directory reports at the destination.
- **Derive destinations from where files land.** An import sets `rollout_path` and similar fields to the path it writes the file to on the target, without mapping the source host's roots.

## Session selection

Session selection follows dependent descendants, even when their cwd differs, without adding ancestors or siblings. The [transfer procedure](../../skills/agent-project-move/SKILL.md#transfer-between-hosts) describes its command-line modes.

Each store normalizes its session identities, recorded cwds, parent relationships, physical files, and project ownership before selection. Missing or invalid IDs never participate in the relationship graph. Physical project ownership stays separate from a visited cwd. A selected session owns its transcript and its same-stem artifact subtree. Claude retirement leaves project memory, configuration, and prompt history in place. Other shared project metadata is removed only after its remaining references are accounted for, using exact owners during retirement.

## Actions

Stores return action records without writing. File edits read current content at apply time and replace it atomically, preserving mtime. Binary files are never edited.

Path columns use set-based `UPDATE` statements, covering rows written between plan and apply. They match with `substr`, because `LIKE` folds case and treats `_` and `%` as wildcards.

## Apply order

The executor uses this order:

1. **Derived statements**, which delete data that a source rewrite invalidates. They run first because a source write ends their selection, so an interrupted apply still converges on the rerun.
2. **Per assistant, the row actions that must precede files**, such as retirement's row deletes, so a failure leaves that assistant's files or rows for the rerun.
3. **Per assistant, file actions**, then the rest of that assistant's statements.

Codex retirement turns on `PRAGMA foreign_keys` so the schema's cascades delete child rows. Planning opens every database read-only.

## Transfer

Each file descriptor records its exported source in `origin_path`. This field is provenance metadata and does not control import destinations. Older bundles may omit it.

`import <dir>` plans the merge:

- Path mapping changes only incoming fields and JSON path tokens. Bundle locations, provenance, IDs, timestamps, and outside-root paths retain their source values. Existing local state is only read for collision checks.
- Directories are encoded with the target's own rules and `HOME`, and carried `rollout_path` values point at the copied files.
- A row is inserted unless its unique key already exists. Every other constraint stays fatal, and a failing row aborts that database's whole load.
- Existing session IDs are checked against their transcripts before skipping copies, including decoded compressed Codex rollouts and OMP IDs from session headers. A differing transcript aborts before writing. Dependent file history and Codex parent edges are reconciled even when the session already exists.
- A repeated import requires identical transcript content after the import's explicit file mapping. Rewritten paths count as a content difference, so reconcile or re-export moved sessions before importing them again.
- A carried OMP header's path-valued `parentSession` is mapped to the known imported parent file after any explicit incoming-path mapping. Other header and message bytes stay unchanged, and external parent identities remain opaque.
- Each carried table is checked at plan time: the import aborts before writing when the target lacks a carried column, or requires a not-null column without a default that the bundle does not fill.
- Codex carries available `project_roots` rows with selected projects. Targeted imports map those paths and reject an existing project ID whose ordered root paths differ. Project metadata and logical agent identities stay unchanged.

A bundle carries no Codex history projection, because rewriting the rollout invalidates its byte offsets.

## Directory merges

See [Project merges](../../skills/agent-project-move/SKILL.md#project-merges) for directory merges and collision handling.

## Safety

Rewritten transcripts no longer name the subpaths that selected their directories, so a file-phase failure requires recovery before replanning. SQL-phase failures can be replanned directly. Follow [Concurrent sessions](../../skills/agent-project-move/SKILL.md#concurrent-sessions) and [Restore](../../skills/agent-project-move/SKILL.md#restore) for recovery.
