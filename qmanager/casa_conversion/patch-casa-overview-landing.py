#!/usr/bin/env python3
"""Land on the Overview page ("/") instead of the bare login form.

Upstream's Log out already goes to "/" (the public Overview, whose Sign in button
opens /login/), but an expired session (the app-layout guard) and the end of a
reboot went straight to /login/, so users rarely saw the Overview (owner,
2026-10-13). These paths and the shared 401 handler now go to "/" as well.
The "offline" auto-logout (it shows a reason on /login/) and post-setup stay as-is.
"""
from pathlib import Path
import sys

target = Path(sys.argv[1])


def swap(rel, old, new, count, label):
    p = target / rel
    text = p.read_text()
    if old not in text and new in text:
        return
    if text.count(old) != count:
        raise SystemExit(f"Overview landing patch: {label} anchor changed")
    p.write_text(text.replace(old, new))


swap("components/app-layout.tsx",
     '    window.location.replace("/login/");\n',
     '    // Casa: land on the Overview page; its Sign in button opens /login/.\n'
     '    window.location.replace("/");\n',
     1, "app-layout guard")
swap("components/reboot/reboot-countdown.tsx",
     'window.location.href = "/login/";', 'window.location.href = "/";', 2, "reboot redirects")
swap("components/reboot/reboot-countdown.tsx",
     'href="/login/"', 'href="/"', 1, "reboot escape link")
swap("lib/auth-fetch.ts",
     '    if (!window.location.pathname.startsWith("/login")) {\n'
     '      window.location.href = "/login/";\n'
     '    }',
     '    // Casa: an expired session lands on the public Overview.\n'
     '    if (window.location.pathname !== "/" &&\n'
     '        !window.location.pathname.startsWith("/login")) {\n'
     '      window.location.replace("/");\n'
     '    }',
     1, "expired API session")
swap("hooks/use-auto-logout.ts",
     ' * - 401 response   → authFetch already redirects to /login/ (session gone after reboot)',
     ' * - 401 response   → authFetch already redirects to / (expired session or reboot)',
     1, "auto-logout documentation")
