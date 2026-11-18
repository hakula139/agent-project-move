# Assistant stores

See [Tested with](../../README.md#tested-with) for checked assistant versions, [Design](design.md) for shared constraints, and the [skill](../../skills/agent-project-move/SKILL.md) for procedures and selection rules.

## Claude Code

Root: `$CLAUDE_CONFIG_DIR`, defaulting to `~/.claude`. Project keys in `$CLAUDE_CONFIG_DIR/.claude.json`, or `~/.claude.json` when the variable is unset, help resolve physical project ownership and are only read.

A default move merges `projects/<encoded-cwd>/` directories owned under the source path and rewrites top-level and `<parent>/subagents/agent-*.jsonl` transcripts, including references in directories that stay in place. Subagent `.meta.json` sidecars supply nested `parentAgentId` links and travel with their transcripts. Selected moves relocate only selected transcripts, `.meta.json` sidecars, and same-stem artifact subtrees. See [project merges](../../skills/agent-project-move/SKILL.md#project-merges) for collisions.

Export carries `.meta.json` sidecars, same-stem artifacts, and `file-history/<session>/`. Local moves leave file history in place. Retirement leaves project directories, shared memory, global configuration, and prompt history intact.

## Codex

Root: `$CODEX_HOME`, defaulting to `~/.codex`. The active database is the highest-numbered `state_<N>.sqlite` containing `threads`.

Moves rewrite thread cwds, JSON sandbox paths, and rollouts in `sessions/` and `archived_sessions/`, including `.zst`. Rewritten rollouts lose their `thread_history_<N>.sqlite` projections until resume, after `codex unarchive` for archived threads. Previews remain empty until then.

Selection follows spawn relationships. Selected moves and exports require existing canonical rollout files, and selected moves preserve project metadata and spawn relationships. Export preserves incoming parent identities. Retirement removes project metadata only when unreferenced.

Export carries `project_roots` when available. Existing project IDs require identical ordered roots after mapping. Other project metadata and logical `agent_path` identities stay unchanged.

Desktop workspace state in `.codex-global-state.json` stays unchanged and may need a separate path update. Codex may request project trust after a move or import.

## OMP

Root: `$PI_CODING_AGENT_DIR`, defaulting to `~/.omp/agent`. Sessions live in home-relative encoded directories under `sessions/` and `archive/sessions/`.

The header supplies the ID and optional `parentSession` ID or file path. Each journal owns its same-stem artifact directory. Default moves update absolute parent references across journals. Selected moves update only selected journals and relocate their owned paths, preserving unselected parent identities. Imports map known parent files to their destinations and preserve external identities. Existing filenames determine imported artifact destinations.

The global `blobs/` pool holds canonical SHA-256 files for `blob:sha256:<hash>` locators and `<hash>.<extension>` aliases for file viewing. Export carries referenced canonical files and available aliases, validating their hashes. Import rejects differing bytes and maps complete blob path tokens to the local pool. Native locators and prose references retain their spelling.

Retirement leaves the blob pool intact. OMP memory, `history.db`, and `agent.db` stay untouched in every operation. Re-export older bundles containing memory or database state before importing them.
