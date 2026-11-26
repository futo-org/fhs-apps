# Reviewing an app update

For a PR that changes an app's `latest/`, `releases/` or `manifest.json`. Vocabulary is in [CONTEXT.md](../../CONTEXT.md); the author's checklist is in the [pull request template](../../.github/pull_request_template.md#reviewing-an-app-update).

The review exists to catch what breaks a device's update: a missed required stop, a migration path that fails, data that moves or is lost, and a breaking change that leaves a user's setup not working after the update.

## Devices

FHS devices are x86, `linux/amd64` only. An image missing another platform is not a finding.

## Summary

The take's first bullet is the can skip verdict for the new release: `can skip` or `required stop`, why, and the upstream source it rests on. `Required stop` when this version runs a migration later versions need, or upstream names it as a version to upgrade through or from.

* When the PR has no release yet, the same bullet says how to add it. From a branch of this repo: which box to tick, `Release, can skip` or `Release, required stop`, and the `appVersion` matching the new image tag. From a fork: `APP_VERSION=<appVersion> CAN_SKIP=<true|false> mise run release <app>`, then push.
* When the PR only changes `canSkip` in `manifest.json`, the bullet says whether devices can now pass over that release safely. It asks for no new release.

The second bullet names the required stops a device passes through to reach the new release, or says there are none. The third names what was not verified: notes not read, and the update paths `run-apps` did not exercise.

A PR without its release yet is not a finding; the first bullet covers it.

## Checks

Each check is a finding only when it shows a defect, with the upstream source it rests on. Notes or sources that could not be read are a verification gap, never a pass.

* **Update path:** trace the update from every published release, skippable ones included, to the new latest. Group releases that share a path.
* **Versions read:** for every image whose reference changed, sidecars included, read upstream's notes for each version from the old reference to the new one, not only the newest.
* **Breaking changes:** changes in those notes that affect FHS as deployed: env vars, ports, volumes and binds, health check route, auth, URL and host handling, data format, minimum database or dependency versions.
* **Upstream compose:** upstream's own compose diffed between the two tags, and the changes `latest/docker-compose.yml` did not carry.
* **Migrations:** schema or data migrations in the range, whether later versions need them, and what data they touch. A rollback restores the app data snapshot only. A one way migration is not a finding when everything it touches is in app data; one that writes to an external location a setting points at, or to a remote store, is not undone by a rollback.
* **CI coverage:** `run-apps` installs and updates only apps whose `latest/` changed, from the release before the newest to the newest, on empty app data. Any other path, and any path on real data, is untested; it is a finding only with a concrete reason it fails.

## Severity

* **P0:** the update fails or loses data on a device: the image has no `linux/amd64`; a release later versions need is marked `canSkip: true`, or an upstream version that must be a stop is not released first; a dropped or moved bind sends data back to app data; a migration path that cannot run.
* **P1:** a working setup breaks after the update: a removed env var FHS sets, a changed port or health check route, a config change upstream requires.
* **P2:** a release marked a required stop that nothing needs, an upstream compose change not carried that changes behavior, a wrong `appVersion`.
* **Not a finding:** upstream behavior or security the update does not introduce, performance tuning, comments, cosmetic differences from upstream, and digest drift on an unchanged tag once the new digest is checked to still have `linux/amd64`. A new upstream weakness the update introduces is ranked by its impact on a device as deployed.

## Suggested fixes

A suggested compose, env or setting change must hold for every release on the update path, not only the previous one. Check it against the oldest release a device can update from; an env var that skips a migration an older release still needs breaks that device.
