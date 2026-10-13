# Casa CFW-3212 features — what the port changes and how each is kept

Every Casa-specific behaviour the converter adds on top of upstream QManager, where
it lives, what checks it automatically, and when it was last seen working on a
router. Update this file in the same commit as any converter change.

Public, user-facing wording lives in `CFW3212_JTOOLEY_CHANGELOG.md`; this file is
for whoever maintains the port.

## Porting a new upstream version (do every time)

1. `bash qmanager/casa_conversion/build-casa-port.sh --version vX.Y.Z --ref-dir <ref> --force --skip-build`
   and fix each patch whose anchor moved. A patch that is no longer needed must
   say why in a `log` line, never just stop matching.
2. Type-check the converted tree before spending a CI run: copy
   `qmanager/qmanager_work_vX.Y.Z_casa` to a scratch dir, `bun install --frozen-lockfile
   --ignore-scripts`, add the standard `next-env.d.ts`, run `tsc --noEmit -p .`.
3. **Dropped-change gate.** Check the new conversion against the last released
   build's Casa delta:

   ```bash
   python3 scripts/casa-delta-compare.py check \
     qmanager/casa_conversion/casa-delta/<last casa tag>.json \
     <upstream vX.Y.Z checkout> qmanager/qmanager_work_vX.Y.Z_casa \
     --accept qmanager/casa_conversion/casa-delta-accept.txt
   ```

   Every `LOST`/`MISSING` line is a Casa change that did not make it into the
   new build. Fix the converter, or, when the loss is intended (upstream fixed
   it, the UI it patched is gone), add it to `casa-delta-accept.txt` with the
   reason. CI runs the same check after every build and fails on anything
   unreviewed.
4. Walk the feature table below for anything the gate cannot see: behaviour that
   depends on upstream code the Casa patch replaced (example: the v0.1.12 Casa
   Scheduled Reboot time-zone fix lived in crond code that v0.1.14 removed;
   the gate flags the lost lines, the table says what to re-test).
5. Live checks on one `1.1.x` and one `1.2.24.0` box (column "Live").
6. After publishing, commit the build's `casa-delta-snapshot-<casa tag>` artifact
   as `casa-delta/<casa tag>.json` so the next port is checked against it.

## Features

Live = last confirmed on a router (box, date, build). "—" = not yet tested on a router.

### Install, update, uninstall

| Feature | Implemented by | Automatic check | Live |
|---|---|---|---|
| Installs from `/usrdata` on a stock box, offline, bundled Entware (.ipk) + vendored fallback | `templates/install_cfw3212.sh`, `vendor/` | converter safety checks | Box 1, 2026-10-13, v0.1.16-cfw3212.1 (fresh install) |
| Install/update unpacks on flash (`/usrdata/qmanager_stage`), 40 MB free-space check, boot cleanup | installer, `patch_casa_stage_boot_cleanup_cfw3212` | safety checks | Box 2, 2026-10-12 (RC via Software Update) |
| Software Update: Casa package repo only, restart services then **Reboot required** (no auto reboot, no sign-out, no blind reload) | `templates/update_cfw3212.sh`, `patch_software_update_v14_cfw3212` | safety checks | Box 1, 2026-10-13 (public release) |
| Version Management install (rollback) uses the same flow | same | — | Box 1, 2026-10-11 |
| Software Update **Reboot now** logs a `user` reboot | `templates/update_cfw3212.sh` | delta gate | Box 1, 2026-10-13 |
| Release notes switch Joetooley / Rus \| Ame / Dr. D | `patch_software_update_v14_cfw3212` | — | Box 1, 2026-10-11 |
| Upgrade from public `v0.1.12-cfw3212.21` keeps password and settings | installer | — | Box 4 (1.2.24.0) and Box 1 (1.1.79.0), 2026-10-10 |
| Uninstall: stops every `qmanager*` unit, removes VO rules, carrier-block ports, DNS repair, all files (incl. `qcmd_test`); keeps `/etc/qmanager` unless `--purge` | `templates/uninstall_cfw3212.sh` | — | Box 1, 2026-10-13 |
| One-line install/uninstall scripts pinned to the release tag | workflow "Write install scripts" | — | Box 1 dry run, 2026-10-11 |
| Services get the Casa PATH (`/etc/qmanager.env`); explicit enable list incl. `qmanager-sites` (v0.1.17+) | installer | — | Box 1, 2026-10-13 (v0.1.16) |

