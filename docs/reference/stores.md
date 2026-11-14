# Assistant stores

Each store module reads one assistant's local state, plans its changes, and returns actions without writing. This page records where that state lives and which fields a move rewrites. The invariants behind the rewrites are in [Design](design.md).

These formats are the ones the modules read, and a release of any assistant can change them, so check a claim against a run, and record the version you ran in the README's [Tested with](../../README.md#tested-with) table.

## Claude Code

Root: `$CLAUDE_CONFIG_DIR`, defaulting to `~/.claude`. The global document is `$CLAUDE_CONFIG_DIR/.claude.json`, or `~/.claude.json` when the variable is unset.

| State                             | A move rewrites                                                                     |
| --------------------------------- | ----------------------------------------------------------------------------------- |
| `projects/<encoded-cwd>/`         | Renames or merges the directory when its name encodes `<old>` or a path under it    |
| Top-level `*.jsonl`               | Every `cwd` a transcript records, as a JSON string token                            |
| `history.jsonl`                   | `project`                                                                           |
| `$CLAUDE_CONFIG_DIR/.claude.json` | `projects` keys and `githubRepoPaths`, where an existing entry for the new key wins |
| `file-history/<session>/`         | Nothing, because it is keyed by session id and travels with an export instead       |

A directory name encodes a path by replacing each UTF-16 code unit outside `[a-zA-Z0-9]` with one `-`, truncating to 200 characters, and appending `-` plus a base36 hash of the whole path when it overflows. A surrogate pair becomes two dashes.

A session that changed directories is attributed to every `cwd` its transcript records.

Selective exports and retirements use session filenames as identities and follow subagent transcripts under the owning session's directory. A child-only selection keeps the parent transcript and its other files. The selected IDs also carry their `file-history/` directories. Retirement invalidates `sessions-index.json` and keeps project configuration and memory while another transcript still owns the physical project directory.

Merges, including memory staging, follow [Design](design.md#merges-and-memory-staging).

## Codex

Root: `$CODEX_HOME`, defaulting to `~/.codex`. The state database is the highest-numbered `state_<N>.sqlite` that has a `threads` table.

Codex asks for project trust when needed after a move or import.

| State                                | A move rewrites                                                                               |
| ------------------------------------ | --------------------------------------------------------------------------------------------- |
| `threads.cwd`                        | A path column                                                                                 |
| `threads.sandbox_policy`             | Path values inside the JSON                                                                   |
| `sessions/` and `archived_sessions/` | Every path value in a rollout, including compressed `<rollout>.zst` files read through `zstd` |
| `thread_history_<N>.sqlite`          | Deletes projections of threads whose rollouts are rewritten                                   |

A move deletes each rewritten rollout's history projection, with `thread_history_projection_state` first so its trigger clears `thread_realtime_items`. Codex rebuilds it on resume, after `codex unarchive` for an archived thread. Reading a thread or running `codex unarchive` does not rebuild it, so the transcript preview stays empty until resume. Threads without a rewritten rollout keep their rows.

Desktop workspace state in `.codex-global-state.json` stays unchanged. Update its paths separately when needed.

Selection follows `thread_spawn_edges` and attached parent identities toward descendants. Export carries incoming spawn edges for selected children, preserving an external parent's identity without selecting that parent. Retirement deletes selected edges, threads, rollouts, and history projections, and removes a project row only when no thread still references it.

Export carries `project_roots` when the state database has that table. An import with `--target` maps incoming `threads.cwd`, JSON paths in `sandbox_policy`, and `project_roots.path`. Rollout paths follow the actual copied files. Project metadata and logical `agent_path` identities stay unchanged, and an existing project ID must have the same ordered root paths as the mapped incoming project.

## OMP

Root: `$PI_CODING_AGENT_DIR`, defaulting to `~/.omp/agent`. Session and archive directories use a home-relative encoding.

| State                                                | A move rewrites                               |
| ---------------------------------------------------- | --------------------------------------------- |
| `sessions/<encoded>/`, `archive/sessions/<encoded>/` | Every path value in a session or archive file |

Selection reads the `type: session` header, skipping an optional title slot. `parentSession` can identify a parent by ID or file path, and a session file owns its same-stem artifact directory. A selected child carries its own subtree and linked descendants, while adjacent files belonging to its parent remain in place. Retirement deletes only the selected transcripts and their owned artifacts.

An import matches an OMP session by its header ID. A known carried parent file path in `parentSession` maps to its actual destination, and an existing session's renamed file also determines where its owned artifacts land. OMP bundles carry no database rows. Re-export older bundles that carry memory or database state before importing.

OMP memory, `history.db`, and `agent.db` stay untouched during every operation. The skill can handle any needed auxiliary state separately.
