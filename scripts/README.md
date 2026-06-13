# Dev / working-branch flow

**For agents / new chats:** This is the **default way to test QManager Casa
changes on a live CFW-3212 router** without publishing a new release to
`Joetooley28/qmanager-casa-cfw3212-package` on every edit. Edit on branch
`dev` → dispatch CI → download **workflow artifacts** → install with
`scripts/cfw3212-dev-load.sh`. Only merge to `main` and publish when the user
wants a public package release.

**Canonical script:** `scripts/cfw3212-dev-load.sh` (VPS:
`github-staging/qmanager-casa-conversion-cfw3212-updater/scripts/cfw3212-dev-load.sh`)

Also documented in workspace `AGENTS.md` and `shared-docs-and-notes/WORKSPACE_MAP.md`.

## Goal

Iterate on builder/converter/UI templates and verify on a **live router** many
times per day. **Do not** cut a package-repo prerelease for each small change.
Public releases stay on `main` + manual approval of `official-package-release`.

## Typical loop (copy for handoffs)

1. **Code** on branch `dev` in `Joetooley28/qmanager-casa-cfw3212-builder`
   (VPS: `~/code/cfw3212/github-staging/qmanager-casa-conversion-cfw3212-updater`).
   Edit Casa **templates** under `qmanager/casa_conversion/templates/`, not
   generated `out/_next` chunks.
2. **Commit / push** to `dev` when ready for a test build.
3. **Dispatch CI** (no auto-build on push):
   - GitHub → **Actions** → **Build Casa CFW-3212 package** → **Run workflow**
   - Branch: **`dev`**
   - Leave defaults (`dry_run=true`, `create_release=false`, `casa_build=next`).
   - Versioning rule: `dev` builds are iterations toward the **next public**
     release. If the highest published package is `v0.1.12-cfw3212.20`, then
     default `dev` builds are `v0.1.12-cfw3212.21.1.dev`,
     `v0.1.12-cfw3212.21.2.dev`, and so on. When approved and merged to
     `main`, the public package is `v0.1.12-cfw3212.21`.
4. **Wait** for the **Build converted Casa package** job (artifact upload only).
   - **Do not** approve `official-package-release` for `dev` builds — nothing
     should publish to the package repo from `dev`.
5. **Sideload** from the VPS (needs `gh` auth + SSH to modem):

   ```bash
   cd ~/code/cfw3212/github-staging/qmanager-casa-conversion-cfw3212-updater
   export CFW3212_BOX=cfw3212-modem   # or your ssh config name

   # Latest successful dev workflow run
   scripts/cfw3212-dev-load.sh install

   # Or pin a specific Actions run id (from the workflow URL)
   scripts/cfw3212-dev-load.sh install --run RUN_ID

   # Non-interactive
   scripts/cfw3212-dev-load.sh install --yes
   ```

6. **Verify** on the router UI (Software Update, changed screens, `/etc/qmanager/VERSION`).
   Dev builds use a `.N.dev` iteration tag (e.g. `v0.1.12-cfw3212.21.2.dev`)
   baked into VERSION.
7. **Repeat** from step 1 until good; then **merge `dev` → `main`** and run an
   **official** build only when the user wants a public package release.

## Branches and CI behavior

| Branch | Package repo publish | Test artifacts |
|--------|----------------------|----------------|
| **`dev`** | **Never** (forced dry run) | Yes — `casa-cfw3212-publish-<tag>` on the workflow run |
| **`main`** | Only if `create_release=true`, `dry_run=false`, **and** you approve `official-package-release` | Yes when dry run; publish when approved |

- **`dev`** tags include a **public-build plus iteration suffix**:
  `vX.Y.Z-cfw3212.N.M.dev`, where `N` is the next public release and `M` is
  the dev iteration. About / Software Update show the dev build after sideload.
- `CFW3212_JTOOLEY_CHANGELOG.md` is public-release only. Do not add one
  changelog section per dev build; write/update the next public section
  (`## vX.Y.Z-cfw3212.N`) and let all `N.M.dev` artifacts use those notes.
