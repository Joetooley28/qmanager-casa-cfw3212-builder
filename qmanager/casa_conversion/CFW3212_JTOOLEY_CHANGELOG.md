# Casa CFW-3212 Joetooley Changelog

## What's Working

- Web Console works. On installs with internet, `ttyd` gets pulled in and started automatically, and `/console/` is live once that helper is in place.
- System Health Check has been pointed at the Casa paths, services, lighttpd ports, and the `/usrdata/opt/bin` helper locations it actually needs to look at.
- QManager now installs on a clean, stock router with no internet and no special "rooting." The installer bundles everything it needs (the web server, `sudo`, and their support libraries) inside the package, and the bundled `sudo` is pre-built so it works without the old root-level `/opt` shortcut. Routers with a writable root still get the `/opt` shortcut created for good measure, but it's no longer required.
- Tailscale runs from the QManager UI using the lighter Tiny Tailscale build. You do your own Tailscale login from the UI.
- Ookla Speedtest works once the `speedtest` helper is installed. install handles if connected to internet.
- Email Alerts can install and remove `msmtp` through the Casa Entware package flow. The Gmail app-password setup and an actual test send are the last things to confirm working on your end. (wired up, not tested yet) 
- Discord Bot backend is now part of the Casa package, so you can plug in your own Discord bot token and user ID and try the UI. (wired up, not tested yet)
- SIM Profiles can be saved, applied, deleted, and deactivated by hand on Casa. That includes APN, TTL/HL, IMEI, and the modem reboot apply step. The blind "auto-apply by ICCID" behavior is still off by default.
- Custom DNS works from the QManager UI, including custom upstream resolvers for LAN clients without changing DHCP leases or rebooting the router.
- IP Passthrough keeps the router/LAN DNS correct automatically: a background reconciler restores carrier DNS when passthrough is turned off and falls back to public DNS only when carrier DNS is actually unreachable. The dashboard shows whether IP Passthrough is on and where the router/LAN DNS is currently coming from.
- The Reconnect Network menu action now uses Casa's connection manager path instead of forcing a modem deregister/re-register.
- Reconnect Network now keeps a small progress window open so you can watch elapsed time, network registration, WAN IP, and internet status while the router comes back online.
- Software Update → Version Management can now install a different version (including rollbacks). After the download verifies, the Install button switches to "Install Now" so the staged package actually gets applied instead of being left on disk.
- A handful of upstream modem-management actions stay blocked or limited on Casa because they'd let you push the modem into a state we don't want it in.

## v0.1.12-cfw3212.21

- Band Locking now sticks across a reboot. On this hardware, saving a band selection (including "Select all") applied right away, but after a reboot any bands the carrier profile keeps hidden came back unselected — so your saved choice didn't fully survive the reboot. Saving bands in QManager (or completing the first-run setup's band step) now makes your selection the one the modem keeps after rebooting, instead of the carrier's hidden-band policy re-applying on the next boot. QManager owns the band set on this device once you save; the modem's hardware still decides which bands are actually available, and Band Failover still protects you if a locked band loses service.
- After a Software Update install, if the browser session drops while QManager's web server restarts, the page now reloads the **Software Update** page instead of jumping to the dashboard/home page, so you land back on the install status (and any "reboot required" prompt) where you started.
- Fixes the Custom DNS page wrongly warning that "IP Passthrough is bypassing dnsmasq." On Casa, IP Passthrough is a routed handover — the downstream device still gets the modem as its DNS server and routes lookups through the modem's dnsmasq — so Custom DNS *does* apply to passthrough clients. The page no longer shows the misleading bypass notice.
- Fixes IP Passthrough not actually engaging after it had been turned off and on again. The toggle now keeps Casa's service-level handover flag (`service.ip_handover.enable`, which the stock QCMAP engine reads) in sync — enabling sets it on so the carrier IP is handed to your downstream device, instead of only flipping the per-profile flag and leaving passthrough silently inactive (dashboard showing "IPPT On" while the device still got a normal LAN IP).
- The `--purge` uninstall now also removes QManager's DNS changes from the router's persistent dnsmasq config (`/etc/data/dnsmasq.conf`) — both the Custom DNS upstreams and the automatic public-DNS fallback block (`1.1.1.1` / `8.8.8.8`) the IP Passthrough reconciler adds when carrier DNS is down — and restarts dnsmasq so the router/LAN resolver reverts to stock/carrier DNS. A plain uninstall still leaves these in place (alongside other preserved config) for reinstall.
- Fixes the first-run setup wizard not applying its **default** network/band choices. Choosing **Automatic** on the "Preferred network" step now actually sets the modem to automatic RAT (LTE + 5G, SA and NSA) instead of skipping the step, and choosing **All bands (default)** on the band step now clears any existing band lock instead of leaving it in place. Previously these defaults were treated as "do nothing," so if the modem still carried a network-mode or band lock from earlier use, the wizard's "Automatic"/"All bands" left that old setting active. Picking a non-default option already worked; this only changes the default choices.

