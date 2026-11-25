# FHS App Store

Apps that FHS devices install and update. Glossary: [CONTEXT.md](CONTEXT.md).

## Layout

```
catalog.json              # apps shown in the store (name, tagline, icon, ...)
<app>/
  manifest.json           # releases, appended by `mise run release`; authors edit appPort only
  latest/                 # working copy: the only folder authors edit
    release.json          # {"appVersion": "v3.3.1", "canSkip": true, "healthTimeoutMinutes": 60}
    docker-compose.yml    # stock compose, close to upstream's
    settings.json         # deployment choices and the compose changes they make
    health-check.sh       # exit 0 = serving
    data/                 # seed folders copied into the app's data on install (.gitkeep dropped)
  releases/<n>/           # frozen copy of latest/ made by `mise run release`; never edited
_template/                # starting point for a new app
scripts/                  # bash tooling, run with `mise run <task>`
```

## Releases

* A PR that changes `<app>/latest/` also adds its release: run `mise run release <app>`,
  which asks `appVersion` (guessed from the changed image tag, Enter takes it) and
  `canSkip`, writes them to `latest/release.json`, copies `latest/` to `releases/<n+1>/`
  and appends `{version, appVersion, canSkip}` to the manifest. Without `<app>` it lists the
  apps, marks the ones with unreleased changes, and asks which one. Without a terminal, pass
  the app and both answers: `APP_VERSION=v1.2.3 CAN_SKIP=true mise run release <app>`. In
  a PR from a branch of this repo, ticking `Release, can skip` or `Release, required stop`
  in the PR body does the same in CI with the guessed `appVersion` and pushes the release
  to the branch; with no guess it comments to release locally. A box ticked when the PR is
  opened does nothing, and a PR from a fork releases locally. CI releases the commit the box
  was ticked on, so after a new push untick the box and tick it again. Run
  it again after every change; it rebuilds the PR's release, so a PR adds exactly one. CI
  rejects a `latest/` that differs from the newest release, and a PR that adds more than
  one release. On a conflict in `releases/` or `manifest.json`, take master's side and run
  it again.
* `version` is the release number (1, 2, 3, ...); updates follow it. `appVersion` is the
  upstream version, shown to users only; a manifest entry's must match its release's
  `release.json`.
* `canSkip: false` makes the release a required stop: every update lands on it and passes
  its health check before going further. Once merged, the only allowed change is
  `canSkip` from `false` to `true` in `manifest.json`.
* `healthTimeoutMinutes` (optional, 1 to 360, default 30) is how long the health gate waits
  for this release to pass its health check. Set it from the times `ci-run` prints
  (`healthy after N s`) with a clear margin: longer for a slow migration, shorter for an
  app that can get stuck, so the user isn't kept waiting for a start that won't finish.
* Merged releases and folders never change; to fix a release, add a new one.

## Settings (`settings.json`)

Only deployment choices that change the compose belong here (a folder to mount, hardware
acceleration). Anything configured inside the app is set in the app itself. Every
setting has a default.

| Type | Value | `compose` |
|---|---|---|
| `path` | a folder the user picks from indexed external locations; unset = app data | a fragment, applied when a folder is picked |
| `enum` | one of `options[].value` | map option value → fragment |
| `bool` | `true` / `false` | map `"true"`/`"false"` → fragment |

A secret the app needs is `${APP_SEED}` or `${APP_PASSWORD}`: derived on the device per
app, the same on every render, never shown or stored.

Field keys: `key` (UPPER_SNAKE, also the env var name; `APP_`, `FHS_`, `COMPOSE_`
reserved), `type`, `label`, optional `help`, `editable` (default `true`; `false` = chosen
at install only), `default` (required for `enum` and `bool`), `options` (`enum`).

