#!/usr/bin/env python3
"""Find Casa changes that a new upstream port silently dropped.

For each file, the "Casa delta" is the set of lines the converter added on top of
upstream. A Casa line that was in the last released conversion and is missing
from a new one is reported, unless the new upstream already contains that line
(upstream absorbed it) or it is listed as reviewed in the accept file. Files the
Casa port adds outright (no upstream counterpart) only have to exist.

Modes:
  compare  OLD_UPSTREAM OLD_CASA NEW_UPSTREAM NEW_CASA [--accept FILE] [--all]
  snapshot UPSTREAM CASA OUT.json
  check    SNAPSHOT.json NEW_UPSTREAM NEW_CASA [--accept FILE] [--all]

UPSTREAM = a checkout of the upstream tag; CASA = the converter's output tree
(qmanager/qmanager_work_<tag>_casa). Take a snapshot of every released build
(casa_conversion/casa-delta/<casa tag>.json); CI checks each build against the
newest one.

--accept FILE lists reviewed, intended losses, one per line:
  <path> | <lost line, stripped, or * for the whole file> | <reason>
Lines starting with # are comments. Version-string lines are always ignored.
Exit status 1 when anything unreviewed was lost.
"""
import json
import os
import sys
from pathlib import Path

SKIP_DIRS = {".git", "node_modules", "out", ".next", "dependencies", "language-packs", "docs"}
SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".ico", ".gz", ".ipk", ".zip", ".woff", ".woff2", ".ttf", ".lock"}
VERSION_LINE = ("VERSION=", '"version":', "Build: ")


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


def snapshot(upstream, casa):
    """{path: [casa lines]} for patched files, {path: "casa-only"} for added files."""
    snap = {}
    for rel in sorted(files(casa)):
        oc = lines(casa / rel)
        if oc is None:
            continue
        up = upstream / rel
        if not up.exists():
            snap[str(rel)] = "casa-only"
            continue
        delta = oc - (lines(up) or set())
        if delta:
            snap[str(rel)] = sorted(delta)
    return snap


def load_accept(path):
    accepted = {}
    for raw in Path(path).read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        # The lost line may itself contain " | " (shell pipes): path is before the
        # first separator, reason after the last.
        rel, _, rest = raw.partition(" | ")
        line, _, reason = rest.rpartition(" | ")
        if not rel.strip() or not line.strip() or not reason.strip():
            raise SystemExit(f"accept file: need 'path | line | reason': {raw}")
        accepted.setdefault(rel.strip(), set()).add(line.strip())
    return accepted


def check(snap, new_up, new_casa, accepted, show_all):
    report = []
    for rel, delta in sorted(snap.items()):
        ok = accepted.get(rel, set())
        if "*" in ok:
            continue
        nc_path = new_casa / rel
        if not nc_path.exists():
            n = 1 if delta == "casa-only" else len(delta)
            what = "Casa-only file" if delta == "casa-only" else f"{n} Casa lines"
            report.append((n, f"MISSING  {rel}  ({what}; not in the new tree: moved or removed upstream?)"))
            continue
        if delta == "casa-only":
            continue
        nc = lines(nc_path) or set()
        nu = lines(new_up / rel) or set()
        lost = sorted(l for l in delta if l not in nc and l not in nu
                      and l not in ok and not l.startswith(VERSION_LINE))
        if lost:
            sample = "\n      ".join(l[:150] for l in (lost if show_all else lost[:6]))
            more = "" if show_all or len(lost) <= 6 else f"\n      ... {len(lost) - 6} more"
            report.append((len(lost), f"LOST     {rel}  ({len(lost)} of {len(delta)} Casa lines)\n      {sample}{more}"))
    for _, line in sorted(report, key=lambda r: -r[0]):
        print(line)
    print(f"\n{len(report)} file(s) with dropped Casa changes, {sum(r[0] for r in report)} line(s).")
    return 1 if report else 0


def main(argv):
    show_all = "--all" in argv
    accepted = {}
    if "--accept" in argv:
        i = argv.index("--accept")
        accepted = load_accept(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    args = [a for a in argv if not a.startswith("--")]
    mode = args[0] if args and args[0] in ("compare", "snapshot", "check") else "compare"
    if args and args[0] == mode:
        args = args[1:]
    if mode == "snapshot" and len(args) == 3:
        snap = snapshot(Path(args[0]), Path(args[1]))
        Path(args[2]).write_text(json.dumps(snap, indent=1, ensure_ascii=False, sort_keys=True) + "\n")
        n = sum(len(v) for v in snap.values() if v != "casa-only")
        print(f"{len(snap)} files, {n} Casa lines -> {args[2]}")
        return 0
    if mode == "check" and len(args) == 3:
        snap = json.loads(Path(args[0]).read_text())
        return check(snap, Path(args[1]), Path(args[2]), accepted, show_all)
    if mode == "compare" and len(args) == 4:
        snap = snapshot(Path(args[0]), Path(args[1]))
        return check(snap, Path(args[2]), Path(args[3]), accepted, show_all)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