Uninstall/`--purge` cleanup, on top of the above — closes the remaining "restore to stock" gaps so a `--purge` uninstall leaves the router the way it shipped:

- The uninstaller now tears down QManager's firewall rules immediately and synchronously, instead of asking the firewall service to stop in the background and then deleting its helper script. Previously the firewall rules (the QManager web-UI port protections) could stay active until the next reboot.
- The IP Passthrough DNS reconciler's scheduled timer is now fully removed on uninstall. Before, only its service file was cleaned up, so a stale timer entry was left behind.
- `--purge` now also removes the dnsmasq backup snapshots QManager's DNS helpers had saved next to the router's persistent dnsmasq config, and the purge step itself no longer writes a new backup file there (its safety copy goes to RAM instead, sparing flash).
- `--purge` now removes the Entware startup unit (`rc.unslung.service`) along with the Entware tree it pointed at, instead of leaving a broken service entry behind.
- Uninstall now clears all of the Software Update check's temporary cache files in `/tmp`, not just two of them.

## v0.1.12-cfw3212.20

This is the first public release since `.19`. It rolls up all of the stock-UI coexistence, IP Passthrough DNS, dashboard, and security/flash-health work that was previously only sideloaded for testing.

**Stock UI coexistence**

- QManager now uses its own `qmanager-lighttpd` service for the QManager web UI on ports `9080` and `9000`, instead of taking over Casa's generic `lighttpd` service name. This lets Casa's stock web UI stay on its normal port `80` path while QManager runs beside it.
- Upgrading from earlier builds removes the old QManager-owned `lighttpd.service` override, restores Casa's masked `lighttpd` state, and starts the stock `turbontc` web UI service when it is present.
- The optional QManager web console now uses an internal backend on `9081` instead of `8080`, because Casa's stock UI also uses `8080` while starting its normal web service.
- System Health Check now reports QManager's web service as `qmanager-lighttpd.service`, so the service check matches the new coexistence layout.

**IP Passthrough DNS and dashboard**

- Keeps Casa's router/LAN DNS working automatically under IP Passthrough. A background reconciler checks every 30 seconds whether the router/LAN resolver can reach real carrier DNS and corrects it — it restores carrier DNS when IP Passthrough is turned off and only falls back to public DNS when no carrier resolver answers.
- The reconciler is probe-based: it treats carrier DNS as working if any carrier nameserver (IPv4 or IPv6) actually answers, instead of assuming DNS is broken just because the IP Passthrough placeholder `192.0.0.1` is present in `resolv.conf`. It only rewrites the dnsmasq config when something needs to change, so it adds no steady-state flash wear.
- Fixes the dashboard Online/Offline badge falsely showing Offline (DNS) under IP Passthrough while the internet actually works. The connectivity probe now uses the normal system resolver (which includes the carrier IPv6 nameservers that answer under IPPT) instead of assuming the IPv4 handover placeholder `192.0.0.1` means DNS is down.
- Adds two small status badges next to the dashboard Online/Offline badge: one shows whether IP Passthrough is On or Off, and one shows where the router/LAN DNS is currently coming from — Carrier, your QManager Custom DNS, or a public fallback. The DNS-source badge describes the router/LAN resolver only; a device in IP Passthrough mode still receives DNS straight from the carrier, which the router cannot report on.