Fragments merge into the stock compose with compose's own rules (`docker compose -f stock
-f fragment config`): they add and override; a volume with the same target replaces the
stock one. `path` fragments must bind with long syntax and
`"bind": {"create_host_path": false}`, so a missing drive fails the start instead of
filling the system disk. CI loads every rendered combination like a device does and
rejects one that doesn't load.

A release keeps every `path` setting of the release before it, as a `path`: dropping or
renaming one would move users' data back to app data on update, so CI rejects it.

## Compose and health check

* Values reach the compose as `${KEY}` (a bool as `true` or `false`, an unset folder as
  empty), plus platform variables `APP_ID`, `APP_DATA_DIR`, `APP_SEED`, `APP_PASSWORD` and
  `APP_TZ` (the device's time zone, like `America/Chicago`). Data lives under
  `${APP_DATA_DIR}`; named and anonymous volumes, relative binds, `env_file`,
  `container_name` (names are global on the host), floating tags and SELinux `:z`/`:Z`
  are rejected, in the stock compose and every fragment. Any other `${NAME}` would render
  empty, so CI rejects it (`$$` for a literal `$`).
* Bind every path an image declares as `VOLUME` under `${APP_DATA_DIR}`, or docker makes
  an anonymous volume that the snapshot misses and every `down` leaves behind. `ci-run`
  fails on one.
* Every service sets `restart: always` or `restart: unless-stopped`.
* The stock compose publishes the app's `appPort` over tcp, and no two apps publish the same host
  port. Within one settings combination, no two services publish the same host port and
  protocol on overlapping addresses. An app on `network_mode: host` is taken to use its
  `appPort`; other ports it opens aren't checked.
* `health-check.sh` runs as `bash -euo pipefail` from the release folder, 5 s per run, as
  root, with only `PATH=/usr/bin:/usr/sbin`, `HOME`, `LANG=C.UTF-8`, `APP_ID`,
  `APP_DATA_DIR` and `APP_TZ` set: no secrets, no setting values. It can use bash,
  coreutils, grep, sed, gawk, jq and curl, nothing else. No docker.
* A failing `health-check.sh` says why in one or two plain lines a user or support can act
  on: what it asked and what it got (the URL and status code, still installing, in
  maintenance mode). The device shows the last 20 lines it printed when the health gate
  gives up, so a silent check leaves the user with nothing. A passing one prints nothing.
  `ci-run` fails on either.
* `catalog.json` icons are absolute `https` URLs, and every app is in `catalog.json`.

## Adding an app

1. `mise run new-app <app-id> <port>` (copies `_template/`).
2. Fill in `<app>/latest/` and add a `catalog.json` entry.
3. `mise run release <app>` and `mise run validate`, then open a PR. CI also installs
   `latest/` and, from the second release on, updates from the previous release to the
   new one (`mise run ci-run`).

## Tooling

mise pins shellcheck, shfmt, oras, cosign and crane (`mise install`) and runs every command. The scripts are bash and need
jq and docker on the host, like the device. `scripts/generate-compose.sh` is the only renderer: the
agent runs it on the device, CI runs it here. CI pins docker compose to the version the OS
image ships, since the merge rules are compose's.

```
scripts/
  validate-store.sh, generate-compose.sh, new-app.sh, release.sh, release-pr.sh, ci-run.sh,
  pack-store.sh, publish-store.sh, check-images.sh                            commands
  *.test.sh                                                                   their tests
```

* `mise run validate`: strict checks and a render of every settings combination (needs
  docker; `SKIP_RENDER=1` skips renders and the compose and port rules checked on them,
  `BASE_REF=<ref>` checks published history).
* `mise run generate-compose <release-dir> <app-id> [user_settings.json]`: the compose a
  device would run, on stdout. Needs `APP_DATA_DIR`, `APP_SEED`, `APP_PASSWORD` and
  `APP_TZ` in the environment. A stored value the release doesn't accept exits 10, its key
  on stdout and the reason on stderr; any other failure exits non zero with the reason.
* `mise run ci-run install|update <app-id>`: runs the app like a device (pulls images).
* `mise run release [<app-id>]`: freezes `latest/` into the PR's release, asking for the
  app when none is given (`BASE_REF`, default `origin/master`, is the branch the PR merges
  into).
* `mise run pack <out>`: the store bundle devices download, the same bytes for the same store.
  Fails over the agent's limits: 1 MiB packed, 64 MiB unpacked.
* `mise run publish commit`: what CI runs on `master` once `validate` passes. Pushes
  `store:<commit>` to ghcr, signs it, and copies both to `oci.futo.org/futo-home/store`.
  Then it moves `nightly`, `alpha`, `beta` and `stable` on each, only forward. Its revision is the last commit on `master`'s
  first parent line that changed the store or how it's packed, so the same store always gets
  the same digest, and a channel moves only when
  the commit it points at is an ancestor of that one. `mise run publish pr <number>` pushes a
  PR's unsigned `store:pr-<number>` to ghcr. `STORE_REPOSITORIES` points it at other
  registries, `COSIGN_KEY` signs with a key instead of CI's keyless identity.

  In Harbor project `futo-home` (ID 13), create a project robot with Pull Repository and
  Push Repository. Add its full username as `OCI_FUTO_ORG_USERNAME` and its secret as
  `OCI_FUTO_ORG_TOKEN` in this repository's Actions secrets.
* Release from PR (`.github/workflows/release.yml`): ticking a release box in a PR body runs
  `scripts/release-pr.sh` on the branch and pushes the release as the org's `fhs-ci` app
  (`FHS_CI_APP_CLIENT_ID` variable, `FHS_CI_APP_PRIVATE_KEY` secret), so `validate` runs on it.
* `mise run check-images`: what CI runs every night. Every image of every published release,
  rendered with the defaults, each enum and bool choice and each folder set, must resolve and
  mount each `VOLUME` it declares.
* `mise run test`: the tooling's tests (need docker).
* `mise run lint`: shfmt format check and shellcheck (`lint-fix` formats).
