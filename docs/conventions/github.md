# GitHub

Conventions for commits, branches, pull requests, and issues.

## Commits and branches

- Keep each commit to one logical change. Use the imperative mood for its title, formatted as `type(scope): description`. For substantial changes, add a body explaining the problem, rationale, and tradeoffs.
- Choose one of these types: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `ci`, `build`, `chore`, `style`, or `revert`.
- Use the most specific scope the change touches, such as a store (`claude`, `codex`), a helper (`actions`, `sqlite`), or a documentation target (`README`, `design`). Omit the scope for changes that span the repository.
- If a change breaks the [stability surface](../../.agents/skills/release/SKILL.md#stability-surface), add `!` after the scope, as in `feat(claude)!: ...`.
- Name branches `<type>/<short-name>`, using the same types.

## Pull requests

- Merge into `main` only with squash merges. The squash commit uses the PR title, which becomes the PR's draft [changelog](../../.agents/skills/release/SKILL.md#changelog) entry, so write the title for users.
- Fill in `.github/pull_request_template.md`.
- Assign the PR to `hakula139` and add one type label:

| Commit type               | Label                            |
| ------------------------- | -------------------------------- |
| `feat`                    | `enhancement`                    |
| `fix`                     | `bug`                            |
| `perf`                    | `performance`                    |
| `refactor`                | `refactor`                       |
| `docs`                    | `documentation`                  |
| `test`                    | `test`                           |
| `ci`                      | `ci`                             |
| `build`, `chore`, `style` | `chore`                          |
| `revert`                  | The reverted change's type label |

## Review and merge

- Review each PR once. Fix every finding, including suggestions, verify the fixes with the [verification](../../AGENTS.md#verification) block, and merge without a second review round.
- Tags and releases need the approval the [release skill](../../.agents/skills/release/SKILL.md) describes.
- Keep each line of work's open PRs in a single stack, with each PR based on the one before it and no more than three unmerged at a time. Land the bottom PR before opening another.

## Issues

- Open one issue for each actionable outcome with the details the form asks for, and include acceptance criteria for planned work. Label it like a PR.
- If an issue depends on another landing first, record that order with a native blocked-by dependency.
- Label open design questions `design`, and close them once the decision is documented in `docs/reference/`.
- Close out-of-scope requests as not planned, pointing to the assistants and workflows `README.md` covers.
- Close an issue as completed when its PR merges, and tick each acceptance criterion the merged work satisfies. Leave an unmet criterion unchecked, and track it in a follow-up issue.