- **Public repo:** anyone can **download artifacts** from your completed Actions
  runs (read-only). They **cannot** dispatch workflows or publish packages
  without write access + your approval.

## Build a dev artifact (CI details)

Manually dispatch **Build Casa CFW-3212 package** on branch **`dev`**.

Every successful build uploads:

- `casa-cfw3212-<tag>` — tarball + `.sha256` only
- `casa-cfw3212-publish-<tag>` — tarball + `.sha256` + install/uninstall scripts +
  release notes + updater changelog JSON ← **use this for sideload**

There is **no auto-build on push** — dispatch when you need a fresh package.

```bash
# From VPS (optional)
gh workflow run "Build Casa CFW-3212 package" \
  --repo Joetooley28/qmanager-casa-cfw3212-builder \
  --ref dev \
  -f upstream_version=latest \
  -f casa_build=next \
  -f dry_run=true \
  -f create_release=false
```

## Load onto a live router — `cfw3212-dev-load.sh`

Pulls the **`casa-cfw3212-publish-*`** artifact (fully **converted** package;
never push raw repo templates to the device).

| Variable | Default | Meaning |
|----------|---------|---------|
| `CFW3212_BOX` | `cfw3212-router` | SSH target (use `cfw3212-modem` on the VPS) |
| `BUILDER_REPO` | `Joetooley28/qmanager-casa-cfw3212-builder` | Artifact source repo |
| `BUILD_BRANCH` | `dev` | Branch for “latest run” when `--run` omitted |

`scp` uses **`-O`** (modem has no sftp subsystem).

```bash
# Optional: on PATH
ln -sf "$PWD/scripts/cfw3212-dev-load.sh" ~/bin/cfw3212-dev-load

# Download only; prints path to .tar.gz
scripts/cfw3212-dev-load.sh fetch

# Full offline install (overwrites current QManager install)
scripts/cfw3212-dev-load.sh install
scripts/cfw3212-dev-load.sh install --run 12345678
scripts/cfw3212-dev-load.sh install --tarball /path/qmanager-cfw3212-….tar.gz

# Hot-patch selected converted files + restart services (faster, partial)
scripts/cfw3212-dev-load.sh hotpatch poller
scripts/cfw3212-dev-load.sh hotpatch cgi-update updater
scripts/cfw3212-dev-load.sh hotpatch all
scripts/cfw3212-dev-load.sh hotpatch --file ./local:/usrdata/path/on/device
```

Prompts before writing unless `--yes` / `-y`.

### Full install vs hotpatch (agents)

| Change type | Use |
|-------------|-----|
| Next.js UI, static `out/`, most template edits | **`install`** (full package) |
| `update_cfw3212.sh`, `qmanager_update`, poller, platform CGI | **`hotpatch`** with matching component |
| Unsure | **`install`** |

Hotpatch reads files **from the converted tarball inside the artifact**, not
from git templates — the converter rewrites paths, poller patches, etc.

## Promote to a public release

When a `dev` sideload tests good:

1. Merge **`dev` → `main`** (user approval).
2. Confirm `CFW3212_JTOOLEY_CHANGELOG.md` has the exact public tag being
   released. For example, if dev testing used `.21.1.dev` through `.21.4.dev`,
   the public section must be `## v0.1.12-cfw3212.21`; do not add the dev
   iteration tags to the public changelog.
3. Dispatch builder on **`main`** with `casa_build=next` (or explicit `N`),
   `dry_run=false`, `create_release=true`, `force=true` if replacing assets.
4. Approve **`official-package-release`** (publishes to package repo).

Router **Software Update** installs from the **package repo**, not dev artifacts.

## What not to do

- Do **not** tell the user to approve package-repo publish for a **`dev`** branch build.
- Do **not** use `create_release=true` on `dev` expecting a public release (ignored / blocked).
- Do **not** copy raw `templates/` files to the modem for “quick UI tests”.
- Do **not** skip CI and edit `qmanager_work_v*_casa/` trees directly for shipping behavior.

## Security note (optional hardening backlog)

See Linear **AI-61** for deferred branch protection / Actions allowlist. Today
only the repo owner has write access; package publish still requires environment
approval.
