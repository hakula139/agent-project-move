# Releasing

Use the [release skill][release-skill] for preparation, notes curation, the release PR, approved tagging, and recovery. This document defines the agent-project-move release contract.

Pushing a tag matching `v[0-9]+.*` starts devkit's shared release workflow. It validates the package version against the tag, waits for CI, and publishes notes from `CHANGELOG.md` using the shared changelog configuration.

## Versioning

- **Before 1.0**: tag `v0.N.0` whenever a user-visible batch lands, and `v0.N.M` for a fix to shipped behavior. A change to the stability surface bumps the minor version and is listed under Breaking changes.
- **After 1.0**: a breaking change to the [stability surface](#stability-surface) bumps the major version, a user-visible addition or change bumps the minor version, and a fix bumps the patch version.
- **Prereleases**: a tag with a suffix such as `-rc.1` publishes a prerelease, and its section lists only changes since the previous tag.

### Stability surface

Within a minor version, stable releases keep these compatible:

- Subcommands, flags, and exit codes
- The flake's `packages`, `overlays.default`, and `homeModules.default` outputs, and the module's options
- The bundle format written by `export` and read by `import`, which both hosts of a transfer share
- The backup layout under `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/`, including the `manifest.json` that a restore reads

Transcript and database rewrites follow each assistant's own store, so an assistant release can change what a move rewrites. The [README](README.md#tested-with) lists the versions tested with this tool.

## Preparation and verification

Set `version` in `flake.nix` to the release number, update the changelog, and run the [verification block](AGENTS.md#verification). The release PR changes `flake.nix`, `CHANGELOG.md`, and any required spelling entries in `.cspell/words.txt`.

PR titles become draft changelog entries, so describe the user-visible effect. Mark changes to the stability surface with `!` in the conventional commit title.

After publication, verify that `nix run github:hakula139/agent-project-move/vX.Y.Z -- scan` starts and prints its table.

## Cache recovery

To restore a published tag's cache pin, run:

```bash
gh workflow run nix-cache.yml --ref vX.Y.Z
```

[release-skill]: https://github.com/hakula139/plugins/blob/main/plugins/hakula-workflow/skills/release/SKILL.md
