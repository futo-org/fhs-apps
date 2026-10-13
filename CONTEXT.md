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
An app's `latest/` folder, the only place authors edit; each merge that changes it becomes the next release.
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

**Install record**:
The device's statement of which release an installed app is on. It changes only after a step has started and passed its health check, so it is never ahead of what runs.
_Avoid_: installed manifest, state

**Update path**:
The releases an update lands on, in order: every required stop above the installed release, then the latest.
_Avoid_: plan, chain

**Rollback**:
Returning an app to the release and data it had before a failed step, from that step's snapshot. Only the failed step is undone; earlier steps of the path stay landed.
_Avoid_: revert, downgrade

