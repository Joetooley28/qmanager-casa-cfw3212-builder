#!/usr/bin/env python3
"""Support page: add Casa CFW-3212 issues and release-notes rows.

The Casa rows go first in the Get help card; upstream's rows are relabelled
"QManager ..." so Casa problems are not sent to the QManager author.
"""
import json
from pathlib import Path
import sys

CASA_REPO = "Joetooley28/qmanager-casa-cfw3212-package"

target = Path(sys.argv[1])


def edit(rel, old, new):
    p = target / rel
    text = p.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"Support patch anchor changed: {rel}: {old[:90]!r}")
    p.write_text(text.replace(old, new, 1))


page = "components/support/support.tsx"

edit(
    page,
    '  EMAIL: "russel.yasol@gmail.com",\n} as const;',
    '  EMAIL: "russel.yasol@gmail.com",\n'
    "  // Casa: the CFW-3212 port's own repo.\n"
    f'  CASA_ISSUES: "https://github.com/{CASA_REPO}/issues",\n'
    f'  CASA_ISSUES_LABEL: "github.com/{CASA_REPO}/issues",\n'
    f'  CASA_RELEASES: "https://github.com/{CASA_REPO}/releases",\n'
    f'  CASA_RELEASES_LABEL: "github.com/{CASA_REPO}/releases",\n'
    "} as const;",
)

edit(
    page,
    """              <motion.div variants={staggerRows} className={ACTION_LIST}>
                <ActionRow
                  href={LINKS.ISSUES}""",
    """              <motion.div variants={staggerRows} className={ACTION_LIST}>
                <ActionRow
                  href={LINKS.CASA_ISSUES}
                  icon={<BugIcon className={ACTION_ROW.GLYPH} />}
                  label={t(`${K}.help.casa_bug.label`)}
                  dest={LINKS.CASA_ISSUES_LABEL}
                  mono
                  newTabLabel={newTab}
                />
                <ActionRow
                  href={LINKS.CASA_RELEASES}
                  icon={<FileTextIcon className={ACTION_ROW.GLYPH} />}
                  label={t(`${K}.help.casa_release_notes.label`)}
                  dest={LINKS.CASA_RELEASES_LABEL}
                  mono
                  newTabLabel={newTab}
                />
                <ActionRow
                  href={LINKS.ISSUES}""",
)

# --- English strings (other locales fall back to English) ---
loc = target / "public/locales/en/common.json"
data = json.loads(loc.read_text())
help_ = data["support"]["help"]
help_["description"] = (
    "Problems installing or updating, or anything specific to the Casa CFW-3212, "
    "go to the Casa port. App bugs that also happen on other modems go to QManager."
)
help_["casa_bug"] = {"label": "Report a Casa CFW-3212 problem"}
help_["casa_release_notes"] = {"label": "Casa CFW-3212 release notes"}
help_["bug"]["label"] = "Report a QManager bug"
help_["email"]["label"] = "Email QManager's maintainer"
help_["release_notes"]["label"] = "QManager release notes"
loc.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
