# FHS App Store

Apps that FHS devices install and update. Glossary: [CONTEXT.md](CONTEXT.md).

## Layout

```
catalog.json              # apps shown in the store (name, tagline, icon, ...)
<app>/
  manifest.json           # releases, appended by CI; authors edit appPort only
  latest/                 # working copy: the only folder authors edit
    release.json          # {"appVersion": "v3.3.1", "canSkip": true}
    docker-compose.yml    # stock compose, close to upstream's
    settings.json         # deployment choices and the compose changes they make
    health-check.sh       # exit 0 = serving
    data/                 # seed folders copied into the app's data on install
  releases/<n>/           # frozen copy of latest/ made by CI; never edited
_template/                # starting point for a new app
scripts/                  # bash tooling, run with `mise run <task>`
```

## Releases

* Every merge that changes `<app>/latest/` becomes the next release: the publish workflow
  runs `mise run publish-app`, which copies `latest/` to `releases/<n+1>/` and appends
  `{version, appVersion, canSkip}` to the manifest. Never add release folders or manifest
  entries by hand.
* `version` is the release number (1, 2, 3, ...); updates follow it. `appVersion` is the
  upstream version, shown to users only.
* `canSkip: false` makes the release a required stop: every update lands on it and passes
  its health check before going further. After publishing, the only allowed change is
  `canSkip` from `false` to `true` in `manifest.json`.
* Published releases and folders never change; to fix a release, publish a new one.

## Settings (`settings.json`)

Only deployment choices that change the compose belong here (a folder to mount, hardware
acceleration). Anything configured inside the app is set in the app itself. Every
setting has a default.

| Type | Value | `compose` |
|---|---|---|
| `path` | a folder the user picks from indexed external locations; unset = app data | a fragment, applied when a folder is picked |
| `enum` | one of `options[].value` | map option value → fragment |
| `bool` | `true` / `false` | map `"true"`/`"false"` → fragment |
| `generated` | a secret derived on the device; never shown or stored | none |

Field keys: `key` (UPPER_SNAKE, also the env var name; `APP_`, `FHS_`, `COMPOSE_`
reserved), `type`, `label`, optional `help`, `editable` (default `true`; `false` = chosen
at install only), `default` (required for `enum` and `bool`), `options` (`enum`).

Fragments merge into the stock compose with compose's own rules (`docker compose -f stock
-f fragment config`): they add and override; a volume with the same target replaces the
stock one. `path` fragments must bind with long syntax and
`"bind": {"create_host_path": false}`, so a missing drive fails the start instead of
filling the system disk.

## Compose and health check

* Values reach the compose as `${KEY}`, plus platform values `APP_ID`, `APP_DATA_DIR`,
  `APP_SEED`, `APP_PASSWORD`. Data lives under `${APP_DATA_DIR}`; named volumes,
  `env_file`, floating tags and SELinux `:z`/`:Z` are rejected.
* Every service sets `restart: always` or `restart: unless-stopped`.
* `health-check.sh` runs as `bash -euo pipefail` from the release folder, 5 s per run.
  Available tools: bash, coreutils, grep, sed, gawk, jq, curl, docker compose.

## Adding an app

1. `mise run new-app <app-id> <port>` (copies `_template/`).
2. Fill in `<app>/latest/` and add a `catalog.json` entry.
3. `mise run validate`, then open a PR. CI also installs `latest/` and, once published,
   updates from the last release to `latest/` (`mise run ci-run`).

## Tooling

mise pins shellcheck and shfmt (`mise install`) and runs every command. The scripts are bash and need
jq and docker on the host, like the device. `scripts/render.sh` is the only renderer: the
agent runs it on the device, CI runs it here.

```
scripts/
  validate-store.sh, render.sh, new-app.sh, publish.sh, ci-run.sh   commands
  *.test.sh                                                        their tests
```

* `mise run validate`: strict checks and a render of every settings combination (needs
  docker; `SKIP_RENDER=1` skips renders, `BASE_REF=<ref>` checks published history).
* `mise run render <release-dir> <app-id> [values.json]`: the compose a device would run.
* `mise run ci-run install|update <app-id>`: runs the app like a device (pulls images).
* `mise run publish-app <app-id>`: used by the publish workflow only.
* `mise run test`: the tooling's tests (need docker).
* `mise run lint`: shfmt format check and shellcheck (`lint-fix` formats).