### Networking and DNS

| Feature | Implemented by | Automatic check | Live |
|---|---|---|---|
| IP Passthrough off by default (once per box) | installer marker `ippt_default_off_applied` | — | Box 1, 2026-10-10 |
| IP Passthrough page: Disabled / Enabled (Ethernet) only, prop-driven card | `write_ippt_card_cfw3212` (+ `_v16`, detects `ippt-strip.tsx` or v0.1.17 `status-strip.tsx`), `write_ippt_backend_cfw3212` | delta gate (caught the v0.1.17 regression) | — on v0.1.17 |
| IPPT disable clears stuck `service.ip_handover.*` | `patch_casa_ippt_disable_clears_service_cfw3212` | — | v0.1.16 port |
| DNS repair: reconciler + watcher (repair within ~2 s of a reconnect), 45 s link-up grace, dead-first-server pruning | installer templates (`qmanager_dns_reconcile`, `qmanager_dns_watch`) | — | Box 2, 2026-09-28; dead-DNS fix 2026-10-11 |
| Custom DNS on Casa (dnsmasq restart, staging in /tmp, reconciler re-run) | `patch_casa_custom_dns_cfw3212` | converter greps | v0.1.16 port |
| Carrier remote management (TR-069 / LwM2M) off + ports blocked | installer `qmanager_carrier_block` | — | Box 1, 2026-10-11 |
| Carrier DNS shown correctly (one-line dual-stack CGCONTRDP) | `patch_casa_cgcontrdp_dualstack_cfw3212` | — | v0.1.16 port |
| Port firewall for 9000/9080 starts (PATH incl. `/usr/sbin`) | installer, `qmanager.env` | — | Box 1, 2026-10-13 |

### Video Optimizer

| Feature | Implemented by | Automatic check | Live |
|---|---|---|---|
| Off / Narrow / Broad; Narrow = DNS-learned video IPs only via Go helper | `patch-casa-video-selective.py`, `video-selective/` | helper unit tests in CI, delta gate | Narrow: Box 2 field test 2026-10-12; Broad: Box 4 2026-10-10 |
| v0.1.17: Narrow hands off before upstream's argv build; rule now applied by ExecStartPost `--rule-up` | same | delta gate | Box 1, 2026-10-13, v0.1.17 dev: Narrow, Broad, Off |
| Traffic Engine ensure timer (60 s): re-adds the rule after a flush, restarts a dead engine; helper cleanup only when Narrow chains exist | installer (from v0.1.17; never enabled on v0.1.16), `patch-casa-video-selective.py` | — | Box 1, 2026-10-13: ensure run by hand in Narrow (no-op), Broad (restored a deleted rule), Off (adds nothing) |
| tpws pinned to zapret v72.13 + hash, `--user=www-data` | same | converter | Box 4, 2026-10-10 |
| Uninstall/disable removes all VO and Force-TCP rules | uninstall, `--clear-selective` | — | Box 4, 2026-10-10 |

### Modem, recovery, reboots

