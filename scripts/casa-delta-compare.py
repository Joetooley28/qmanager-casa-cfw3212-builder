#!/usr/bin/env python3
"""Find Casa changes that a new upstream port silently dropped.

For each file, the "Casa delta" is the set of lines the converter added on top of
upstream. Compare the delta from the previous release's conversion with the new
one: any Casa line that was there before and is gone now is reported, per file,
unless the new upstream already contains that line (upstream absorbed it).

Usage:
  casa-delta-compare.py OLD_UPSTREAM OLD_CASA NEW_UPSTREAM NEW_CASA [--all] [--accept FILE]

--accept FILE lists reviewed, intended losses, one per line:
  <path> | <lost line, stripped, or * for the whole file> | <reason>
Lines starting with # are comments. Version-string lines are always ignored.

OLD_* = the last released conversion (e.g. upstream v0.1.16 checkout and the
converter's qmanager_work_v0.1.16_casa from main); NEW_* = the port under test.
Exit status 1 when anything was lost, so it can gate a build.
"""
import os
import sys
from pathlib import Path

SKIP_DIRS = {".git", "node_modules", "out", ".next", "dependencies", "language-packs", "docs"}
SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".ico", ".gz", ".ipk", ".zip", ".woff", ".woff2", ".ttf", ".lock"}


def files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            p = Path(dirpath) / name
            if p.suffix.lower() in SKIP_SUFFIXES or p.is_symlink():
                continue
            yield p.relative_to(root)


def lines(path):
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    return {l.strip() for l in text.splitlines() if l.strip()}


VERSION_LINE = ("VERSION=", '"version":', "Build: ")


def load_accept(path):
    accepted = {}
    for raw in Path(path).read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        # The lost line may itself contain " | " (shell pipes): path is before the
        # first separator, reason after the last.
        path, _, rest = raw.partition(" | ")
        line, _, reason = rest.rpartition(" | ")
        if not path.strip() or not line.strip() or not reason.strip():
            raise SystemExit(f"accept file: need 'path | line | reason': {raw}")
        accepted.setdefault(path.strip(), set()).add(line.strip())
    return accepted


def main(argv):
    show_all = "--all" in argv
    accepted = {}
    if "--accept" in argv:
        i = argv.index("--accept")
        accepted = load_accept(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 4:
        print(__doc__)
        return 2
    old_up, old_casa, new_up, new_casa = map(Path, args)
    lost_total = 0
    report = []
    for rel in sorted(files(old_casa)):
        oc = lines(old_casa / rel)
        if oc is None:
            continue
        ou = lines(old_up / rel) or set()
        delta = oc - ou
        if not delta:
            continue
        nc_path = new_casa / rel
        if not nc_path.exists():
            if "*" in accepted.get(str(rel), set()):
                continue
            report.append((len(delta), f"MISSING  {rel}  ({len(delta)} Casa lines; file not in new tree: moved or removed upstream?)"))
            lost_total += len(delta)
            continue
        nc = lines(nc_path) or set()
        nu = lines(new_up / rel) or set()
        ok = accepted.get(str(rel), set())
        if "*" in ok:
            continue
        lost = sorted(l for l in delta if l not in nc and l not in nu
                      and l not in ok and not l.startswith(VERSION_LINE))
        if lost:
            lost_total += len(lost)
            sample = "\n      ".join(l[:150] for l in (lost if show_all else lost[:6]))
            more = "" if show_all or len(lost) <= 6 else f"\n      ... {len(lost) - 6} more"
            report.append((len(lost), f"LOST     {rel}  ({len(lost)} of {len(delta)} Casa lines)\n      {sample}{more}"))
    for _, line in sorted(report, key=lambda r: -r[0]):
        print(line)
    print(f"\n{len(report)} file(s) with dropped Casa changes, {lost_total} line(s).")
    return 1 if report else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
