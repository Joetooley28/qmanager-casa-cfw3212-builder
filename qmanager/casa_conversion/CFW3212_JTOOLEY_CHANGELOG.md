# Casa CFW-3212 Joetooley Changelog

## What's Working

- Web Console works. On installs with internet, `ttyd` gets pulled in and started automatically, and `/console/` is live once that helper is in place.
- System Health Check has been pointed at the Casa paths, services, lighttpd ports, and the `/usrdata/opt/bin` helper locations it actually needs to look at.
- The Casa installer now idempotently ensures `/opt -> /usrdata/opt` on every install (with an explicit root remount when needed) so Entware helpers such as `sudo` resolve correctly on clean routers without manual symlink setup.
- Tailscale runs from the QManager UI using the lighter Tiny Tailscale build. You do your own Tailscale login from the UI.
- Ookla Speedtest works once the `speedtest` helper is installed. install handles if connected to internet.
- Email Alerts can install and remove `msmtp` through the Casa Entware package flow. The Gmail app-password setup and an actual test send are the last things to confirm working on your end. (wired up, not tested yet) 
- Discord Bot backend is now part of the Casa package, so you can plug in your own Discord bot token and user ID and try the UI. (wired up, not tested yet)
- SIM Profiles can be saved, applied, deleted, and deactivated by hand on Casa. That includes APN, TTL/HL, IMEI, and the modem reboot apply step. The blind "auto-apply by ICCID" behavior is still off by default.
- Custom DNS works from the QManager UI, including custom upstream resolvers for LAN clients without changing DHCP leases or rebooting the router.
- The Reconnect Network menu action now uses Casa's connection manager path instead of forcing a modem deregister/re-register.
- Reconnect Network now keeps a small progress window open so you can watch elapsed time, network registration, WAN IP, and internet status while the router comes back online.
- Software Update → Version Management can now install a different version (including rollbacks). After the download verifies, the Install button switches to "Install Now" so the staged package actually gets applied instead of being left on disk.
- A handful of upstream modem-management actions stay blocked or limited on Casa because they'd let you push the modem into a state we don't want it in.

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