| Feature | Implemented by | Automatic check | Live |
|---|---|---|---|
| All reboots via Casa managed reset (reason recorded) | `patch_casa_managed_reboot_cfw3212`, `patch_casa_reboot` | safety checks | Box 1, 2026-10-13 |
| Reboot history: one crash.log entry labels one boot | `patch-casa-reboot-cause.py` | converter | Box 1, 2026-10-13 |
| Watchdog: Tier 1 = Casa RDB reconnect, cooldown 120 s, Tier 2 (radio) and Tier 3 (SIM) off with notices, exits cleanly on stop | `patch_casa_watchcat_*`, `patch_casa_watchdog_ui_single_sim_cfw3212` | safety checks, delta gate | Box 2 ladder run, 2026-09-27 (v0.1.16 dev) |
| Watchdog skips recovery on stale ping data | v0.1.16: Casa ping-health patch; v0.1.17+: upstream `conn_state.sh` | safety checks (version-aware) | — on v0.1.17 |
| Scheduled Reboot / Tower Lock schedule: systemd timers, re-armed by the installer; follow the router zone via `/etc/localtime` (`qmanager_timezone_apply`) | `patch_casa_scheduled_reboot_cfw3212`, `patch_casa_timezone_apply_cfw3212`, installer | — | arm/disarm + timer fired, Box 1, 2026-10-13 (v0.1.16); zone change moves timers live (UTC→US/Eastern→UTC), Box 1, 2026-10-13 (v0.1.17 dev) |
| Single SIM slot: no SIM Slot switch, no Watchdog SIM failover | `patch_casa_single_sim_slot_cfw3212`, watchdog patches | safety checks | — |
| APN changes through the Casa connection manager | `patch_casa_apn_apply_cfw3212` | — | — (no real APN change yet) |
| Band locks persist across reboot; notice when 5G Architecture / Network Type blocks a lock | `patch_casa_band_locking_persist_cfw3212`, `patch-casa-band-arch.py` | converter | Box 1, 2026-10-10 |
| QCAINFO: short NR SCC line with SCell state reads the real PCI (no fake "SCC handoff PCI 1 -> 2") | `patch-casa-qcainfo-scc.py` | converter | parser tested on Box 1 BusyBox, 2026-10-13; raw line capture running |
| Network Events: secondary-carrier band change at the same count is logged ("NR carriers changed (+N25, -N66)"), settled ~9 s; count changes stay upstream's | `patch-casa-scc-band-change.py` | converter | 10 simulated sequences on Box 1 BusyBox, 2026-10-13 |
| Poller boot identity fix | `patch_casa_poller_boot_identity_cfw3212` | — | v0.1.11 era |
| ICCID profile auto-apply only when explicitly enabled | `patch_disable_profile_auto_apply` | safety checks | Box 2, `.22.19.dev` |

### UI and branding

| Feature | Implemented by | Automatic check | Live |
|---|---|---|---|
| Board photo on Home | `patch_casa_device_photo_cfw3212` | — | Box 1, 2026-10-11 |
| Reconnect Network progress window | `templates/components/nav-user.tsx` (3-way merged, base in `templates/upstream-base/`) | merge fails on conflict | Box 1 build check, 2026-10-13 |
| Donate: separate PayPal / Venmo / Cash App row for the port | `patch-casa-donate.py` | converter, delta gate | strings in Box 1 build, 2026-10-13 (not visually checked) |
| Support page: Casa issues + release notes rows | `patch-casa-support.py` | converter | strings in Box 1 build, 2026-10-13 (not visually checked) |
| Tailscale: Tiny build, in-place update, Check for updates, shell hint | `patch_casa_tailscale_*` | converter | v0.1.16 port |
| Email alerts: msmtp installs without opkg | `patch_email_alerts_casa_msmtp` | converter | install only; send — |
| Hardening (AI-62): narrow sudoers, iptables/Tailscale helpers, SHA-512 SSH password, cookie/CORS | `patch_ai62_*` | safety checks | — |

## Upstream changes taken as-is (no Casa patch) — re-check on each port

- Conn Uptime = internet-reachable timer from the ping daemon (resets on poller restart). Same upstream.
- v0.1.17 Sites monitor: upstream default on (13 sites every 5 min, ~20–30 MB/day of data, estimate). Kept on by owner decision 2026-10-13.
- v0.1.17 DNS lookup timing: probes the first `resolv.conf` server; works on Casa because the DNS repair keeps that server live.
