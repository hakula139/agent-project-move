# CI

CI runs on pushes to `main`, pull requests, and manual dispatch, and the release workflow calls it again for each tag before publishing. The `nix` job runs `nix flake check` and `nix build` on Linux and macOS.

Branch protection requires only `CI Result`, which reads every job of the run attempt from the Actions API and fails when any job other than itself concluded anything except success or skipped. A matrix leg cancelled before a runner picks it up never reaches `needs`, so list each new job in the gate's `needs`. A skipped job counts as passing, which is why the gate runs after a failure too.

The Nix jobs pull from the `hakula` Cachix cache, and push their builds to it on `main` or when the maintainer runs them. The cache only saves build time, so a failed Cachix setup logs a warning and the job builds without it.

Each job sets `timeout-minutes` to several times its usual duration, so a hung job stops at that limit, where it would otherwise hold the runner for GitHub's six-hour default. Give each new job a limit the same way.
