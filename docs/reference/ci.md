# CI

CI runs on pushes to `main`, pull requests, and manual dispatch. The `nix` job runs `nix flake check` and `nix build` on Linux and macOS.

The release workflow waits for a push or dispatched CI run on the tagged commit, then pins the tag's package closures in Cachix under `agent-project-move-<tag>-<system>` and publishes the GitHub Release from the tag's `CHANGELOG.md` section. A manual dispatch with `notes` republishes a tag's notes without building. `nix-cache.yml` pins a tag's closures and can be dispatched to restore a pin. [RELEASING.md](../../RELEASING.md) covers both procedures.

Branch protection requires only `CI Result`, which reads every job of the run attempt from the Actions API and fails when any job other than itself concluded anything except success or skipped. A matrix leg cancelled before a runner picks it up never reaches `needs`, so list each new job in the gate's `needs`. A skipped job counts as passing, which is why the gate runs after a failure too.

The Nix jobs pull from the `hakula` Cachix cache, and push their builds to it on `main` or when the maintainer runs them. The cache only saves build time, so a failed Cachix setup logs a warning and the job builds without it.

Each job sets `timeout-minutes` to several times its usual duration, so a hung job stops at that limit, where it would otherwise hold the runner for GitHub's six-hour default. Give each new job a limit the same way.
