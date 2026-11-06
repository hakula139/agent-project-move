# CI

CI runs on pushes to `main`, pull requests, and manual dispatch. The `nix` job calls devkit's reusable `nix.yml`, which runs `nix flake check` on Linux and macOS and evaluates every system on Linux.

See [RELEASING.md](../../RELEASING.md) for the release workflow.

Branch protection requires only `CI Result`, which uses devkit's `ci-result` action to read every completed job of the run attempt from the Actions API and fail when any job other than itself, under its own job-name prefix, concluded anything except success or skipped. The gate skips a job that is still running, so a job missing from `needs` that finishes after the gate starts is never checked. A skipped required check passes, so the gate runs after failures too.

The Nix jobs pull from the `hakula` Cachix cache, and push their builds to it on the default branch. The cache only saves build time, so a failed Cachix setup does not fail the job.

Each job sets `timeout-minutes` to several times its usual duration, so a hung job stops at that limit, where it would otherwise hold the runner for GitHub's six-hour default. Give each new job a limit the same way.
