# Casa CFW-3212 Joetooley Changelog

## Verified / Wired / Working

- Web Console is wired: internet-connected installs auto-install/start `ttyd`, and `/console/` works once the helper is present.
- System Health Check is wired for Casa paths, services, lighttpd ports, and `/usrdata/opt/bin` helper locations.
- Tailscale is wired through the QManager UI; users still need to complete their own Tailscale login.
- Ookla Speedtest is wired and works when the `speedtest` helper is installed.
- Email Alerts can install/remove `msmtp` through the Casa Entware package flow. Gmail app-password setup and live send behavior are the remaining user-side verification steps.
- Discord Bot backend is now installed by the Casa package so users can test the UI with their own Discord bot token and user ID.
- Some upstream modem-management actions remain intentionally blocked or limited on Casa when they could change unsafe modem settings.

## v0.1.10-cfw3212.24

- Clarify the public changelog's optional-feature section: Web Console now auto-installs `ttyd` during internet-connected installs, while Tailscale and Ookla Speedtest are expected to work when installed/configured.
- Note that Email Alerts can install/remove `msmtp` through the Casa Entware package flow, with Gmail app-password setup and live send behavior still needing final verification.
- Update the Software Update upstream changelog toggle label to `Rus | Ame / Dr. D`.
- Clarify the generated GitHub release credit line to mention Joetooley's Casa converter/package flow and small UI compatibility changes, while keeping upstream QManager credit with Rus | Ame / Dr. D.
- Install the built `qmanager_discord` helper from the Casa package so the Discord Bot UI can enable/start the backend for users who want to test Discord DM alerts.

## v0.1.10-cfw3212.23

- Install and start the optional Web Console backend (`ttyd`) during internet-connected Casa installs so `/console/` works without a manual helper step.
- Keep `ttyd` download failure non-fatal; the rest of QManager still installs and the Web Console page remains unavailable until `ttyd` can be installed.
- Tighten `--purge` uninstall cleanup so QManager-installed optional tools such as Tailscale state/symlinks/services and Ookla CLI config are removed with the rest of the package.
- During GUI updates, return the browser to the main QManager screen after service restart poll loss instead of reloading the stale Software Update route.
- Adapt Email Alerts `msmtp` install/uninstall for Casa by using the direct Entware IPK extraction flow instead of a missing `opkg` command, and remove the misleading manual `opkg` command from the UI.
- Rename the Software Update upstream changelog toggle from `Dr. D` to `Rus | Ame / Dr. D` while keeping the same upstream release notes.

## v0.1.10-cfw3212.22

- Add a compact Software Update changelog toggle so the router UI can show Casa-specific Joetooley notes separately from upstream QManager notes.
- Create `/opt -> /usrdata/opt` during install so Entware setuid tools such as `sudo` can use their native loader and library paths.
- Adapt the QManager health-check worker for Casa paths, remapped lighttpd ports, Casa service names, and `/usrdata/opt/bin` CGI paths.
- v21 follow-up: preserve Rust ELF binaries during install by normalizing CRLF only on shebang text files, preventing `qmanager_ping` corruption.
- v21: vendor the Casa-tested Rust `qmanager_ping` binary and verify the packaged binary SHA in CI before publishing.
- v20/v21: keep `qmanager-ping` enabled with a bounded Rust-first wrapper and shell fallback, while retrying modem identity reads during boot.

## Earlier Highlights

- Added Casa package releases through the two-repo builder/package flow, with protected prerelease publishing and router-verified release marking.
- Reduced router flash churn by skipping unchanged frontend payloads, comparing before copy, pacing fresh installs, and avoiding duplicate tarball extraction in online install/update paths.
- Changed GUI updates to finish with a reboot-required state instead of automatic reboot, leaving reboot timing under operator control.
- Mapped QManager install paths to Casa writable storage under `/usrdata` and `/etc/systemd/system`, with lighttpd on HTTP `9080` and HTTPS `9000`.
- Kept Casa safety boundaries around USB composition, upstream IP Passthrough modem writes, and blind SIM profile auto-apply.
