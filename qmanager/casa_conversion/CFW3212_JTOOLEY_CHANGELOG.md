# Casa CFW-3212 Joetooley Changelog

## v0.1.10-cfw3212.23

- Install and start the optional Web Console backend (`ttyd`) during internet-connected Casa installs so `/console/` works without a manual helper step.
- Keep `ttyd` download failure non-fatal; the rest of QManager still installs and the Web Console page remains unavailable until `ttyd` can be installed.
- Tighten `--purge` uninstall cleanup so QManager-installed optional tools such as Tailscale state/symlinks/services and Ookla CLI config are removed with the rest of the package.

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
