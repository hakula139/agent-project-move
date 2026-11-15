# Design

This page records shared adapter and executor constraints. See the [skill](../../skills/agent-project-move/SKILL.md) for procedures and [Assistant stores](stores.md) for assistant-specific ownership and formats.

## Path identity

Planning reads current state. A recorded cwd can select a transcript even when it differs from that transcript's physical project owner. Store ownership determines which directories move and which artifacts travel with an export.

Path matching is case-sensitive at the old root or its slash boundary. Rewrites preserve unrelated bytes and use the destination's native path spelling. JSON path tokens can occur as keys or values, including file URIs, so rewriting is independent of record field names. Binary artifacts stay unchanged.

Import destinations follow the target store's layout and actual copied files. A bundle's `origin_path` records provenance for incoming path mapping and never chooses a destination root.

## Derived state and interruption

Adapters plan without writing. File replacement preserves mtime. Each SQL action is transactional, while the complete operation spans databases and files.

Derived data is invalidated before rewriting its source, because the rewrite can erase the evidence needed to select that data on a rerun. Row changes needed to retain a recoverable selection precede file changes. SQL-phase failures can be replanned. File-phase failures require [restoration](../../skills/agent-project-move/SKILL.md#restore) before replanning, because partial path rewrites can hide unfinished directory moves.

## Import collisions

Only incoming state receives import path mappings. Existing state supplies collision checks. An existing session ID must have identical transcript content after incoming mapping, including decompressed rollouts. Dependent artifacts are reconciled even when the session exists. Moving a previously imported transcript can therefore require reconciliation or re-export before another import.

Database rows with existing unique keys are skipped. Other constraint failures abort that database's load. Planning rejects carried columns absent from the destination schema and missing required destination columns without defaults.
