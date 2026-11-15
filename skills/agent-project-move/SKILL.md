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

Planning is read-only. `move`, `import`, and `retire` write only with `--apply`, which first creates a private backup under `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/<timestamp>-<pid>/`. Use `--no-backup` only with explicit authorization to proceed without recovery copies. Backups and exported bundles contain sensitive session content.

## Requirements

Run the absolute path returned by `command -v agent-project-move`. If it is absent, use `nu --no-config-file <skill directory>/scripts/agent-project-move.nu` with the script's absolute path. Preserve the working directory so relative arguments keep their meaning. Give the user the same absolute command when handing execution to their terminal, whose `PATH` may differ.

Nix provides the runtime tools. Otherwise check for Nushell 0.116 or later, SQLite 3.33 or later, ripgrep with PCRE2, zstd, POSIX `find` and `cmp`, and GNU coreutils. On macOS the command uses Homebrew's GNU coreutils without changing the user's `PATH`. Native Windows is unsupported.

## Survey

Run `scan`, narrowing by `--assistant` when useful, and establish the intended path mappings or session selection from the user's request, local checkouts, and repository relationships. Ask about unresolved destinations or missing write authority. Review each dry run before applying already-authorized work. `--help` describes the available commands and selectors.

## Concurrent sessions

Close sessions writing affected state before applying. Your own session counts: when its cwd is under either move path, or the plan edits a shared document it uses, such as `~/.claude.json`, hand the user the exact apply command to run after exiting the assistant.

A SQL-phase failure can be replanned and rerun. After a file-phase failure, [restore](#restore) before replanning, because rewritten transcripts may no longer identify the directories still needing relocation. A run without a backup needs an independent recovery copy.

## Project merges

Claude project-directory merges keep unique files and move memory as ordinary directory content. Differing files at the same destination stop the move for review. Selected-session moves and session transfer leave shared project memory in place.

## Move

Move the project directory first, then preview the state repair:

```bash
agent-project-move move ~/src/app ~/work/app
agent-project-move move ~/src/app ~/work/app --apply
```

Paths match case-sensitively at `<old>` or `<old>/`. Case-only moves are refused. A missing destination draws a warning because sessions need it to resume. When a child moves outside its parent's destination, repair the child's mapping before the parent's.

Use `move <old> <new> --session-ids <id,id>` to move specific sessions recorded under `<old>` and their linked descendants, including descendants whose cwd is elsewhere. Ancestors and siblings stay in place. Only selected transcripts are rewritten, and their owned artifacts move when their physical project owner is under `<old>`. Shared project state stays in place.

## Transfer between hosts

1. Export the source path into a private bundle directory. Export reads the source store without changing it. Prefix selection includes child paths. `--exact` selects an equal cwd, while `--session-ids` selects specific sessions under the path. Linked descendants and owned artifacts follow each selected session, without selecting ancestors or siblings. OMP also carries referenced global blobs and their available aliases.
2. Copy the bundle to the destination and preview `import <bundle>`. Add `--target <path>` to map the exported root and its descendants in incoming state. Outside-root paths keep their values, except complete OMP blob paths map to the destination's local blob directory. Existing session IDs require identical transcript content after mapping. A collision stops the import before writing, so reconcile or re-export changed sessions.
3. Apply the import, then verify destination sessions and their artifacts in the assistant before retiring source copies or deleting bundles. Imported Codex previews remain empty until resume. Archived threads need `codex unarchive` before resume.

For missing OMP blobs, `export-blobs <ids-file> <bundle>` creates a blob-only bundle from the local pool, accepting one canonical lowercase SHA-256 ID per line. Establish the IDs from actual references, import normally, and verify native resolution on the destination.

## Retire

`retire <path>` requires either `--exact` or `--session-ids`. Obtain authority to remove the selected source copies, inspect the dry run, and apply after destination acceptance. IDs allow selecting only some sessions sharing a cwd.

Retirement removes selected transcripts and owned artifacts. Claude project memory, global configuration, and prompt history stay in place. Other shared project metadata stays while referenced. OMP's global blob pool stays intact. Handle any separately authorized auxiliary cleanup from evidence of ownership and remaining references.

## Restore

Use the directory printed after `Backed up to`. It mirrors absolute paths and contains an ordered `manifest.json`.

1. Close assistant writers.
2. Reverse `rename` and `rmdir` actions in reverse manifest order. Move each `to` back to `path` and recreate removed directories.
3. Restore each database through SQLite's `.backup` command from its mirrored backup path to its original path.
4. Copy other backed-up files and directories to their original paths, skipping databases already restored.
5. Remove files created by the import, listed by the manifest's `copy` actions and their `to` paths.
6. Run `scan` and check the restored paths.

## Verify

Check `scan`, then open the destination project and resume affected sessions in each assistant. Check transferred artifacts, including OMP blob resolution. Keep backups until a new session opens the migrated project successfully.
