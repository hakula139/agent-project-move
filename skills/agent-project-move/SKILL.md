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

Nushell 0.116 or later, `sqlite3`, `ripgrep`, `zstd`, and GNU coreutils must be on `PATH`. A Nix install supplies all of them through the package wrapper, while a plain install reads the user's own `PATH`. If `agent-project-move` is not on `PATH`, run `nix run github:hakula139/agent-project-move -- <args>` or tell the user to install it.

## Survey

1. Run `agent-project-move scan` on the host. It lists each recorded path with its session count, last use, whether the directory exists, and a `suggested` target for a missing path. Run it again with `--assistant` to narrow the output. Assistant names are a comma-separated list: `claude`, `codex`, `opencode`, `omp`.
2. For each missing path without a suggestion, look for a checkout with the same basename under the old parent and the usual source roots (`~/src`, `~/work`, `~/projects`). Ask the user when you find none or several. When two candidates share a name, `git -C <candidate> rev-list --max-parents=0 HEAD` tells clones of one repository from unrelated projects. Use GitHub or GitLab when no local checkout remains.
3. Present the old-to-new mapping, the suggested target of each missing path, and the paths that pruning would delete. Wait for the user to confirm all three before any write.

When the user names both paths, check that `scan` lists `<old>`, show the move plan, and offer pruning as a separate confirmation.

## Concurrent sessions

Moves and prunes rewrite state in place. Close sessions working in the moved or pruned paths before applying.

Your own session counts. When your working directory is under `<old>` or `<new>`, or the plan edits a shared document such as `~/.claude.json`, give the user the exact `--apply` command to run in a terminal after they exit the assistant.

If the run aborts, read the error and close the session working in that path. A run that failed in its SQL phase, usually because a database stayed busy, recovers from a plain rerun: it re-plans from the current state, so completed actions are skipped. A failure while writing files leaves rewritten transcripts that no longer name the subpaths that selected their directories, so restore from the run's backup first and then rerun.

## Project merges

When a Claude project directory lands on an existing one, the unique transcripts from both sides are kept, and `sessions-index.json` is deleted as stale derived data. If the destination already has a `memory/` directory, the source's whole memory directory is staged under `memory/incoming/<source-encoded-name>/`, listed as a rename, and left for the user to consolidate by hand. Otherwise the source memory moves in directly, with identical duplicates dropped. OMP memory collisions keep the destination file and delete the source copy. Memory content is never merged by the script.

## Move

1. Move local directories first with the file manager or `mv`, so the recorded path is the only stale reference.

2. Dry-run the state move, show the plan, and apply it after confirmation. Prefix matching is an exact, case-sensitive string test on `<old>` or `<old>/`, so a sibling such as `<old>-bar` is untouched even on a case-insensitive filesystem. A move whose paths differ only in case is refused, and a destination that does not exist draws a warning because a later prune would delete the moved state. See [Project merges](#project-merges) for what happens when a destination exists.

   ```bash
   agent-project-move move ~/src/app ~/work/app
   agent-project-move move ~/src/app ~/work/app --apply
   ```

   When only part of a tree changes, move the diverging child first. If `~/src/app` moves to `~/work/app` but its `assets` subdirectory moves to `~/media/assets`, run `move ~/src/app/assets ~/media/assets` and then `move ~/src/app ~/work/app`. Reversed, the parent move carries `assets` to `~/work/app/assets`.

3. Move each path that `scan` suggests before pruning, since prune deletes every recorded path that does not exist on disk. A suggestion follows a repository that moved, and stays empty when no unique target exists. Confirm each suggestion, then dry-run and apply its move.

   ```bash
   agent-project-move move ~/.codex/worktrees/abc/app ~/src/app
   agent-project-move move ~/.codex/worktrees/abc/app ~/src/app --apply
   ```

   Two worktrees of one repository merge into it in either order, and a rerun reports `No changes.`.

4. Consolidate each destination project whose `memory/incoming/` directory exists, by hand, before the next prune.

## Transfer between hosts

1. On the source host, write the state recorded for `<old>` as a bundle in a private directory. This only reads state.

   ```bash
   agent-project-move export ~/src/app ~/agent-project-move-bundle
   ```

2. Copy the bundle to the target host over ssh, for example with `rsync -a ~/agent-project-move-bundle <target>:~/`, then run the import there. It copies the files and rows to where the target's assistant keeps `<old>`, unchanged, so conversations arrive with their sessions and still name the old path. A store whose sessions the target already holds is left alone, memory included, so rerunning an import after the move changes nothing. Codex trust settings are not carried, so the target asks for trust once on the first resume. Codex rebuilds a thread's history projection on its first resume, after `codex unarchive` for an archived thread, so an imported Codex transcript preview stays empty until then.

   ```bash
   agent-project-move import ~/agent-project-move-bundle
   agent-project-move import ~/agent-project-move-bundle --apply
   ```

3. On the target host, run a normal move from `<old>` to the project's path there, when that path differs, so the imported state names the target's directory.

4. On the target host, consolidate each destination project whose `memory/incoming/` directory exists, by hand.

5. Delete the bundle on both hosts. The bundle holds transcripts, so it should not stay in a shared directory.

If you are retiring the source copy, delete its directory there once the target lists the sessions, then prune the source host.

## Prune

Run a dry-run `prune` only after every move and cross-host transfer. Apply it once the plan names only abandoned sessions.

```bash
agent-project-move prune
agent-project-move prune --keep ~/archive,/tmp/scratch
agent-project-move prune --apply
```

`--keep` takes comma-separated path prefixes and leaves every missing path that equals one or falls under one. The dry run lists the excluded paths. Paths under an unmounted `/Volumes/<name>`, `/mnt/<name>`, `/media/<user>/<name>`, or `/run/media/<user>/<name>` stay, so a detached disk is not mistaken for a deleted project, while any other drive or network share should be mounted before pruning or passed to `--keep`.

## Restore

Set `BACKUP` to the directory the apply printed after `Backed up to`. It mirrors absolute paths and holds a `manifest.json` listing every action, including the destination of each rename as `to`.

1. Exit the four assistants so nothing writes during the restore.

2. Reverse every `rename` and `rmdir` in reverse manifest order, moving each renamed file or directory from `to` back to `path` and recreating each directory removed by `rmdir`.

3. For each database in the manifest, restore its backup with `sqlite3 "$BACKUP/<path>" ".backup '<path>'"`.

4. Copy the backed-up files and directories back to their original paths, skipping the databases that step 3 restored. The backup mirrors absolute paths, so a file at `$BACKUP/home/u/.claude.json` returns to `/home/u/.claude.json`.

   ```bash
   cp -a "$BACKUP/home/u/.claude.json" /home/u/.claude.json
   ```

5. Delete files that the run created by importing a bundle, using the manifest's `copy` actions and their `to` path.

6. Run `agent-project-move scan` and confirm the restored paths are listed.

## Verify

- Run `agent-project-move scan` again and confirm the moved paths appear under their new location.
- Ask the user to open the new directory and check `/resume` in Claude Code, `codex resume` in Codex, the session list in OpenCode, and `/resume` in OMP.
- Keep the backup until the next session opens the moved project successfully.
