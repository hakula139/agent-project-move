# Releasing

Pushing a tag that matches `v[0-9]+.*` starts `.github/workflows/tag.yml`, which checks the package version and calls devkit's `release.yml`; that workflow waits for a passing CI run on the tagged commit, pins the tag's package closures in the `hakula` Cachix cache as `agent-project-move-<tag>-<system>`, and publishes a GitHub Release with the tag's `CHANGELOG.md` section as its notes.

To restore a published tag's cache pin, run `gh workflow run nix-cache.yml --ref vX.Y.Z`.

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

## Changelog

[git-cliff](https://git-cliff.org) drafts each release's `CHANGELOG.md` section from `cliff.toml`, and the release PR curates the draft into the published notes.

- Each squash-merged PR title becomes one draft entry.
- `feat`, `fix`, `perf`, and `revert` titles appear under Added, Fixed, Changed, and Removed, respectively. Titles with `!` appear under Breaking changes. Other types are skipped, including routine `chore(deps)` and `chore(flake)` bumps.
- Each `(#N)` links to its PR.
- `--prepend` adds one section while preserving the rest. Avoid `--output CHANGELOG.md`, which regenerates the whole file and drops every curated section and compare link.

The GitHub Release keeps its own copy of the notes. To refresh it from an edited `CHANGELOG.md`, fetch `parse-changelog` and edit the release only if the parse succeeds. Replace `x86_64-unknown-linux-musl` below with your system's target, such as `aarch64-apple-darwin` on a Mac:

```bash
dir=$(mktemp -d)
gh release download \
  -R taiki-e/parse-changelog \
  -p 'parse-changelog-x86_64-unknown-linux-musl.tar.gz' \
  --dir "$dir"
tar -xzf "$dir"/parse-changelog-*.tar.gz -C "$dir"
"$dir/parse-changelog" CHANGELOG.md X.Y.Z >"$dir/notes.md" \
  && gh release edit vX.Y.Z --notes-file "$dir/notes.md"
```

### Curate the section

The draft lists PR titles, which are too short to explain each change to users. Before opening the release PR, rewrite and reorganize the draft for users, reading a PR's description wherever its title leaves the effect unclear. Follow these rules:

- For a stable section, start from the curated sections of the prereleases it rolls up and carry over every entry.
- Describe what users can now do, what no longer breaks, and what now works differently, such as a check that now fails or a value that is now rejected. Omit implementation details.
- Merge entries that describe the same user-visible change, keeping every PR link. Fold a fix to a feature that is new in the same section into that feature's entries, and describe the feature as it now works.
- Move each entry to the group that matches its effect, such as a `fix` that adds a capability moving to Added.
- Drop entries with no user-visible effect, such as a CI-only or test-only change titled `fix`.
- Order entries within each group by user impact, and keep their scope labels.
- Lead with the highlights when the release has any, curating them like the entries.
- Describe only what the PRs changed.

## Prepare a release

1. Branch off `main` as `chore/release-vX.Y.Z`.

2. Set `version` in `flake.nix` to `X.Y.Z`, since the version job fails when the tag and the package version differ.

3. Inside the dev shell, which provides git-cliff, prepend the section. Because `cliff.toml` bounds sections at stable tags only, a prerelease adds a `--tag-pattern` that bounds its section at every tag:

   ```bash
   git cliff --unreleased --tag vX.Y.Z --prepend CHANGELOG.md                                # Stable
   git cliff --unreleased --tag vX.Y.Z --tag-pattern '^v[0-9]+\.' --prepend CHANGELOG.md     # Prerelease
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

5. [Curate the section](#curate-the-section) that git-cliff prepended.

6. Run the [verification block](AGENTS.md#verification).

7. Commit, then open a PR titled `chore(release): vX.Y.Z`. Record the checks in the PR's Test plan. The diff should touch only `flake.nix`, `CHANGELOG.md`, and possibly `.cspell/words.txt`.

8. Merge after CI passes and the review is approved. If another PR merges first, recreate the branch from `main` and repeat the steps before curation, because updating the branch leaves a section that misses the new commit.

## Tag

Pushing the tag starts the Tag Release workflow and is hard to undo, so get approval for it separately from the release PR.

Tag the release PR's squash commit by its SHA, since a later PR may already sit on top of `main`:

```bash
git fetch origin
sha=$(gh pr view <release-pr> --json mergeCommit --jq .mergeCommit.oid)
git tag vX.Y.Z "$sha" && git push origin vX.Y.Z
```

The workflow reuses the CI run that the merge started on `main` and waits up to two hours for it to finish. It publishes nothing unless a push or dispatched CI run on that commit passed, so a tag on a commit that never ran CI on `main` needs `gh workflow run ci.yml --ref vX.Y.Z` first, and a failed run needs its failed jobs rerun. Then rerun the Tag Release workflow's failed jobs.

## Verify publication

Watch the [Tag Release workflow](https://github.com/hakula139/agent-project-move/actions/workflows/tag.yml) with `gh run watch` and check:

- The release notes match the changelog section, and a prerelease tag published a prerelease.
- `nix run github:hakula139/agent-project-move/vX.Y.Z -- scan` starts and prints its table.

## Re-cut an existing tag

The PR-based flow tags only reviewed, CI-green commits, so re-cutting should be rare. If a release still needs to be redone, let any in-flight release run finish first. To rebuild the same commit, delete only the release with `gh release delete vX.Y.Z --yes` and rerun the Tag Release workflow from the Actions tab against the tag. To release a different commit, delete the release and its tag, then move and push the tag:

```bash
gh release delete vX.Y.Z --cleanup-tag --yes
git tag -f vX.Y.Z <commit> && git push origin vX.Y.Z
```
