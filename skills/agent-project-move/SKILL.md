---
name: agent-project-move
description: >-
  Repair the project paths recorded by Claude Code, Codex, and OMP after a directory moves,
  transfer sessions between hosts, and retire selected session copies. Use when a project was
  moved or renamed and an assistant no longer lists its sessions under the new path, when memory
  or history still points at an old path, when a removed worktree leaves sessions stranded, when
  deleted directories leave stale state, or when moving work to another machine.
---

# Agent project move

`agent-project-move` rewrites the project paths stored by the three assistants. Planning is read-only and prints every action, while `--apply` backs state up under `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/<timestamp>-<pid>/`, then rewrites state in place. `move`, `import`, and `retire` accept `--no-backup` to skip that backup explicitly. Use it only with authorization to proceed without recovery copies. The dry run reports whether a backup will be created, and [Restore](#restore) requires a backup.

## Requirements

Wherever the procedures below name `agent-project-move`, run the absolute path that `command -v agent-project-move` prints. When the command is not on `PATH`, run the bundled script by its absolute path instead, as `nu --no-config-file <skill directory>/scripts/agent-project-move.nu`, and stay in your working directory so relative path arguments keep their meaning. Hand the user the same absolute form when they run an `--apply` command in a terminal, since their terminal's `PATH` can differ from yours.

A Nix install wraps the command with every tool it needs. The bundled script reads the user's own `PATH`, so before its first run check each tool and tell the user which package to install for their platform when a check fails:

| Tool          | Requirement             | Check                                                          |
| ------------- | ----------------------- | -------------------------------------------------------------- |
| Nushell       | 0.116 or later          | `nu --version`                                                 |
| SQLite        | `sqlite3` 3.33 or later | `sqlite3 --version`                                            |
| ripgrep       | Built with PCRE2        | `rg --pcre2-version`                                           |
| zstd          | Any version             | `zstd --version`                                               |
| find          | POSIX implementation    | `command -v find`                                              |
| cmp           | POSIX implementation    | `command -v cmp`                                               |
| GNU coreutils | Homebrew's on macOS     | `brew --prefix coreutils` on macOS, `stat --version` elsewhere |

On macOS the command puts Homebrew's GNU coreutils first on its own `PATH`, so the user's `PATH` can keep the BSD tools. Elsewhere, `stat --version` must report GNU coreutils. Native Windows is unsupported.

## Survey

1. Run `agent-project-move scan` on the host. It lists each recorded path with its session count, last use, and whether the directory exists. Run it again with `--assistant` to narrow the output. Assistant names are a comma-separated list: `claude`, `codex`, `omp`.
2. Determine where missing paths belong from the user's intent, local checkouts, and Git repository and worktree relationships. Investigate ambiguous candidates and ask the user when the evidence does not establish a target.
3. Present the old-to-new mappings and wait for the user to confirm them before any write.

When the user names both paths, check that `scan` lists `<old>` and show the move plan.

## Concurrent sessions

Moves and retirements rewrite state in place. Close sessions working in the affected paths before applying.

Your own session counts. When your working directory is under `<old>` or `<new>`, or the plan edits a shared document such as `~/.claude.json`, give the user the exact `--apply` command to run in a terminal after they exit the assistant.

If the run aborts, read the error and close the session working in that path. A run that failed in its SQL phase, usually because a database stayed busy, recovers from a plain rerun: it re-plans from the current state, so completed actions are skipped. A failure while writing files leaves rewritten transcripts that no longer name the subpaths that selected their directories, so restore from the run's backup first and then rerun. A run with `--no-backup` requires an independent recovery copy for that repair.

## Project merges

When Claude project directories merge, unique files are kept. Memory moves as ordinary directory content, and differing files at the same destination stop the move for review. Shared memory content is handled separately from session transfer.

## Move

1. Move local directories first with the file manager or `mv`, so the recorded path is the only stale reference.

2. Dry-run the state move, show the plan, and apply it after confirmation. Prefix matching is an exact, case-sensitive string test on `<old>` or `<old>/`, so a sibling such as `<old>-bar` is untouched even on a case-insensitive filesystem. A move whose paths differ only in case is refused, and a destination that does not exist draws a warning because sessions need it to resume. See [Project merges](#project-merges) for what happens when a destination exists.

   ```bash
   agent-project-move move ~/src/app ~/work/app
   agent-project-move move ~/src/app ~/work/app --apply
   ```

   When only part of a tree changes, move the diverging child first. If `~/src/app` moves to `~/work/app` but its `assets` subdirectory moves to `~/media/assets`, run `move ~/src/app/assets ~/media/assets` and then `move ~/src/app ~/work/app`. Reversed, the parent move carries `assets` to `~/work/app/assets`.

## Transfer between hosts

1. On the source host, write the state recorded for `<old>` as a bundle in a private directory. This only reads state.

   ```bash
   agent-project-move export ~/src/app ~/agent-project-move-bundle
   ```

   By default the export includes child paths. Use `--exact` to select sessions whose recorded cwd equals the path, or `--session-ids <id,id>` to select specific sessions under the path. The options are mutually exclusive. Linked descendants and each selected session's own artifact subtree travel with it. Selecting a child does not select its parent or siblings.

2. Copy the bundle to the target host over ssh, for example with `rsync -a ~/agent-project-move-bundle <target>:~/`, then run the import there. Add `--target` when the project path differs. It maps the exported root and its descendants, preserving suffixes, and leaves carried outside-root paths unchanged. Only incoming state is mapped, so existing local sessions stay unchanged. Omit the option to keep the original project paths. Existing session IDs require identical transcript content after mapping. Changed content aborts before writing, so reconcile or re-export those sessions before importing again. Missing dependent records still import. Codex rebuilds a thread's history projection on its first resume, after `codex unarchive` for an archived thread, so an imported Codex transcript preview stays empty until then.

   ```bash
   agent-project-move import ~/agent-project-move-bundle --target ~/work/app
   agent-project-move import ~/agent-project-move-bundle --target ~/work/app --apply
   ```

3. Delete the bundle on both hosts. The bundle holds transcripts, so it should not stay in a shared directory.

After verifying the destination sessions and their artifacts, use [Retire](#retire) to remove the selected source state. Use the same path, assistant list, and selection as the export.

## Retire

`retire` removes selected session state after explicit authorization. It requires either `--exact` or `--session-ids`, and follows the export's selection rules. Use IDs when sessions sharing a cwd belong to different projects or only some should be removed. Use `--exact` only when the whole cwd selection is intended. Claude project memory, global configuration, and prompt history stay in place. Other shared project metadata stays while another session references it. Investigate other orphaned state separately and use task-specific scripts when needed.

```bash
agent-project-move retire ~/src/app --exact
agent-project-move retire ~/src/app --session-ids session-a,session-b
agent-project-move retire ~/src/app --session-ids session-a,session-b --apply
```

Review the dry run and confirm the selected sessions before applying. `--apply` creates the normal backup. Add `--no-backup` only with explicit authorization to permanently discard these source copies after destination verification. No backup is created in that mode, so [Restore](#restore) cannot recover the retirement.

## Restore

Set `BACKUP` to the directory the apply printed after `Backed up to`. It mirrors absolute paths and holds a `manifest.json` listing every action, including the destination of each rename as `to`.

1. Exit the three assistants so nothing writes during the restore.

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
- Ask the user to open the new directory and check `/resume` in Claude Code, `codex resume` in Codex, and `/resume` in OMP.
- Keep the backup until the next session opens the moved project successfully.
