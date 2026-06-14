# Casa CFW-3212 QManager Builder

This folder contains the repeatable workflow for turning an upstream
`dr-dolomite/QManager-RM520N` tag into a Casa CFW-3212 package with Casa-safe
install and update behavior.

The public GitHub Actions builder lives in this same repository at
`.github/workflows/build-casa-package.yml`. The package/download repo remains
`Joetooley28/qmanager-casa-cfw3212-package`; router install and update flows
must continue to consume assets from that package repo only.

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
`language-packs`; it only selects tags like `v0.1.10` when the release contains
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

On fresh install and reinstall, `install_cfw3212.sh` idempotently creates
`/opt -> /usrdata/opt` (brief root remount read-write, then read-only) so
Entware helpers such as `sudo` resolve their baked-in `/opt/...` ELF paths.
It never overwrites existing `/usrdata/opt` contents. Uninstall leaves the
symlink in place; only `--purge` removes `/usrdata/opt` itself.

## Installer update behavior

The Casa installer is intentionally conservative about flash writes:

- Frontend, CGI, library, and binary files are compared before copying, so
  weekly updates skip unchanged files instead of deleting and rewriting the
  whole static web tree.
- Fresh installs still write the full tree once, but actual copies are paced
  with periodic `sync` calls to keep UBIFS flash cleanup and the hardware
  watchdog from being starved.
- The terminal installer prints progress counters during large sync sections so
  users can tell the modem is still working.
- The update worker flushes flash writes with `sync` before triggering reboot.

This behavior was added after live CFW-3212 testing showed that full rewrites of
the 484-file frontend tree could temporarily saturate CPU, RAM, and swap on
repeated installs.

## What gets applied

- Casa installer and uninstaller: `install_cfw3212.sh`,
  `uninstall_cfw3212.sh`.
- Casa one-shot bootstrap: `qmanager-installer-cfw3212.sh`.
- Casa build staging: `build.sh`.
- Casa IP Passthrough frontend: Casa-locked page with Ethernet
  enable/disable only.
- Casa IP Passthrough backend: RDB `ip_handover`, no QMAP/QCFG writes.
- Casa-safe package update path:
  - checks the Casa package repo releases, not upstream QManager;
  - downloads converted `qmanager-cfw3212-<version>.tar.gz` packages;
  - requires the matching `.sha256` asset and verifies it with SHA-256;
  - installs only after user confirmation.
- Auto-update remains disabled for Casa CFW-3212.
- ICCID-matched SIM Profile auto-apply is exposed as a runtime user toggle on
  the SIM Profiles page. It remains off by default, and when enabled applies
  matching profiles at boot and after user SIM-switch actions.
- Watchdog backup-SIM recovery is disabled on Casa CFW-3212 single-SIM hardware.
  Tier 3 is forced off even if stale config says it is enabled.
- System Health Check worker (`qmanager_health_check`): Casa binary paths
  (`/usrdata/bin`, `/usrdata/opt/bin`), sudoers and systemd locations,
  lighttpd listener checks on `9080`/`9000`, CGI PATH checks for
  `/usrdata/opt/bin`, and opt-in service handling for console/traffic.
  Applied by `patch_qmanager_health_check_paths_cfw3212` in a single
  non-overlapping pass so sudoers rewrites do not cascade.

The converter patches `qmanager_poller` surgically so future upstream poller
changes are preserved where possible. The Casa poller patch separates
unsupported boot-time modem reads and gates ICCID-matched profile auto-apply
behind the SIM Profiles UI setting.

Most rootfs path conversion is intentionally handled by `install_cfw3212.sh`
at install time, because the upstream package still carries RM520N-style
source paths under `scripts/`.

## Casa Web Service Port Map

QManager must coexist with Casa's stock web stack rather than replace it.
Live Box 2 testing on `v0.1.12-cfw3212.20.dev` verified this layout:

```text
Stock Casa UI             0.0.0.0:80      turbontc.service
Stock Casa remote UI path 0.0.0.0:8080    turbontc.service
Casa authenticate service 0.0.0.0:27068   da_authenticate.service
QManager HTTPS UI         0.0.0.0:9000    qmanager-lighttpd.service
QManager HTTP redirect    0.0.0.0:9080    qmanager-lighttpd.service
QManager web console      127.0.0.1:9081  qmanager-console.service / ttyd
```

Do not use generic `lighttpd.service` for QManager on Casa. Casa ships that
unit masked behind the stock web service. The installer removes any older
QManager-owned `lighttpd.service` override, masks generic `lighttpd` back to
Casa's stock state, and installs QManager's Entware web server as
`qmanager-lighttpd.service`.

Do not bind QManager console/ttyd to `8080`. Stock `turbontc.lua` binds both
`80` and `8080`; if QManager takes `8080`, `turbontc.service` starts and then
fails with `Could not bind to address. Address already in use`, leaving
`http://192.168.20.1/` closed. QManager's `/console` proxy therefore points to
the loopback-only ttyd backend on `127.0.0.1:9081`.

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
- Missing Casa profile auto-apply toggle block.
- Watchdog SIM-slot switching commands or backup-SIM UI controls left in the
  Casa output.
- Changed `dependencies/atcli_smd11` SHA-256.
- Upstream RM520N paths or `80/443` lighttpd labels left in
  `scripts/usr/bin/qmanager_health_check` after conversion.
- QManager web service or console config that tries to use Casa stock web
  ports (`80`, `443`, or console backend `8080`) instead of
  `qmanager-lighttpd` on `9080`/`9000` and ttyd on `127.0.0.1:9081`.

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
