# Casa CFW-3212 QManager Updater Conversion Workflow

This repository contains the updater-enabled Casa CFW-3212 conversion workflow.
It is intentionally separate from the original standalone converter repository
so the original converter can remain unchanged.

The files live under `qmanager/casa_conversion/` and are meant to be copied or
checked out into the existing local workspace layout.

## What This Variant Adds

- Uses upstream `dr-dolomite/QManager`.
- Supports `--version latest`, filtering out non-app releases such as
  `language-packs`.
- Generates Casa release versions such as `v0.1.23-cfw3212.1`.
- Adds a manual-only GUI updater that checks Casa package releases, downloads
  converted Casa tarballs, verifies SHA-256, and installs only after user
  confirmation.
- Keeps `qmanager_auto_update` disabled for Casa CFW-3212.

## Basic Usage

```sh
bash qmanager/casa_conversion/build-casa-port.sh --version latest --skip-build
```

Use `--skip-build` while validating converter output. Build the package only
when ready for live-router testing.

See [`qmanager/casa_conversion/README.md`](qmanager/casa_conversion/README.md)
for detailed usage and safety checks.
