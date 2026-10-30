# Assistant stores

Each store module reads one assistant's local state, plans its changes, and returns actions without writing. This page records where that state lives and which fields a move rewrites. The invariants behind the rewrites are in [Design](design.md).

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

Selection reads every `cwd` a top-level transcript records in one `rg` pass, so a session that changed directories is attributed to each path it used. A directory counts as owned when a recorded `cwd` whose encoding equals its name lies under `<old>`.

A prune deletes a directory only when every `cwd` it records lies under the pruned paths and no existing path encodes to its name. `sessions-index.json` is stale derived data and is deleted when a project directory merges.

When a merge lands on a destination that already has `memory/`, the source memory moves to `<destination>/memory/incoming/<source-encoded-name>/` unchanged. Otherwise it moves in directly, dropping identical duplicates. Memory content is never merged.

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

A prune deletes the rollouts and `threads` rows with foreign keys on, then the removed threads' history projection rows explicitly, because that database has no cascades. An export carries no projection rows.

## OpenCode

Database: `$XDG_DATA_HOME/opencode/opencode.db`, defaulting to `~/.local/share/opencode/opencode.db`.

| State                         | A move rewrites                                                         |
| ----------------------------- | ----------------------------------------------------------------------- |
| `session.directory`           | A path column                                                           |
| `workspace.directory`         | A path column                                                           |
| `project.worktree`            | A path column, while `project.id` stays                                 |
| `project.sandboxes`           | Path values inside the JSON                                             |
| `project_directory.directory` | A path column, where a colliding key keeps the destination row          |
| `event.data`                  | Path values inside the JSON, including each event's `info.directory`    |
| `snapshot/<project>/<sha1>`   | Renamed with the path it hashes, so `/undo` keeps working across a move |

A prune runs with foreign keys on. It deletes `event_sequence` rows for the removed sessions, which cascades their events, then the `session` rows, which cascade messages, parts, the `session_*` tables, and todos, then workspaces and `project_directory` rows, and finally a project whose worktree is under the pruned paths when no session remains. The `global` project is never matched, because its worktree is `/`.

## OMP

Root: `$PI_CODING_AGENT_DIR`, defaulting to `~/.omp/agent`. Session and archive directories use a home-relative encoding, and memory directories use an absolute encoding. Memory lives under `$XDG_STATE_HOME/omp/memories`, defaulting to `~/.local/state/omp/memories`.

| State                                                | A move rewrites                                                                  |
| ---------------------------------------------------- | -------------------------------------------------------------------------------- |
| `sessions/<encoded>/`, `archive/sessions/<encoded>/` | Every path value in a session or archive file, found by one `rg -m1` scan        |
| `agent.db` `threads.cwd`                             | A path column                                                                    |
| `agent.db` `threads.rollout_path`                    | Mapped from the old session directory to the new one                             |
| `agent.db` `jobs.job_key`                            | `global:<path>`, where a colliding key keeps the destination row                 |
| `history.db` `history.cwd`                           | A path column                                                                    |
| `history.db` `session_recaps.cwd`                    | A path column                                                                    |
| Memory directories                                   | The directory is merged entry by entry, and the destination wins every collision |

A prune deletes a session or archive directory when every session it holds is under the pruned paths, and a memory directory unless another existing path encodes to the same name. Its statements delete `stage1_outputs` and thread-keyed `jobs` through a subquery on the removed threads, the removed sessions' `session_titles`, the `history` and `session_recaps` rows, and the `global:` jobs, then rebuild the external-content `history_fts` index.

An import matches an OMP session by its rows and by its session files under any session directory, so a session file with no database row still imports.
