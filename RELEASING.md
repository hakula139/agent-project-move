# Releasing

Pushing a tag that matches `v[0-9]+.*` starts `.github/workflows/release.yml`, which waits for a passing CI run on the tagged commit, pins the tag's package closures in the `hakula` Cachix cache, and publishes a GitHub Release with the tag's `CHANGELOG.md` section as its notes. A tag with a prerelease suffix, such as `v0.1.0-rc.1`, publishes a prerelease.

To restore a published tag's cache pin, run `gh workflow run nix-cache.yml -f tag=vX.Y.Z`. To republish a tag's release notes after correcting its changelog section, run `gh workflow run release.yml --ref main -f notes=vX.Y.Z`.

## Versioning

- **Before 1.0**: tag `v0.N.0` whenever a user-visible batch lands, and `v0.N.M` for a fix to shipped behavior. A change to the stability surface can land in any of these, and the release notes name it under Breaking changes.
- **After 1.0**: a breaking change to the [stability surface](#stability-surface) bumps the major version, a user-visible addition or change bumps the minor version, and a fix bumps the patch version.
- **Prereleases**: a tag with a suffix such as `-rc.1` publishes a prerelease, and its section lists only changes since the previous tag.
- **Breaking changes**: a PR that breaks the stability surface marks its title with [`!`](docs/conventions/github.md#commits-and-branches).

### Stability Surface

Within a minor version, stable releases keep these compatible:

- Subcommands, flags, and exit codes
- The flake's `packages`, `overlays.default`, and `homeModules.default` outputs, and the module's options
- The bundle format written by `export` and read by `import`, which both hosts of a transfer share
- The backup layout under `${XDG_STATE_HOME:-~/.local/state}/agent-project-move/`, including the `manifest.json` that a restore reads

Transcript and database rewrites follow each assistant's own store, so an assistant release can change what a move rewrites. The [README](README.md#tested-with) lists the versions tested with this tool.

## Changelog

[git-cliff](https://git-cliff.org) drafts each release's `CHANGELOG.md` section from `cliff.toml`, and the release PR curates the draft into the published notes.

- Each squash-merged PR title becomes one draft entry.
- `feat`, `fix`, `perf`, and `revert` titles appear under Added, Fixed, Changed, and Removed, respectively. Titles with `!` appear under Breaking changes. Other types are skipped, including routine `chore(deps)` and `chore(flake)` bumps.
- Within each group, unscoped entries come first, then the rest sorted by scope, so related entries sit together. Each `(#N)` links to its PR.
- A stable section includes every change since the previous stable release, and a prerelease section includes only changes since the previous tag.
- `--prepend` adds one section while preserving the rest. Avoid `--output CHANGELOG.md`, which regenerates the whole file and drops every curated section and compare link.

The GitHub Release keeps its own copy of the notes, so once a PR that corrects a published section merges, run the Release workflow on `main` with the tag in its `notes` input, which republishes the tag's section and builds nothing:

```bash
gh workflow run release.yml --ref main -f notes=vX.Y.Z
```

### Curate the Section

The draft lists PR titles, which are too short to explain each change to users. Before opening the release PR, rewrite the draft for users, reading a PR's description wherever its title leaves the effect unclear.

- Describe what users can now do, what no longer breaks, and what now works differently, such as a check that now fails or a value that is now rejected. Omit implementation details.
- Merge entries that describe the same user-visible change, keeping every PR link. Fold a fix to a feature that is new in the same section into that feature's entries, and describe the feature as it now works.
- Move each entry to the group that matches its effect, such as a `fix` that adds a capability moving to Added.
- Drop entries with no user-visible effect, such as a CI-only or test-only change titled `fix`.
- Order entries within each group by user impact, and keep their scope labels.
- Lead with the highlights when the release has any, curating them like the entries.
- Describe only what the PRs changed.

## Prepare a Release

1. Branch off `main` as `chore/release-vX.Y.Z`.

2. Set `version` in `nix/agent-project-move.nix` to `X.Y.Z`, since the publish job fails when the tag and the package version differ.

3. Inside the dev shell, which provides git-cliff, prepend the section. Because `cliff.toml` bounds sections at stable tags only, a prerelease adds a `--tag-pattern` that bounds its section at every tag:

   ```bash
   git cliff --unreleased --tag vX.Y.Z --prepend CHANGELOG.md                             # Stable
   git cliff --unreleased --tag vX.Y.Z --tag-pattern '^v[0-9]+\.' --prepend CHANGELOG.md  # Prerelease
   ```

   For a notable release, list the highlights as Markdown bullets in `highlights.md` and add `--with-tag-message="$(<highlights.md)"`, which renders them under `### Highlights` at the top of the section.

4. Because `--prepend` writes no compare link, add the section's link reference above the first one at the end of `CHANGELOG.md`. A stable release compares against the previous stable tag, and a prerelease against the previous tag:

   ```bash
   git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-*'    # Previous stable tag
   git describe --tags --abbrev=0 --match 'v[0-9]*'                    # Previous tag
   ```

   ```markdown
   [X.Y.Z]: https://github.com/hakula139/agent-project-move/compare/<previous-tag>..vX.Y.Z
   ```

   When the stable lookup finds no tag, as for `v0.1.0`, link `https://github.com/hakula139/agent-project-move/releases/tag/vX.Y.Z` instead.

5. [Curate the section](#curate-the-section) that git-cliff prepended.

6. Run the [verification block](AGENTS.md#verification). Because `cspell` scans `CHANGELOG.md`, add any unknown words from the section to `.cspell/words.txt`.

7. Commit, then open a PR titled `chore(release): vX.Y.Z`. Record the checks in the PR's Test plan. The diff should touch only `nix/agent-project-move.nix`, `CHANGELOG.md`, and possibly `.cspell/words.txt`.

8. Merge after CI passes and the review is approved. If another PR merges first, recreate the branch from `main` and repeat the steps before curation, because updating the branch leaves a section that misses the new commit.

The `v0.1.0` section and the `0.1.0` version are already prepared on `main`, so the first release starts at [Tag](#tag). Check that nothing merged after the section was written.

## Tag

Pushing the tag starts the Release workflow and is hard to undo, so get approval for it separately from the release PR.

Tag the release PR's squash commit by its SHA, or the commit that prepared the `v0.1.0` section for the first release, since a later PR may already sit on top of `main`:

```bash
git fetch origin
sha=$(gh pr view <release-pr> --json mergeCommit --jq .mergeCommit.oid)
git tag vX.Y.Z "$sha" && git push origin vX.Y.Z
```

The workflow reuses the CI run that the merge started on `main` and waits up to an hour for it to finish. It publishes nothing unless a push or dispatched CI run on that commit passed, so a tag on a commit that never ran CI on `main` needs `gh workflow run ci.yml --ref vX.Y.Z` first, and a failed run needs its failed jobs rerun. Then rerun the Release workflow's failed jobs.

## Verify Publication

Watch the [Release workflow](https://github.com/hakula139/agent-project-move/actions/workflows/release.yml) with `gh run watch` and check:

- The release notes match the changelog section, and a prerelease tag published a prerelease.
- The `Pin Nix packages` job passed.
- `nix run github:hakula139/agent-project-move/vX.Y.Z -- scan` starts and prints its table.

## Re-Cut an Existing Tag

The PR-based flow tags only reviewed, CI-green commits, so re-cutting should be rare. If a release still needs to be redone, let any in-flight release run finish first. To rebuild the same commit, delete only the release with `gh release delete vX.Y.Z --yes` and run the Release workflow from the Actions tab against the tag. To release a different commit, delete the release and its tag, then move and push the tag:

```bash
gh release delete vX.Y.Z --cleanup-tag --yes
git tag -f vX.Y.Z <commit> && git push origin vX.Y.Z
```
