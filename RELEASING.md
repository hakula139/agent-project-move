# Releasing

Use the [release skill](https://github.com/hakula139/plugins/blob/main/plugins/hakula-workflow/skills/release/SKILL.md) with the contract below.

## Versioning

- **Before 1.0**: tag `v0.N.0` whenever a user-visible batch lands, and `v0.N.M` for a fix to shipped behavior. A change to the stability surface bumps the minor version and is listed under Breaking changes.
- **After 1.0**: a breaking change to the [stability surface](#stability-surface) bumps the major version, a user-visible addition or change bumps the minor version, and a fix bumps the patch version.

### Stability surface

Within a minor version, stable releases keep these compatible:

- Subcommands, flags, and exit codes
- The flake's `packages`, `overlays.default`, and `homeModules.default` outputs, and the module's options
- The bundle format written by `export` and read by `import`, which both hosts of a transfer share
- The backup layout under `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/`, including the `manifest.json` that a restore reads

Transcript and database rewrites follow each assistant's own store, so an assistant release can change what a move rewrites. The [README](README.md#tested-with) lists the versions tested with this tool.

## Preparation and verification

Set `version` in `.claude-plugin/plugin.json` to the release number, which the flake reads too, since Claude Code keeps serving its cached copy of the plugin until that string changes. Then update the changelog, and run the [verification block](AGENTS.md#verification). Mark changes to the stability surface with `!` in the conventional commit title.

After publication, verify that `nix run github:hakula139/agent-project-move/vX.Y.Z -- scan` starts and prints its table.
