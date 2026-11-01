# Security policy

## Supported versions

Security fixes go into `main` and ship with the next release. Report vulnerabilities against the latest release or current `main`.

## Reporting a vulnerability

Report vulnerabilities privately through a [GitHub security advisory](https://github.com/hakula139/agent-project-move/security/advisories/new), not in public issues. Include:

- The release tag or commit you run, and your platform
- The subcommand and flags, and the assistant versions whose state they read
- Steps to reproduce or a proof of concept
- The impact and any mitigations you know of

The maintainer acknowledges a report within 7 days and shares an assessment within 14 days. For a confirmed vulnerability, the maintainer aims to release a fix within 30 days, coordinates disclosure with the reporter, and publishes the advisory once the fix is released.

## Sensitive data

`agent-project-move` reads and rewrites the local state of four coding assistants. That state contains full conversation transcripts, tool input and output, file history, and memory notes, and it can include secrets a session printed or a tool read.

- **Backups** copy every edited or deleted file and database into `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/`, which is created with mode 0700. The backups outlive the run and hold the same content as the stores.
- **Bundles** written by `export` hold the files and database rows recorded for one project path, including transcripts. Selection follows the project path, so the assistants' credential files and tables, such as `auth.json` and `.credentials.json`, stay out of a bundle. An export is still a copy of that state, so transfer it over a channel you trust and delete it on both hosts when the import is done.

A bug in the selection or rewrite logic can delete state or leave a session pointing at a dead path, but the tool holds no credentials, opens no network connections, and runs no commands from the assistant stores.

## Trust model

The command runs with the permissions of the user who starts it and edits that user's assistant stores in place. It trusts the store formats of the assistants it supports, listed in the [README](README.md#tested-with).

The [safety model](README.md#safety-model) covers concurrent sessions and recovery after a failed apply.