**System Health Check fixes**

- Fixes a sudoers false failure. On Casa, QManager's sudo helper rules live under `/usrdata/opt/etc/sudoers.d/qmanager`; the health check now treats that installed helper file as valid instead of failing because the Casa sudo shim does not print a normal `sudo -l` listing.
- Fixes a DNS (`net.dns`) false failure on routers with IP Passthrough active. Casa leaves `192.0.0.1` in `/etc/resolv.conf`, which does not answer DNS even though dnsmasq on the LAN bridge still resolves correctly; the health check now queries the bridge LAN resolver instead of the poisoned nameserver.

**Flash-health and security hardening**

- Reduces flash wear from the data-usage counter. The poller now keeps the every-few-seconds hot counter state in `/tmp` and flushes the durable `/usrdata/qmanager/data_used.json` copy on a bounded cadence and important events instead of rewriting persistent flash every poll cycle.
- Turns off QManager's syslog forwarding by default on Casa, because Casa stores syslog under `/usrdata/log/messages`. The normal capped QManager log stays in `/tmp`.
- Hardens CGI handling by failing closed if the auth library is unavailable and by rejecting oversized POST bodies before reading them into memory.
- Adds the `Secure` attribute to QManager login cookies and removes wildcard CORS headers from CGI responses; the UI and API are served from the same HTTPS origin.
- Removes the old world-writable cron spool setup behavior while preserving QManager's current schedule writers, and tightens `/etc/qmanager` file and directory permissions.
- Narrows QManager sudo helpers to known `qmanager-*`, `tailscaled`, and `dnsmasq_service@0.service` units instead of allowing any `systemctl` target, aligns the Custom DNS sudo rules with the Casa `/tmp` staging file and `systemctl` dnsmasq reload path, and drops the unused broad `crontab` sudo rule.
- The installer now protects already-Casa `/usrdata/opt/...` paths during its install-time path normalization, preventing repeated `/usrdata` prefixes in installed helper scripts.

## v0.1.12-cfw3212.19

- The dashboard/status IP Passthrough fields now follow Casa's real IP handover state instead of always showing disabled. This matches the Local Network → IP Passthrough settings page, which was already reading Casa's RDB state correctly.
- The upstream Quectel MPDN/QMAP/USB-mode IP Passthrough probes remain blocked on Casa; this change only reads Casa's safe RDB status keys for display.

## v0.1.12-cfw3212.18

- Software Update restores the **Current Release Notes** card (Joetooley / Rus | Ame toggle) and **Version Management** dropdown from one check on page load, like build `.16`. **Check for Updates** forces a fresh GitHub pull.
- Software Update caches GitHub release and changelog responses on the router so repeat visits are much faster than a cold check.
- Software Update → Version Management no longer shows a duplicate **Install Now** in the staged-ready banner; install or reinstall from the version dropdown row.
- Dev sideload builds (`.dev` tag) show release notes by falling back to this build’s changelog when the dev tag is not published on the package repo.

## v0.1.12-cfw3212.17

- Software Update → Version Management works with the router's bundled `jq` build again. The `.16` rollback-history filter used a regex helper that is not available on the router, which could leave the version dropdown empty. The filter now uses a compatible literal split instead.
- Uninstall cleanup now restores Casa's stock masked `lighttpd` state after removing the QManager web service override.
- `--purge` cleanup now removes QManager-owned sudoers include residue and removes `/opt` only when it is the QManager-created shortcut to `/usrdata/opt`.
- Installs now start the Casa firewall service immediately, so curl installs, offline installs, and in-UI updates all finish in the same ready state without waiting for a reboot.

## v0.1.12-cfw3212.16

