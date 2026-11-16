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

Resolve `agent-project-move` to an absolute command, or use `nu --no-config-file <skill directory>/scripts/agent-project-move.nu` with the script's absolute path when absent. Preserve the working directory for relative arguments. Give the user the same absolute command, because their terminal's `PATH` may differ.

Nix provides the runtime tools. Otherwise check for Nushell 0.116 or later, SQLite 3.33 or later, ripgrep with PCRE2, zstd, POSIX `find` and `cmp`, and GNU coreutils. On macOS the command uses Homebrew's GNU coreutils without changing the user's `PATH`. Native Windows is unsupported.

## Survey

Run `scan` and establish path mappings or session selection from the user's request and local repositories. Ask about unresolved destinations or missing write authority. Review each dry run before applying already-authorized work. `--help` describes commands and options.

Selection includes child paths by default. `--session-ids <id,id>` selects sessions recorded under the given root and their linked descendants, including descendants whose cwd is elsewhere. Ancestors and siblings stay in place. Export and retirement also accept `--exact` to select equal-cwd sessions and their linked descendants.

## Concurrent sessions

Close sessions writing affected state before applying. Your own session counts: when its cwd is under either move path, or the plan rewrites its transcript, hand the user the exact apply command to run after exiting the assistant.

A SQL-phase failure can be replanned and rerun. After a file-phase failure, [restore](#restore) before replanning, because rewritten transcripts may no longer identify the directories still needing relocation. A run without a backup needs an independent recovery copy.

## Project merges

Claude project-directory merges keep unique files and move memory as ordinary directory content. Differing files at the same destination stop the move for review. Selected-session moves and session transfer leave shared project memory in place.

## Move

Move the project directory first, then preview `move <old> <new>` and apply with `--apply`.

Paths match case-sensitively at `<old>` or `<old>/`. Case-only moves are refused. A missing destination draws a warning because sessions need it to resume. When a child moves outside its parent's destination, repair the child's mapping before the parent's.

With `--session-ids`, only sessions recorded under `<old>` and their linked descendants are selected. Selected transcripts are rewritten, their owned artifacts move when their physical project owner is under `<old>`, and shared project state stays in place.

## Transfer between hosts

1. Export the selection into a private bundle directory. Export leaves the source unchanged and carries owned artifacts, including referenced OMP blobs and available aliases.
2. Copy the bundle to the destination and preview `import <bundle>`. Use `--target <path>` to map incoming paths under the exported root. Complete OMP blob paths map to the local pool. Existing session IDs require identical transcript content after mapping. Reconcile collisions or re-export changed sessions before applying.
3. Apply and [verify](#verify) before retiring source copies or deleting bundles. Codex previews remain empty until resume. Archived threads need `codex unarchive` first.

For missing OMP blobs, `export-blobs <ids-file> <bundle>` creates a blob-only bundle from the local pool, accepting one canonical lowercase SHA-256 ID per line. Establish the IDs from actual references, import normally, and verify native resolution on the destination.

## Retire

`retire <path>` requires either `--exact` or `--session-ids`. Obtain authority to remove selected source copies and apply after destination acceptance.

Retirement removes selected transcripts and owned artifacts. Claude project memory, global configuration, prompt history, and OMP's blob pool stay in place. Other shared project metadata stays while referenced. Separate cleanup requires evidence of ownership and remaining references.

## Restore

Use the directory printed after `Backed up to`. It mirrors absolute paths and contains an ordered `manifest.json`.

1. Close assistant writers.
2. Reverse `rename` and `rmdir` actions in reverse manifest order, skipping entries that did not run. Move each `to` back to `path` and recreate removed directories.
3. Restore each database listed in `sql` actions through SQLite's `.backup` command from its mirrored backup path to its original path.
4. Copy other backed-up files and directories (`edit` and `delete` actions) to their original paths, skipping databases already restored.
5. Remove files created by an import, listed by the manifest's `copy` actions and their `to` paths.
6. Run `scan` and check the restored paths.

## Verify

Check `scan`, then open the destination project and resume affected sessions in each assistant. Check transferred artifacts, including OMP blob resolution. Keep backups until a new session opens the migrated project successfully.
