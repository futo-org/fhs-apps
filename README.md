# FHS App Store

Apps that FHS devices install and update. Glossary: [CONTEXT.md](CONTEXT.md).

## Layout

```
catalog.json              # apps shown in the store (name, tagline, icon, ...)
<app>/
  manifest.json           # releases, appended by `mise run release`; authors edit appPort only
  latest/                 # working copy: the only folder authors edit
    release.json          # {"appVersion": "v3.3.1", "canSkip": true}
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
  which copies `latest/` to `releases/<n+1>/` and appends `{version, appVersion, canSkip}`
  to the manifest. Run it again after every change; it rebuilds the PR's release, so a PR
  adds exactly one. CI rejects a `latest/` that differs from the newest release, and a PR
  that adds more than one release. On a conflict in `releases/` or `manifest.json`, take
  master's side and run it again.
* `version` is the release number (1, 2, 3, ...); updates follow it. `appVersion` is the
  upstream version, shown to users only.
* `canSkip: false` makes the release a required stop: every update lands on it and passes
  its health check before going further. Once merged, the only allowed change is
  `canSkip` from `false` to `true` in `manifest.json`.
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
  empty), plus platform values `APP_ID`, `APP_DATA_DIR`, `APP_SEED`, `APP_PASSWORD`. Data
  lives under `${APP_DATA_DIR}`; named volumes, `env_file`, floating tags and SELinux
  `:z`/`:Z` are rejected. Any other `${NAME}` would render empty, so CI rejects it (`$$`
  for a literal `$`).
* Every service sets `restart: always` or `restart: unless-stopped`.
* `health-check.sh` runs as `bash -euo pipefail` from the release folder, 5 s per run, as
  a throwaway unprivileged user. Available tools: bash, coreutils, grep, sed, gawk, jq,
  curl. No docker.

## Adding an app

1. `mise run new-app <app-id> <port>` (copies `_template/`).
2. Fill in `<app>/latest/` and add a `catalog.json` entry.
3. `mise run release <app>` and `mise run validate`, then open a PR. CI also installs
   `latest/` and, from the second release on, updates from the previous release to the
   new one (`mise run ci-run`).

## Tooling

mise pins shellcheck and shfmt (`mise install`) and runs every command. The scripts are bash and need
jq and docker on the host, like the device. `scripts/generate-compose.sh` is the only renderer: the
agent runs it on the device, CI runs it here. CI pins docker compose to the version the OS
image ships, since the merge rules are compose's.

```
scripts/
  validate-store.sh, generate-compose.sh, new-app.sh, release.sh, ci-run.sh   commands
  *.test.sh                                                        their tests
```

* `mise run validate`: strict checks and a render of every settings combination (needs
  docker; `SKIP_RENDER=1` skips renders, `BASE_REF=<ref>` checks published history).
* `mise run generate-compose <release-dir> <app-id> [user_settings.json]`: the compose a
  device would run.
* `mise run ci-run install|update <app-id>`: runs the app like a device (pulls images).
* `mise run release <app-id>`: freezes `latest/` into the PR's release (`BASE_REF`,
  default `origin/master`, is the branch the PR merges into).
* `mise run test`: the tooling's tests (need docker).
* `mise run lint`: shfmt format check and shellcheck (`lint-fix` formats).
