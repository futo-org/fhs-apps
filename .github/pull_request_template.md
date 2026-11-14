## Reviewing an app update

For a PR that changes an app's `latest/`, before merging:

* [ ] Read upstream's release notes for every version between the current one and the proposed one.
* [ ] Set `appVersion` in `latest/release.json`. The tag and `appVersion` don't always look the same: `34.0.4-apache` is `v34.0.4`, `12.2.20261005-225228` is `v12.2`.
* [ ] Decide `canSkip`. It carries over from the last release, so check it every time: `false` when this version runs a migration that later versions need.
* [ ] If upstream's own compose changed for this version (a new sidecar, new variables, sidecar versions), bring those changes into `latest/docker-compose.yml`.
* [ ] If the release notes say a version in between is required, split the PR: release the required version first with `canSkip: false`, and the newer one in the next PR.
* [ ] Run `mise run release <app>` and push.
* [ ] Wait for `validate` and `run-apps`. For a big jump, try it on a test device pointed at `store:pr-<n>` too.
