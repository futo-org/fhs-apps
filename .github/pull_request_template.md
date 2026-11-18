## Reviewing an app update

For a PR that changes an app's `latest/`, before merging:

* [ ] Read upstream's release notes for every version between the current one and the proposed one.
* [ ] Decide `canSkip`: `false` when this version runs a migration that later versions need.
* [ ] If upstream's own compose changed for this version (a new sidecar, new variables, sidecar versions), bring those changes into `latest/docker-compose.yml`.
* [ ] If the release notes say a version in between is required, split the PR: release the required version first with `canSkip: false`, and the newer one in the next PR.
* [ ] Release: tick one box below and CI releases with the guessed `appVersion` and pushes it here, or run `mise run release <app>` and push (always for a PR from a fork). After a new push, untick the box and tick it again to rebuild the release. Check the `appVersion` it picks (`34.0.4-apache` is `v34.0.4`).
* [ ] Wait for `validate` and `run-apps`. For a big jump, try it on a test device pointed at `store:pr-<n>` too.

<!-- release -->
* [ ] Release, can skip
* [ ] Release, required stop
<!-- /release -->
