# Reviewing an app update

For a PR that changes an app's `latest/`, `releases/` or `manifest.json`. Vocabulary is in [CONTEXT.md](../../CONTEXT.md); the author's checklist is its "Reviewing an app update" section.

The review exists to catch what breaks a device's update: a missed required stop, a migration path that fails, data that moves or is lost, and a breaking change that leaves a user's setup not working after the update.

## Devices

FHS devices are x86, `linux/amd64` only. An image missing another platform is not a finding.

## Every review states, before the findings

* **Can skip verdict:** `Can skip` or `Cannot skip` for the new release, with one line why and its evidence. `Cannot skip` when this version runs a migration later versions need, or upstream names it as a version to upgrade through or from. When the PR has no release yet, say which box to tick: `Release, can skip` or `Release, required stop`, and the `appVersion` matching the new image tag.
* **Update path:** the releases a device lands on from every required stop in the manifest and from the latest release, ending on the new one.
* **Versions read:** every upstream version between the previous release's `appVersion` and the new one, not only the newest, with the release notes read for each.
* **Breaking changes:** each change in those notes that affects FHS as deployed: env vars, ports, volumes and binds, health check route, auth, URL and host handling, data format, minimum database or dependency versions. `None` when none, with the versions read.
* **Upstream compose:** upstream's own compose diffed between the two tags, and the changes `latest/docker-compose.yml` did not carry.
* **Migrations:** schema or data migrations in the range, whether later versions need them, and whether they are one way. A snapshot rollback restores app data, so one way alone is not a finding.
* **Verification gaps:** what was not checked. `ci-run update` starts from empty app data, so a green `run-apps` does not prove a migration on real data; name that gap when the range has migrations. Say when `run-apps` has not run on the head.

## Severity

* **P0:** the update fails or loses data on a device: the image has no `linux/amd64`, a required stop is skippable, a dropped or moved bind sends data back to app data, a migration path that cannot run.
* **P1:** a working setup breaks after the update: a removed env var FHS sets, a changed port or health check route, a config change upstream requires; a `canSkip` that disagrees with the verdict; an upstream version that must be released first as its own required stop (split the PR).
* **P2:** an upstream compose change not carried that changes behavior, a wrong `appVersion`, a missing release.
* **Not a finding:** upstream behavior or security the update does not introduce, performance tuning, comments, digest only drift, cosmetic differences from upstream. Mention them in the summary when useful. A new upstream weakness the update introduces is ranked by its impact on a device as deployed.

## Suggested fixes

A suggested compose, env or setting change must hold for every release on the update path, not only the previous one. Check it against the oldest release a device can update from; an env var that skips a migration an older release still needs breaks that device.

## Rereviews

On every new head, recheck each open finding: resolve it when fixed, withdraw it when its premise is gone (Renovate moved the version, the release was added), keep it only when still valid against the current head. Recompute the can skip verdict and the update path.
