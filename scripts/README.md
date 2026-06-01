# Dev / working-branch flow

Goal: iterate on builder changes and test them on a live router **without**
cutting a public package release on every change. Public releases stay on
`main`; day-to-day work happens on `dev`.

## Branches

- **`main`** — the public release line. Only `main` can publish a Casa package
  prerelease (and only via `create_release=true` + `dry_run=false` + manual
  approval of the protected `official-package-release` environment).
- **`dev`** — the working branch. Commit changes here. Builds from `dev` (or any
  non-`main` branch) are **forced to a dry run** by the workflow's branch-safety
  gate: `create_release` is ignored, nothing is published to the **package repo**,
  and GitHub keeps the build as **workflow artifacts** only. Tags are suffixed
  with `.dev` (for example `v0.1.12-cfw3212.18.dev`) so the router UI shows a
  dev build after sideload. Use `scripts/cfw3212-dev-load.sh` to install.

## Build a dev artifact

Manually dispatch the builder workflow on the `dev` branch
(`Actions → Build Casa CFW-3212 package → Run workflow → Branch: dev`).
`dry_run` defaults to `true`; leave it. Every successful build uploads:

- `casa-cfw3212-<tag>` — tarball + `.sha256`
- `casa-cfw3212-publish-<tag>` — tarball + `.sha256` + install/uninstall scripts
  + release notes + updater changelog JSON

(There is no auto-build on push — dispatch when you want a build.)

## Load onto a live router — `cfw3212-dev-load.sh`

`scripts/cfw3212-dev-load.sh` pulls the `casa-cfw3212-publish-*` artifact (the
fully **converted** package) and puts it on the box. Set the target with
`CFW3212_BOX` (default `cfw3212-router`; set it to your router's ssh target). `scp` uses `-O` (the modem has no sftp).

```bash
# Symlink onto PATH (optional)
ln -sf "$PWD/scripts/cfw3212-dev-load.sh" ~/bin/cfw3212-dev-load

# Just download + extract the latest dev build; prints the .tar.gz path
cfw3212-dev-load.sh fetch

# Full offline install of the latest dev build onto the box
cfw3212-dev-load.sh install                 # latest run on 'dev'
cfw3212-dev-load.sh install --run 12345678  # a specific run
cfw3212-dev-load.sh install --tarball /path/qmanager-cfw3212-….tar.gz

# Hot-patch individual converted files onto a running install + restart services
cfw3212-dev-load.sh hotpatch poller                 # poller daemon (restarts qmanager-poller)
cfw3212-dev-load.sh hotpatch cgi-update updater     # the Software-Update CGI + worker (restarts lighttpd)
cfw3212-dev-load.sh hotpatch all                    # cgi-update + updater + poller + platform
cfw3212-dev-load.sh hotpatch --file ./x.sh:/usrdata/bin/x.sh   # verbatim push (you converted it yourself)
```

It prompts before writing to the live router; pass `--yes` to skip.

**Why hot-patch sources from the artifact, not the repo templates:** the
converter transforms the templates on the way into the package (PACKAGE_REPO
substitution, the `qmanager_poller` AT-command/CR patches, etc.). The
on-device files are the converter's *output*, so the helper extracts them from
the converted tarball. Pushing a raw template would not match what runs on
device. Use `--file` only when you have already converted the file yourself
(e.g. a manual one-off patch).

## Promote to a public release

When a `dev` build tests good on the box: merge `dev` → `main`, then dispatch
the builder on `main` with `casa_build=next` (or a specific `<N>`) and
`dry_run=false create_release=true
force=true` and approve the `official-package-release` environment.