- Software Update → Version Management lists older releases again, so you can roll back to a previous build from the UI. Build .15 changed the package filename to include the full build number, but the in-UI version list only recognized that new naming — so right after the change only the newest build (.15) showed up and there was nothing to roll back to. The version list, the size shown for each version, and the rollback download now accept both filename styles (the new full-build-number name and the older upstream-only name), so the full history of installable builds appears again. Note: a router only shows this restored history once it's running a build that includes this fix (.16 or later); an older install still reaches .16 by a one-line/offline install first.

## v0.1.12-cfw3212.15

- Offline install on a clean stock router now works end to end. Previously, installing without internet ("Method 2") would stop early with `Could not resolve host: bin.entware.net`, because the web server (`lighttpd`), `sudo`, and their support libraries were downloaded during install rather than shipped in the package — only `jq` was bundled. The package now carries the full set of these components inside it, so a router with no SIM/WAN can install completely. Routers that do have internet still work the same way, falling back to downloading only if a bundled piece is somehow missing.
- QManager no longer needs a writable root filesystem (no pivot/overlay/"rooting" prep). On a stock router `/` is read-only, so the installer can't create the `/opt` shortcut the Entware tools were built to expect. The web server now starts without it (its modules are loaded from an explicit `/usrdata` path and it no longer comes up masked), and privileged actions in the UI — which previously failed silently — now work directly, so the install comes up functional on a clean stock box.
- About Device now shows the modem's identity (Model, Firmware, Build Date, IMEI, Manufacturer) even with no SIM inserted. Previously the poller bundled the SIM reads (`CIMI`/`QCCID`/`CNUM`) into the same query as the modem identity, so on a SIM-less modem the SIM commands errored and wiped out the whole response — leaving every field blank until a SIM was present. The SIM reads are now a separate, best-effort step, so the always-available identity fields fill in regardless of SIM.
- The downloadable package file now includes the full build number in its name (for example `qmanager-cfw3212-v0.1.12-cfw3212.15.tar.gz` instead of `qmanager-cfw3212-v0.1.12.tar.gz`). Previously every build of the same upstream version downloaded with the same filename, so a new download landed next to an old one as `… (1).tar.gz` and the offline install command could pick up the wrong (older) file. Each build now has a unique filename. Note: because of this rename, reaching this build from an older install is a fresh one-line/offline install rather than an in-app Software Update.

## v0.1.12-cfw3212.14

- The "Reboot required" reminder after a software update now stays put until you actually reboot. After an install finishes, the Software Update page shows a "Reboot required" badge and an "Installation complete — Reboot when ready" notice with a Reboot Now button. Previously, if you navigated away from that page and came back (or reloaded it), the reminder disappeared, even though the device still needed a reboot to finish applying the update. The page now re-checks the pending-reboot state every time you open it, so the reminder and the Reboot Now button stay visible until the reboot is done. It clears on its own once the device reboots.
- Full uninstall is now complete: the `--purge` uninstall also removes the Email Alerts helper (`msmtp`), which a previous purge could leave behind. The normal (non-purge) uninstall is unchanged and still keeps your `/etc/qmanager` settings so a later reinstall picks them back up.

## v0.1.12-cfw3212.13

- Running the System Health Check no longer leaves the background data poller stopped. The health check briefly pauses the poller so it can talk to the modem without contention, then resumes it when it finishes. Previously it paused the poller by stopping the service and counting on a cleanup step to start it again — but if the health check got cut off partway (for example the page was closed, the connection dropped, or the router was low on memory), that cleanup could be skipped and the poller was left off. Because the poller is set to only auto-restart after a crash (not after a normal stop), it then stayed off until something started it again, which is why the next Health Check showed `qmanager-poller` as inactive with a warning and the dashboard metrics went stale. The health check now pauses the poller with the same safe flag the Speedtest already uses: the poller keeps running and just skips its modem polling while paused, and it clears a stale pause on its own after a few minutes — so an interrupted health check can no longer take the poller down.

## v0.1.12-cfw3212.12

