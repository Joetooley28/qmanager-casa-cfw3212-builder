# Casa CFW-3212 QManager OTA GUI Update Conversion Workflow

This folder contains the repeatable workflow for turning an upstream
`dr-dolomite/QManager` tag into a Casa CFW-3212 package with a Casa-safe
manual OTA update flow in the QManager GUI.

The converter uses `qmanager/qmanager_work_v0.1.9_casa` as the current Casa
reference patch set. It fetches upstream into a new versioned work folder,
applies the Casa overlays, runs safety checks, and builds artifacts when
Node and Bun are available.

## Basic usage

From the workspace root:

```sh
bash qmanager/casa_conversion/build-casa-port.sh --version v0.1.10
```

This creates:

```text
qmanager/qmanager_work_v0.1.10_casa
```

To select the newest real upstream app release automatically:

```sh
bash qmanager/casa_conversion/build-casa-port.sh --version latest --skip-build
```

The `latest` resolver intentionally ignores non-app releases such as
`language-packs`; it only selects tags like `v0.1.23` when the release contains
both `qmanager.tar.gz` and `sha256sum.txt`.

If Node or Bun are not on `PATH`, the script still fetches, patches, and checks
the Casa tree, then prints the exact build command to run later.

## Rebuild an existing target

```sh
bash qmanager/casa_conversion/build-casa-port.sh --version v0.1.10 --force
```

`--force` only permits replacement of a folder matching
`qmanager_work_<version>_casa`. The old known-good `qmanager/qmanager_work`
folder is not targeted by this workflow.

## Check only

```sh
bash qmanager/casa_conversion/build-casa-port.sh --version v0.1.10 --skip-build
```

## Use a different Casa reference tree

```sh
bash qmanager/casa_conversion/build-casa-port.sh \
  --version v0.1.10 \
  --ref-dir qmanager/qmanager_work_v0.1.9_casa
```

## Installer Templates

The Casa installer entrypoints live in `templates/`:

- `install_cfw3212.sh`
- `uninstall_cfw3212.sh`
- `qmanager-installer-cfw3212.sh`
- `ip-passthrough-card.tsx`

The converter copies these templates into each generated Casa work tree when
the reference tree does not already provide a newer Casa overlay.

## What gets applied

- Casa installer and uninstaller: `install_cfw3212.sh`,
  `uninstall_cfw3212.sh`.
- Casa one-shot bootstrap: `qmanager-installer-cfw3212.sh`.
- Casa build staging: `build.sh`.
- Casa IP Passthrough frontend: Casa-locked page with Ethernet
  enable/disable only.
- Casa IP Passthrough backend: RDB `ip_handover`, no QMAP/QCFG writes.
- Casa-safe manual OTA GUI software updater:
  - checks the Casa package repo releases, not upstream QManager;
  - downloads converted `qmanager-cfw3212-<version>.tar.gz` packages;
  - requires the matching `.sha256` asset and verifies it with SHA-256;
  - installs only after the user confirms in the GUI.
- Auto-update remains disabled for Casa CFW-3212.
- Boot profile auto-apply disabled in `qmanager_poller`.

The converter patches `qmanager_poller` surgically so future upstream poller
changes are preserved where possible. The Casa poller patch only separates
unsupported boot-time modem reads and disables profile auto-apply.

Most rootfs path conversion is intentionally handled by `install_cfw3212.sh`
at install time, because the upstream package still carries RM520N-style
source paths under `scripts/`.

## Safety checks

The converter fails if it detects:

- `build.sh` staging RM520N install scripts.
- Missing `/usrdata/bin`, `/usrdata/qmanager/lib`,
  `/etc/systemd/system`, `9080`, or `9000` in the Casa installer.
- IP Passthrough backend QCFG/QMAP/reboot controls.
- IP Passthrough frontend USB composition controls.
- Updater paths that use upstream QManager releases directly.
- Enabled auto-updater scripts.
- Missing Casa package checksum verification.
- Missing Casa profile auto-apply block.
- Changed `dependencies/atcli_smd11` SHA-256.

It also runs `bash -n` over shell scripts and script-like files.

The workflow refuses to replace the Casa reference tree when the requested
target is the same path as `--ref-dir`; use `--skip-fetch` for check-only
validation of the reference tree.

## Output

When build tools are available:

```text
qmanager/qmanager_work_<version>_casa/qmanager-build/qmanager.tar.gz
qmanager/qmanager_work_<version>_casa/qmanager-build/sha256sum.txt
```

Every generated Casa work folder also gets:

```text
CFW3212_SMOKE_TEST_CHECKLIST.md
```

Use that checklist for manual router testing before publishing a Casa build.
