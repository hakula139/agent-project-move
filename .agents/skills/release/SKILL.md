---
name: release
description: Cut an agent-project-move release, from the release PR through the published GitHub Release. Use when asked to release, tag, or ship a version.
---

# Cut an agent-project-move release

Pushing a tag that matches `v[0-9]+.*` starts `.github/workflows/release.yml`, which runs CI and publishes a GitHub Release with the tag's `CHANGELOG.md` section as its notes. A tag with a prerelease suffix, such as `v0.1.0-rc.1`, publishes a prerelease.

## Versioning

- **Before 1.0:** tag `v0.N.0` whenever a user-visible batch lands, and `v0.N.M` for a fix to shipped behavior. A change to the stability surface can land in any of these, and the release notes name it under Breaking changes.
- **After 1.0:** a breaking change to the stability surface bumps the major version, a user-visible addition or change bumps the minor version, and a fix bumps the patch version.
- **Prereleases:** a tag with a suffix such as `-rc.1` publishes a prerelease and its section lists only changes since the previous tag.

### Stability surface

Within a minor version, stable releases keep these compatible:

- Subcommands, flags, and exit codes
- The flake's `packages`, `overlays.default`, and `homeModules.default` outputs, and the module's options
- The bundle format written by `export` and read by `import`, which both hosts of a transfer share
- The backup layout under `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/`, including the `manifest.json` that a restore reads

Transcript and database rewrites follow each assistant's own store, so an assistant release can change what a move rewrites. The [README](../../../README.md#tested-with) lists the versions tested with this tool.

## Changelog

[git-cliff](https://git-cliff.org) drafts each release's `CHANGELOG.md` section from `cliff.toml`, and the release PR curates the draft into the published notes.

- Each squash-merged PR title becomes one draft entry.
- `feat`, `fix`, `perf`, and `revert` titles appear under Added, Fixed, Changed, and Removed, and titles with `!` under Breaking changes. Other types are skipped.
- `--prepend` adds one section while preserving the rest. Never run `--output CHANGELOG.md`, which regenerates the whole file and drops every curated section.

Curate the draft for users by describing what they can now do and what now works differently, dropping entries with no user-visible effect and merging entries about the same change.

## Prepare a release

1. Branch off `main` as `chore/release-vX.Y.Z`.
2. Inside the dev shell, prepend the section and add its compare link above the first one at the end of `CHANGELOG.md`:

   ```bash
   git cliff --unreleased --tag vX.Y.Z --prepend CHANGELOG.md
   git describe --tags --abbrev=0 --match 'v[0-9]*'    # Previous tag
   ```

   ```markdown
   [X.Y.Z]: https://github.com/hakula139/agent-project-move/compare/<previous-tag>..vX.Y.Z
   ```

   For the first release, link `https://github.com/hakula139/agent-project-move/releases/tag/vX.Y.Z` instead.
3. Curate the section and run the [verification](../../../AGENTS.md#verification) block. Because `cspell` scans `CHANGELOG.md`, add any unknown words to `.cspell/words.txt`.
4. Commit, open a PR titled `chore(release): vX.Y.Z`, record the checks, and merge once CI passes.

The steps easiest to skip are curating the section before opening the release PR, tagging only after separate approval, and verifying publication once the Release workflow finishes. Report the URLs of the release PR and the GitHub Release.

## Tag

Pushing a tag is hard to undo, so get approval for it separately from the release PR. Tag the release PR's squash commit by its SHA, since a later PR may already sit on top of `main`:

```bash
git fetch origin
sha=$(gh pr view <release-pr> --json mergeCommit --jq .mergeCommit.oid)
git tag vX.Y.Z "$sha" && git push origin vX.Y.Z
```

## Verify publication

Watch the [Release workflow](https://github.com/hakula139/agent-project-move/actions/workflows/release.yml) with `gh run watch`, and check that the release notes match the changelog section, that a prerelease tag published a prerelease, and that `nix run github:hakula139/agent-project-move/vX.Y.Z -- scan` starts and prints its table.