- The QManager HTTPS certificate is now generated correctly so browsers accept it. The previous build produced a certificate with a duplicate setting that newer Chrome/Edge rejected outright (`NET::ERR_CERT_INVALID`, with no way to continue). The certificate is now built cleanly with a Subject Alternative Name and proper server settings, so reaching the QManager UI over HTTPS shows the normal, click-through-able warning. Existing installs are upgraded automatically on the next install.

## v0.1.12-cfw3212.11

- Software Update now reliably finds the newest available version. Once the Casa build number reached double digits (for example `.10` and up), the update check could miss it and report "up to date," because it was trusting the package host's release ordering instead of comparing build numbers directly. The check now sorts candidates by their actual version and build number, so the newest build is always detected regardless of how the host lists them.

## v0.1.12-cfw3212.10

- Software Update → Version Management install confirmations no longer say the device will reboot automatically. All three "Install Now" / "Reinstall Now" dialogs now match the Update Status card: QManager restarts its services after installation and then asks you to reboot when ready.
- The QManager HTTPS certificate is now a proper server certificate with a Subject Alternative Name (covering localhost, the router's LAN IP, and — when Tailscale is up — its Tailscale IP/name). Older builds shipped a certificate that newer iPhone/Safari and Firefox versions refused to open (the browser warning had no "continue anyway" option). Reaching the QManager UI over HTTPS (including over Tailscale) now shows a normal, acceptable certificate warning you can click through. Existing installs that still have the old certificate are upgraded automatically on the next install.

## v0.1.12-cfw3212.9

- Tailscale "Connect" / login now works from the UI on the Tiny Tailscale build. The previous build left out the component that hands the login link back to the browser, so clicking Connect timed out waiting for a sign-in link. The Tiny Tailscale build used here restores that, so you can connect and sign in from the UI normally — while keeping the lower memory use.

## v0.1.12-cfw3212.8

- Tailscale install reliability fixes for the Tiny Tailscale build introduced in `.7`:
  - The download now follows GitHub redirects, so installing Tailscale from the UI no longer fails partway with an extraction error.
  - The Tailscale service now starts correctly. On the lighter build the daemon was actually running but the service was being reported as "Failed to start" / Stopped; the Service status and Start on Boot now reflect the real state, and you can connect normally.

## v0.1.12-cfw3212.7

- Custom DNS changes now take effect immediately. Previously, enabling, changing, or disabling custom DNS only fully applied after the next router reboot, because the DNS service was sent a reload signal that does not re-read its configuration on this platform. The setting is now applied right away by restarting the DNS service.
- Casa installer now idempotently creates `/opt -> /usrdata/opt` when missing (brief read-write remount of `/`, then read-only again). Reinstalls leave an existing correct symlink untouched; a non-symlink `/opt` is warned and skipped so `/usrdata/opt` is never overwritten.
- The Tailscale install from the QManager UI now uses Tiny Tailscale, a smaller, lighter Tailscale build (v1.98.3), instead of the full official package. It installs and runs the same way from the UI, but uses noticeably less memory on the router — helpful on this hardware where RAM is tight. To upgrade Tailscale later, uninstall and reinstall it from the UI rather than using an in-place update.

## v0.1.12-cfw3212.6

- No functional changes from `v0.1.12-cfw3212.5`. This release is a clean rebuild on top of `.5` to validate the deterministic frontend build ID end-to-end on a live router — installing `.5 → .6` should now rewrite only the small number of files that actually differ between the two builds, instead of the ~80% of the frontend tree that older Casa releases rewrote on every backend-only update.

## v0.1.12-cfw3212.5

- Casa package builds now use a deterministic frontend build ID based on frontend source inputs. This prevents backend-only Casa releases from changing hundreds of exported Next.js files just because the build ID changed, which should greatly reduce flash writes, CPU load, and swap pressure during normal QManager updates.

## v0.1.12-cfw3212.4

- Software Update install progress now explicitly reports `Restarting QManager services...` while the Casa installer is bringing QManager/lighttpd services back up. This makes the two-step download/install flow clearer and no longer depends on the browser seeing a temporary reconnect failure to show a services-restarting message.

## v0.1.12-cfw3212.3

- **Orientation probe gated off for Casa CFW-3212.** The upstream v0.1.12 Cloudflare download probe (~5 MB, up to 90 s timeout) that tries to detect flipped upload/download counters on some Quectel firmwares is now disabled at the converter level for CFW-3212/RG520N-NA builds. Our upload/download counters are not flipped in normal use, and the probe caused unnecessary CPU/network contention around install and first WAN-up.
- The probe's fallback defaults (field 2 = download, field 10 = upload) match the correct CFW-3212 behavior, so upload/download display is unchanged.

## v0.1.12-cfw3212.2

- Installer cleanup: optional Ookla Speedtest helper download failures are now handled as best-effort, so a temporary internet/CDN problem should no longer make the whole QManager install report failure after the new version has already been installed.

## v0.1.12-cfw3212.1

- Ookla Speedtest dashboard no longer crashes when the test result is missing Download or Upload latency stats (which Ookla omits when packet loss is high enough that those numbers wouldn't be meaningful). The DL Latency and UL Latency fields now render `—` instead of throwing a JavaScript error that took the dashboard down.
- First Casa build on top of upstream QManager v0.1.12. Notable upstream changes you'll see on the router:
  - **Upload/Download orientation auto-probe** at first boot: QManager runs a small (5 MB) outbound probe and uses the result to map rmnet rx/tx to "upload" vs "download" the right way on Casa. Older builds sometimes had these swapped.
  - **Storage row** is now part of the Device Metrics dashboard, showing `/usrdata` usage.
  - **Live Traffic widget** has been removed. The kernel counters it relied on read near-zero because the Casa IPA hardware offload bypasses them, so the widget was misleading. Throughput numbers from Ookla Speedtest are still accurate.
  - **IP Passthrough Apply & Reboot** now actually reboots. Previously, on Casa, pressing Apply could update the profile without triggering the reboot — you now go through the standard reboot countdown screen.
  - **OTA reboot pages** no longer show a blank screen between "rebooting" and "back online". All reboot flows wait for the page to be ready before redirecting.
- All CFW-3212 patches from v0.1.11 carry forward: Casa paths, health-check, watchcat tiers, Ookla speedtest poller pause, Custom DNS, IP Passthrough cleanup, Version Management Install fix.

## v0.1.11-cfw3212.8

- Ookla Speedtest now pauses QManager's modem poller while the test is running. This prevents the poller from issuing modem AT reads during the test and keeps Speedtest-created latency or packet-loss spikes out of Recent Network Events.
- Speedtest now stores its Ookla config under `/tmp/qmanager-ookla-home` on Casa, avoiding the read-only `/home/root` path.

## v0.1.11-cfw3212.7

- Watchcat (the automatic recovery daemon) now uses the same Casa-friendly paths the manual UI buttons use. Tier 1 "re-register to network" asks Casa's connection manager via `link.profile.1.writeflag` / `link.policy.1.trigger_connect` instead of forcing the modem through `AT+COPS=2/0`. Tier 4 "reboot device" goes through `service.system.reset` instead of a bare `reboot`. Both still fall back to the legacy behavior if the Casa RDB keys aren't available, so non-Casa builds are unaffected.

## v0.1.11-cfw3212.6

- Version Management now shows a "Staged and ready to install" banner with **Install Now** and **Discard** buttons whenever a downloaded package is sitting on the router. You can drop the staged tarball without being forced to install it first if you change your mind about a downgrade.
- The router reboot countdown screen now waits 120 seconds before declaring the reboot stuck, up from 70 seconds, so slower Casa reboots don't trip the "still rebooting?" warning prematurely.

## v0.1.11-cfw3212.5

- Software Update → Version Management now finishes the install flow on Casa. Previously, picking an older version downloaded it but the page snapped back to "Up to date" and never offered an Install button, so the staged tarball just sat in /tmp. The button now transitions to "Install Now" once the download is verified, calls the staged-install flow, and reboots into the selected version.

## v0.1.11-cfw3212.4

- Reconnect Network now asks Casa's own connection manager to refresh the cellular session instead of forcing the modem through a hard deregister/re-register cycle. This should make that menu action much gentler on the router.
- Reconnect Network now shows a progress window after you confirm the action. It watches QManager's modem status cache and shows elapsed time, cellular registration, WAN IP, and internet reachability instead of closing immediately while the reconnect continues in the background.

## v0.1.11-cfw3212.3

- Custom DNS availability detection is now more reliable on Casa CFW-3212, so the page correctly unlocks when the router's DNS proxy is available.
- Saving Custom DNS settings is now more reliable on Casa CFW-3212 and no longer fails with a staging-file error on affected installs.
- The IP Passthrough disable cleanup is now applied to the installer-written Casa CGI too, so turning IP Passthrough off clears both the profile flag and the persistent service handover state.

## v0.1.11-cfw3212.2

- Custom DNS (Local Network → Custom DNS) works on Casa CFW-3212 now. You can set custom upstream DNS resolvers for LAN clients from the QManager UI without changing DHCP leases or rebooting the router.
- IP Passthrough bypass detection is hooked up to the right place on Casa (`link.profile.1.ip_handover.*` RDB keys). The Custom DNS page can now correctly tell you when a device in IP Passthrough mode is getting carrier DNS straight from the modem and skipping the resolver settings.
- attempted another fixed the long-running "device info missing after boot" problem (blank IMEI, IMSI, ICCID, manufacturer, model, firmware in the dashboard). The poller's boot-identity AT check was stripping newlines and then trying to match `^OK$`, which can never match a multi-line modem response. It now strips carriage returns instead, so the anchored matches work and the dashboard fills in on the first try.
- Turning off IP Passthrough now also clears `service.ip_handover.enable` and the cached last WAN IP. Before this fix, those flags stayed set across reboots and the modem kept its data session bound to the Casa handover placeholder (`192.0.0.1`), which left the router with no real WAN until a manual reconnect.

## v0.1.11-cfw3212.1

- First Casa CFW-3212 build of upstream QManager v0.1.11.

## v0.1.10 Casa Updates

- Kept two v0.1.10 package releases available: `v0.1.10-cfw3212.16` as the router-verified checkpoint, and `v0.1.10-cfw3212.25` as the final v0.1.10 Casa package.
- Manual SIM Profile save, apply, delete, and deactivate works on Casa, including APN, TTL/HL, IMEI, and the modem reboot apply step. Blind auto-apply by ICCID stays off by default.
- Casa/RG520N ICCID handling was cleaned up so SIM Profiles do not show false SIM mismatch warnings from a missing trailing padding nibble.
- Dashboard freshness checks tolerate Casa boxes with a wrong wall clock as long as the router status timestamp keeps advancing.
- Web Console, Software Update Casa notes, Email Alerts `msmtp` install/remove, Discord Bot backend install, Tailscale, and Ookla Speedtest support were added or tightened during the v0.1.10 Casa series.
- Installs and GUI updates were made gentler on router flash: fewer unnecessary file writes, no duplicate full tarball extraction during online install/update, and GUI updates end in a reboot-required state instead of rebooting automatically.
- Casa package safety limits stayed in place around USB composition, upstream IP Passthrough modem writes, and blind SIM Profile auto-apply.

## Earlier Highlights

- Casa package releases go out through the two-repo builder/package flow, with protected prerelease publishing and a router-verified mark on releases.
- Cut down on router flash churn: skip frontend payloads that haven't changed, compare before copying, pace fresh installs, and don't extract the tarball twice during online installs/updates.
- GUI updates now end in a reboot-required state instead of rebooting on their own. You decide when the reboot happens.
- QManager install paths are mapped to Casa's writable storage at `/usrdata` and `/etc/systemd/system`, with lighttpd on HTTP `9080` and HTTPS `9000`.
- Kept the Casa safety lines drawn around USB composition, upstream IP Passthrough modem writes, and blind SIM profile auto-apply.
