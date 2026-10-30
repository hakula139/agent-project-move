---
name: agent-project-move
description: >-
  Repair the project paths recorded by Claude Code, Codex, OpenCode, and OMP after a directory
  moves, transfer sessions between hosts, and prune state whose directory is gone. Use when a
  project was moved or renamed and an assistant no longer lists its sessions under the new path,
  when memory or history still points at an old path, when a removed worktree leaves sessions
  stranded, when deleted directories leave stale state, or when moving work to another machine.
---

# Agent project move

`agent-project-move` rewrites the project paths stored by the four assistants. Planning is read-only and prints every action, while `--apply` backs state up under `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/<timestamp>-<pid>/`, then rewrites state in place.

## Requirements

Nushell 0.116 or later, `sqlite3`, and `ripgrep` must be on `PATH`, and compressed Codex rollouts also need `zstd`. A Nix install supplies all of them through the package wrapper, while a plain install reads the user's own `PATH` and needs GNU coreutils. A missing tool fails the run with a command-not-found error naming it, so check `nu --version`, `sqlite3 --version`, and `rg --version` before retrying.

## Survey

1. Run `agent-project-move scan` on the host. It lists each recorded path with its session count, last use, and a `suggested` target for a missing path. Run it again with `--assistant` to narrow the output. Assistant names are a comma-separated list: `claude`, `codex`, `opencode`, `omp`.

2. For each missing path, find where the project lives now. Compare the repository's remote and its root commit (`git -C <candidate> rev-list --max-parents=0 HEAD`) with sibling checkouts, since a rename can change the basename. Use the forge when no local checkout remains.

3. Present the old-to-new mapping, the suggested target of each missing path, and the paths that pruning would delete. Wait for the user to confirm all three before any write.

## Concurrent sessions

Moves and prunes rewrite state in place. A rename keeps the inode, but an edit replaces its file through a temporary file, so a running session keeps writing to the old inode and those writes are lost. Close sessions working in the moved or pruned paths before applying, since a running assistant may also rewrite a shared document such as `~/.claude.json` at the same moment.

If the run aborts, read the error and close the session working in that path. A run that failed in its SQL phase, usually because a database stayed busy, recovers from a plain rerun: it re-plans from the current state, so completed actions are skipped and the remainder is applied. A prune deletes one assistant's rows right before that assistant's files, so a failure leaves its files or rows for the rerun and leaves later assistants untouched. A failure while writing files leaves rewritten transcripts that no longer name the worktree subpaths that selected their directories, so restore from the run's backup first and then rerun.

## Project merges

When a Claude project directory lands on an existing one, the unique transcripts from both sides are kept, and `sessions-index.json` is deleted as stale derived data. If the destination already has a `memory/` directory, the source's whole memory directory is staged under `memory/incoming/<source-encoded-name>/`, listed as a rename, and left for the user to consolidate, by hand or with a memory-consolidation skill. Otherwise the source memory moves in directly, with identical duplicates dropped. OMP memory collisions keep the destination file and delete the source copy. Memory content is never merged by the script. A merge removes the source directory once its entries have moved.

## Move

1. Move local directories first with the file manager or `mv`, so the recorded path is the only stale reference.

2. Dry-run the state move, then apply the reviewed plan. Prefix matching is an exact, case-sensitive string test on `<old>` or `<old>/`, so a sibling such as `<old>-bar` is untouched even on a case-insensitive filesystem. A move whose paths differ only in case is refused. See Project merges for what happens when a destination exists.

   ```bash
   agent-project-move move <old> <new>
   agent-project-move move <old> <new> --apply
   ```

   Split a move when only part of a tree changes, and move the diverging child first. To keep the app checkout while its `assets` directory moves elsewhere, run `move <root>/app/assets <root>/media/assets` and then `move <root>/app <root>/work/app`. Reversed, the parent move would carry `assets` to `<root>/work/app/assets`.

3. Move each path that `scan` suggests before pruning, since prune deletes every recorded path that does not exist on disk. A suggestion follows a repo that moved, such as `/home/me/src/my-app__worktrees/<name>` to `/home/me/work/my-app`, and stays empty when no unique target exists. Suggestions come from recorded project paths that still exist and contain a repository, plus any existing ancestor of a missing path that does. Confirm each suggestion, then dry-run and apply its move.

   ```bash
   agent-project-move move ~/.codex/worktrees/abc/my-repo ~/src/my-repo --apply
   ```

   Two worktrees of one repo merge into it in either order, and a rerun reports `No changes.`.

4. Consolidate each destination project whose `memory/incoming/` directory exists, by hand or with a memory-consolidation skill, before the next prune.

## Transfer between hosts

1. On the source host, write the state recorded for `<old>` as a bundle. This only reads state.

   ```bash
   agent-project-move export <old> /tmp/agent-project-move-bundle
   ```

2. Copy the bundle to the target host over ssh, for example with `rsync -a /tmp/agent-project-move-bundle <target>:/tmp/`, then run the import there. It copies the files and rows to where the target's assistant keeps `<old>`, unchanged, so conversations arrive with their sessions and still name the old path. A store whose sessions the target already holds is left alone, memory included, so rerunning an import after the move changes nothing. An existing target file with identical content counts as done, while different content aborts the plan. Codex trust settings are not carried, so the target asks for trust once on the first resume. Codex rebuilds a thread's history projection on its first resume, after `codex unarchive` for an archived thread, so an imported Codex transcript preview stays empty until then.

   ```bash
   agent-project-move import /tmp/agent-project-move-bundle
   agent-project-move import /tmp/agent-project-move-bundle --apply
   ```

3. On the target host, run a normal move from `<old>` to the project's path there, when that path differs, so the imported state names the target's directory.

4. On the target host, consolidate each destination project whose `memory/incoming/` directory exists, by hand or with a memory-consolidation skill.

## Prune

Run a dry-run `prune` only after every move and cross-host transfer, and prune a transfer's source host only after the target host reports its import. Apply it once the plan names only abandoned sessions.

```bash
agent-project-move prune
agent-project-move prune --keep /Users/me/Documents/Codex,/tmp/scratch
agent-project-move prune --apply
```

`--keep` takes comma-separated path prefixes and leaves every missing path that equals one or falls under one. The dry run lists the excluded paths.

## Restore

The backup directory is mode 0700, mirrors absolute paths, and holds a `manifest.json` listing every action, including the destination of each rename as `to`.

1. Exit the four assistants so nothing writes during the restore.
2. Reverse every `rename` and `rmdir` in reverse manifest order, moving each renamed file or directory from `to` back to `path` and recreating each directory removed by `rmdir`. A merge places its `rmdir` after the renames that emptied the directory, so reversing the order recreates the directory before its entries return.
3. For each database in the manifest, restore its backup with `sqlite3 <backup>/<path> ".backup '<path>'"`.
4. Copy the backed-up files and directories back to their original paths, skipping the databases that step 3 restored. The backup mirrors absolute paths, so a file at `<backup>/home/u/src/app/notes.md` returns to `/home/u/src/app/notes.md`.

   ```bash
   cp -a "$BACKUP/home/u/src/app/notes.md" /home/u/src/app/notes.md
   ```

   An `edit` backup holds the file as it was before the run, so copying it back also restores that file's earlier mtime.

5. Delete files that the run created by importing a bundle, using the manifest's `copy` actions and their `to` path.
6. Run `agent-project-move scan` and confirm the restored paths are listed.

## Verify

- Run `agent-project-move scan` again and confirm the moved paths appear under their new location.
- Confirm the moved sessions are listed under the new directory in the assistant.
- Keep the backup until the next session opens the moved project successfully.
