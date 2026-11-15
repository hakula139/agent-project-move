# Assistant stores

Store adapters read local state and return planned actions without writing. These formats can change with assistant releases. See [Tested with](../../README.md#tested-with) for checked versions and [Design](design.md) for shared rewrite constraints.

## Claude Code

Root: `$CLAUDE_CONFIG_DIR`, defaulting to `~/.claude`. Project keys in `$CLAUDE_CONFIG_DIR/.claude.json`, or `~/.claude.json` when the variable is unset, help resolve physical project ownership and are only read.

A `projects/<encoded-cwd>/` directory moves when its name encodes the source path or a descendant. Recorded cwds can identify visited projects without identifying that physical owner. A move rewrites top-level session transcripts and `<parent>/subagents/agent-*.jsonl` transcripts, including references in directories that stay in place. [Project merges](../../skills/agent-project-move/SKILL.md#project-merges) handle destination collisions.

Session filenames identify sessions. Selected transcripts travel with their same-stem artifact subtrees and `file-history/<session>/` directories. A child-only selection leaves its parent's other files in place. Other artifact bytes stay unchanged. Retirement leaves project directories, shared memory, global configuration, and prompt history in place.

## Codex

Root: `$CODEX_HOME`, defaulting to `~/.codex`. The active database is the highest-numbered `state_<N>.sqlite` containing `threads`.

Moves rewrite thread cwds, JSON sandbox paths, and rollout paths in `sessions/` and `archived_sessions/`, including compressed `.zst` rollouts. Rewritten rollouts lose their derived `thread_history_<N>.sqlite` projections. Codex rebuilds those only on resume, after `codex unarchive` for archived threads. Until then, transcript previews remain empty.

Selection follows spawn relationships toward descendants. Export preserves selected children's incoming parent identities. Retirement removes selected thread state and removes project metadata only when unreferenced.

Selected-session moves restrict thread and rollout rewrites to the selected closure and require every selected canonical rollout to be readable. Project metadata and spawn relationships stay unchanged.

Export carries available `project_roots`. Targeted imports map incoming cwd, sandbox paths, and project roots, while rollout paths follow the copied files. Existing project IDs must have identical ordered root paths after mapping. Project metadata and logical `agent_path` identities stay unchanged.

Desktop workspace state in `.codex-global-state.json` stays unchanged and may need a separate path update. Codex may request project trust after a move or import.

## OMP

Root: `$PI_CODING_AGENT_DIR`, defaulting to `~/.omp/agent`. Sessions live in home-relative encoded directories under `sessions/` and `archive/sessions/`.

The session header supplies the ID and optional `parentSession`, which can be an ID or a file path. Each session file owns its same-stem artifact directory. Moves update absolute parent references even in sessions whose cwd stays elsewhere. Imports use known parent files' actual destinations and preserve external parent identities. An existing session's filename determines its imported artifact destination.

Selected-session moves rewrite parent references only in selected journals and relocate their owned paths without merging whole project directories.

The global `blobs/` pool stores canonical SHA-256 files without extensions. Native `blob:sha256:<hash>` locators use those files, while `<hash>.<extension>` aliases support file viewing. Export finds native locators, absolute blob paths, file URIs, and existing alias filenames in journal strings, including historical prose. It carries referenced canonical files and available aliases unchanged, validating their bytes against the canonical hash. Import rejects differing destination bytes and maps complete incoming blob path tokens to the local pool. Native locators and prose references retain their spelling.

Retirement removes selected session files and owned artifacts, leaving the global blob pool intact. OMP memory, `history.db`, and `agent.db` stay untouched in every operation. Bundles carry no database rows. Re-export older bundles containing memory or database state before importing them.
