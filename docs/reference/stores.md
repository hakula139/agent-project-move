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

A prune deletes a directory only when every `cwd` it records lies under the pruned paths and no existing path encodes to its name.

Selective exports and retirements use session filenames as identities and follow subagent transcripts under the owning session's directory. A child-only selection keeps the parent transcript and its other files. The selected IDs also carry their `file-history/` directories. Retirement invalidates `sessions-index.json` and keeps project configuration and memory while another transcript still owns the physical project directory.

Merges, including memory staging, follow [Design](design.md#merges-and-memory-staging).

## Codex

Root: `$CODEX_HOME`, defaulting to `~/.codex`. The state database is the highest-numbered `state_<N>.sqlite` that has a `threads` table.

| State                                | A move rewrites                                                                               |
| ------------------------------------ | --------------------------------------------------------------------------------------------- |
| `threads.cwd`                        | A path column                                                                                 |
| `threads.sandbox_policy`             | Path values inside the JSON                                                                   |
| `sessions/` and `archived_sessions/` | Every path value in a rollout, including compressed `<rollout>.zst` files read through `zstd` |
| `.codex-global-state.json`           | Every path value                                                                              |
| `thread_history_<N>.sqlite`          | Projections of edited threads, rewritten or deleted by the rule below                         |
| `config.toml`                        | Trust blocks, where an existing new key wins                                                  |

A history projection is exact or absent. When both spellings of the path keep the byte length of their JSON-escaped form, the thread's rows stay and their `item_json` paths are rewritten. Otherwise the thread's projection rows are deleted, with `thread_history_projection_state` first so its trigger clears `thread_realtime_items`. Codex rebuilds the projection on the thread's first resume, after `codex unarchive` for an archived thread, so reads and the transcript preview show nothing until then. Threads without a rollout keep their rows.

A prune deletes the rollouts and `threads` rows with foreign keys on, then the removed threads' history projection rows explicitly, because that database has no cascades.

Selection follows `thread_spawn_edges` and attached parent identities toward descendants. Export carries incoming spawn edges for selected children, preserving an external parent's identity without selecting that parent. Retirement deletes selected edges, threads, rollouts, and history projections, and removes a project row only when no thread still references it.

## OMP

Root: `$PI_CODING_AGENT_DIR`, defaulting to `~/.omp/agent`. Session and archive directories use a home-relative encoding, and memory directories use an absolute encoding. Memory lives under `$XDG_STATE_HOME/omp/memories`, defaulting to `~/.local/state/omp/memories`.

| State                                                | A move rewrites                                                                  |
| ---------------------------------------------------- | -------------------------------------------------------------------------------- |
| `sessions/<encoded>/`, `archive/sessions/<encoded>/` | Every path value in a session or archive file                                    |
| `agent.db` `threads.cwd`                             | A path column                                                                    |
| `agent.db` `threads.rollout_path`                    | Mapped from the old session directory to the new one                             |
| `agent.db` `jobs.job_key`                            | `global:<path>`, where a colliding key keeps the destination row                 |
| `history.db` `history.cwd`                           | A path column                                                                    |
| `history.db` `session_recaps.cwd`                    | A path column                                                                    |
| Memory directories                                   | The directory is merged entry by entry, and the destination wins every collision |

A prune deletes a session or archive directory when every session it holds is under the pruned paths, and a memory directory unless another existing path encodes to the same name. Its statements delete `stage1_outputs` and thread-keyed `jobs` through a subquery on the removed threads, the removed sessions' `session_titles`, the `history` and `session_recaps` rows, and the `global:` jobs, then rebuild the external-content `history_fts` index.

Selection reads the `type: session` header, skipping an optional title slot. `parentSession` can identify a parent by ID or file path, and a session file owns its same-stem artifact directory. A selected child carries its own subtree and linked descendants, while adjacent files belonging to its parent remain in place. Memory uses physical project ownership and remains while another session references it.

An import matches an OMP session by its header ID and its database rows, so a session file with no database row still imports. Distinct nested files with the same basename retain their own rollout targets. A known carried parent file path in `parentSession` maps to its actual destination, and an existing session's renamed file also determines where its owned artifacts land. History without a session ID and global jobs remain path metadata in default exports and prune plans.
