# Casa CFW-3212 QManager Builder

Looking for the newest Casa-ready build? Use the release/package repo:
**[Joetooley28/qmanager-casa-cfw3212-package](https://github.com/Joetooley28/qmanager-casa-cfw3212-package)**.

This repository contains the public Casa CFW-3212 QManager converter, builder,
and GitHub Actions workflow.

## Credit

QManager is built and maintained by **Rus | Ame** (`misuzu__` on Discord),
GitHub **[dr-dolomite](https://github.com/dr-dolomite)**. Huge thanks to Rus
for all the hard work building, maintaining, and sharing QManager with the
community. The upstream project is
**[dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N)**.

Joetooley built only the Casa CFW-3212 converter/package flow for making
QManager installable on the Casa CFW-3212.

It is the source of truth for building packages that are published to:

```text
Joetooley28/qmanager-casa-cfw3212-package
```

The files live under `qmanager/casa_conversion/` and are meant to be copied or
checked out into the existing local workspace layout.

## What This Variant Adds

- Uses upstream `dr-dolomite/QManager-RM520N`.
- Supports `--version latest`, filtering out non-app releases such as
  `language-packs`.
- Generates Casa release versions such as `v0.1.10-cfw3212.1`.
- Builds Casa CFW-3212 packages that check the official Casa package repo,
  download converted Casa tarballs, verify SHA-256, and install only after user
  confirmation.
- Bundles the full Entware runtime dependency set (lighttpd + modules, `sudo`,
  and their support libraries incl. the loader) into each package, so the
  no-internet install works on a clean stock router. The bundled `sudo` is
  pre-patched (ELF interpreter + RPATH repointed to `/usrdata/opt`, setuid
  preserved) so it needs no writable-root `/opt` symlink.
- Keeps manual SIM Profiles enabled and exposes ICCID-matched profile
  auto-apply as an explicit user toggle on the SIM Profiles page. It remains
  off until enabled by the user.
- Disables Watchdog backup-SIM recovery on Casa CFW-3212 single-SIM hardware,
  including stale Tier 3 config values from older builds.
- Keeps `qmanager_auto_update` disabled for Casa CFW-3212.

## Dev testing on a live router (no package release)

Day-to-day edits use branch **`dev`**: CI produces **workflow artifacts only**
(`.dev` version tags). Install on the modem with **`scripts/cfw3212-dev-load.sh`**
— see **[scripts/README.md](scripts/README.md)** for the full loop, hotpatch vs
full install, and when to promote to `main`. Workspace agents: also read
`AGENTS.md` in the CFW-3212 monorepo.

## GitHub Actions

The workflow lives at:

```text
.github/workflows/build-casa-package.yml
```

Default runs build downloadable artifacts only. Publishing official package
repo prereleases requires `create_release=true`, `dry_run=false`, and approval
of the protected `official-package-release` environment before the package
release token is exposed.

The generated prerelease title/body mark Actions-published builds as
`Actions-built, unverified` until live-router testing is complete. Release notes
preserve the upstream release link, SHA-256, internet install command,
no-internet/manual install commands, and Casa safety scope.

After live-router testing, run the **Mark Casa package release verified**
workflow with the Casa release tag. It edits the existing package release title
and notes in place without rebuilding or replacing the tested assets. The
workflow removes the unverified title label and changes the release-note status
line to say the package has been live-router verified.

## Basic Usage

```sh
bash qmanager/casa_conversion/build-casa-port.sh --version latest --skip-build
```

Use `--skip-build` while validating converter output. Build the package only
when ready for live-router testing.

See [`qmanager/casa_conversion/README.md`](qmanager/casa_conversion/README.md)
for detailed usage and safety checks.
