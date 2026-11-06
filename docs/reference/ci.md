# CI

CI runs on pushes to `main`, pull requests, and manual dispatch. The `nix` job calls devkit's reusable `nix.yml`, which runs `nix flake check` on Linux and macOS and evaluates every system on Linux. A `build` job builds the package on Linux and macOS.

See [RELEASING.md](../../RELEASING.md) for the release workflow.

Branch protection requires only `CI Result`, which uses devkit's `ci-result` action to read every completed job of the run attempt from the Actions API and fail when any job other than itself concluded anything except success or skipped. A matrix leg cancelled before a runner picks it up never reaches `needs`, so list each new job in the gate's `needs`. A skipped job counts as passing, which is why the gate runs after a failure too.

The Nix jobs pull from the `hakula` Cachix cache, and push their builds to it on the default branch. The cache only saves build time, so a failed Cachix setup logs a warning and the job builds without it.

Each job sets `timeout-minutes` to several times its usual duration, so a hung job stops at that limit, where it would otherwise hold the runner for GitHub's six-hour default. Give each new job a limit the same way.
