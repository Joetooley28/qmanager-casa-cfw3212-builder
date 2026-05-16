# Casa CFW-3212 QManager Builder

This repository contains the public Casa CFW-3212 QManager converter, builder,
and GitHub Actions workflow.

It is the source of truth for building packages that are published to:

```text
Joetooley28/qmanager-casa-cfw3212-package
```

The files live under `qmanager/casa_conversion/` and are meant to be copied or
checked out into the existing local workspace layout.

## What This Variant Adds

- Targets the GUI button update flow: **System Settings -> Software Update**.
- Uses upstream `dr-dolomite/QManager-RM520N`.
- Supports `--version latest`, filtering out non-app releases such as
  `language-packs`.
- Generates Casa release versions such as `v0.1.10-cfw3212.1`.
- Makes the QManager GUI update button check Casa package releases, download
  converted Casa tarballs, verify SHA-256, and install only after user
  confirmation.
- Keeps `qmanager_auto_update` disabled for Casa CFW-3212.

## GitHub Actions

The workflow lives at:

```text
.github/workflows/build-casa-package.yml
```

Default runs build downloadable artifacts only. Publishing official package
repo prereleases requires `create_release=true`, `dry_run=false`, and approval
of the protected `official-package-release` environment before the package
release token is exposed.

The generated prerelease title/body mark bot-published builds as
`bot-built, unverified` until live-router testing is complete. Release notes
preserve the upstream release link, SHA-256, internet install command,
no-internet/manual install commands, and Casa safety scope.

## Basic Usage

```sh
bash qmanager/casa_conversion/build-casa-port.sh --version latest --skip-build
```

Use `--skip-build` while validating converter output. Build the package only
when ready for live-router testing.

See [`qmanager/casa_conversion/README.md`](qmanager/casa_conversion/README.md)
for detailed usage and safety checks.
