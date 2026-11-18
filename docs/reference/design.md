# Design

This page records shared adapter and executor constraints. See the [skill](../../skills/agent-project-move/SKILL.md) for procedures and [Assistant stores](stores.md) for assistant-specific ownership and formats.

## Path identity

A recorded cwd selects sessions independently of physical project ownership, which determines directory relocation and exported artifacts.

Rewrites match paths case-sensitively and use the destination's native spelling. JSON rewrites match path tokens in keys or values, including file URIs. Unrelated bytes and binary artifacts stay unchanged.

Import destinations follow the target store's layout and actual copied files. A bundle's `origin_path` records provenance for incoming path mapping and never chooses a destination root.

## Derived state and interruption

File replacement preserves mtime. Each SQL action is transactional, while the complete operation spans databases and files.

Derived data is invalidated before source rewrites erase its selection evidence. Row changes needed to retain a recoverable selection precede file changes. See the skill for [failure recovery](../../skills/agent-project-move/SKILL.md#concurrent-sessions).

## Import collisions

Only incoming state receives import path mappings. Existing session IDs require identical mapped transcript content, comparing rollouts after decompression. Dependent artifacts are reconciled even when the session exists.

Database rows with existing unique keys are skipped. Other constraint failures abort that database's load. Planning rejects carried columns absent from the destination schema and missing required destination columns without defaults.
