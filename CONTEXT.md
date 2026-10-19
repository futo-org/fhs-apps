# FHS app store

How apps are packaged for FHS: what the store publishes and what a device installs and updates from.

## Language

**Store**:
This repository as cloned on a device; the only source of apps.
_Avoid_: repo, registry

**Catalog**:
The store's list of apps that can be installed.

**Manifest**:
An app's list of releases, ordered by release number.

**Release**:
One installable, immutable snapshot of an app's package: its compose, settings and scripts.
_Avoid_: version (alone), step

**Release number**:
A release's identity: an integer the store owns, one higher than the previous release. Increases even when the app version does not.
_Avoid_: revision, build number

**App version**:
The upstream version a release ships (`v1.135.3`). A display label only; never compared.
_Avoid_: version (alone), tag

**Can skip**:
Whether an update may pass over a release. A release that cannot be skipped is a **required stop**: every update lands on it and passes its health check before going further.
_Avoid_: skippable, optional release

**Latest**:
The release with the highest release number.

**Release folder**:
A published release's files, frozen under `releases/<release number>/`; never edited.

**Working copy**:
An app's `latest/` folder, the only place authors edit; a PR that changes it also adds the next release, an exact copy made by `mise run release`.
_Avoid_: draft

**Health check**:
A release's script whose exit status says whether the app is serving: zero means healthy, anything else means not.
_Avoid_: health probe, ping

**Setting**:
A deployment choice a release asks for: something that changes how the release's compose runs on this device, such as a host folder mounted into the app. Declared in the release's settings schema with a key, a type and an optional default. Configuration inside the app is not a setting; the app's own interface handles it.
_Avoid_: option, config, parameter

**Editable**:
A setting the user may change after install. A setting that is not editable is chosen once, at install.

**App settings**:
The setting values a user chose for one installed app. Holds only choices; a setting the user never set takes the release's default each time it is used.
_Avoid_: config, env

**Generated secret**:
A setting no one types or sees, derived from the device and the app each time it is needed, so it is never stored.
_Avoid_: random password

**App data**:
The app's own folder on the device's internal storage. Everything the app keeps lives here unless a setting points part of it at an external location.
_Avoid_: internal (the server's "internal" means the user's files), app storage

**External location**:
A folder on storage the server has indexed outside the device's internal disk, such as a network share, that a setting can point part of an app at.
_Avoid_: external mount (alone), drive

**Rendered compose**:
The one compose file an installed app runs from: the release's stock compose with the compose changes its settings call for, filled in with the chosen values.
_Avoid_: generated compose, override

**Stock compose**:
The compose a release ships, kept close to upstream's; every render starts from it.
_Avoid_: base compose, template

**Fragment**:
A piece of compose that a setting's choice turns on, merged into the stock compose by docker compose's own rules.
_Avoid_: override, patch, overlay

**Renderer**:
The store's `generate-compose.sh`, the only code that turns a release and app settings into the rendered compose. CI runs it to validate every release; devices run it to install, update and change settings.
_Avoid_: generator, templater

**Platform variables**:
The values every app gets from the device: its id, its app data folder, its app seed and its app password.
_Avoid_: env (alone), system settings

**Install record**:
The device's statement of which release an installed app is on. It changes only after a step has started and passed its health check, so it is never ahead of what runs.
_Avoid_: installed manifest, state

**Update path**:
The releases an update lands on, in order: every required stop above the installed release, then the latest.
_Avoid_: plan, chain

**Rollback**:
Returning an app to the release and data it had before a failed step, from that step's snapshot. Only the failed step is undone; earlier steps of the path stay landed.
_Avoid_: revert, downgrade

**Operation**:
One install, update, settings change, start, stop or uninstall of one app. An app runs one operation at a time.
_Avoid_: job, task, action

**Preflight**:
The checks before an update changes anything: the store refreshed, the install record valid, the running app matching its rendered compose.
_Avoid_: precheck, validation

**Snapshot**:
A read only copy of app data, taken after the old release stops and before the new one starts; what a rollback restores.
_Avoid_: backup

**Health gate**:
The wait after a start for the health check to pass. An operation commits only after it passes; it fails after 30 minutes, or sooner when a service keeps restarting.
_Avoid_: readiness check

**Journal**:
What an operation writes before its first change and deletes last, so an operation a crash cut short is finished or undone at the next start.
_Avoid_: lock file, state file

**Last result**:
How the latest operation on an app ended (succeeded, rolled back, failed or interrupted), with its reason and output. Kept until the next operation or until dismissed.
_Avoid_: error, last error

