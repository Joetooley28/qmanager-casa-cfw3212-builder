# Casa CFW-3212 QManager GUI Button OTA Update Converter

This repository is specifically for building Casa CFW-3212 QManager packages
that make the **Software Update** button in the QManager GUI perform a
Casa-safe OTA-style package update.

It is intentionally separate from the original standalone converter repository
so the original converter can remain unchanged.

The files live under `qmanager/casa_conversion/` and are meant to be copied or
checked out into the existing local workspace layout.

## What This Variant Adds

- Targets the GUI button update flow: **System Settings -> Software Update**.
- Uses upstream `dr-dolomite/QManager`.
- Supports `--version latest`, filtering out non-app releases such as
  `language-packs`.
- Generates Casa release versions such as `v0.1.23-cfw3212.1`.
- Makes the QManager GUI update button check Casa package releases, download
  converted Casa tarballs, verify SHA-256, and install only after user
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
