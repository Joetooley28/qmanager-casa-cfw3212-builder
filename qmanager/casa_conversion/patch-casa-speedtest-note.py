#!/usr/bin/env python3
"""Speed Test dialog: say that the router-run test is slower than a LAN device.

The Speed Test runs the Ookla CLI on the router itself, so its traffic is handled
by the router's CPU and cannot use the hardware offload (fast path) that traffic
from LAN devices uses on the CFW-3212. Owner asked for a note (2026-10-13).
"""
from pathlib import Path
import sys

p = Path(sys.argv[1]) / "components/dashboard/speedtest-dialog.tsx"
text = p.read_text()
if "Casa CFW-3212: the router-run test" in text:
    sys.exit(0)
old = '''      <p className="text-on-surface-variant text-sm leading-[1.55]">
        {t("speedtest.dialog_idle_description")}
      </p>
'''
new = '''      <p className="text-on-surface-variant text-sm leading-[1.55]">
        {t("speedtest.dialog_idle_description")}
      </p>
      {/* Casa CFW-3212: the router-run test uses the CPU, not the hardware fast path. */}
      <p className="text-on-surface-variant text-xs leading-[1.5]">
        This test runs on the router itself, so the router&apos;s processor
        limits it and it cannot use the hardware fast path that traffic from your
        devices uses. Expect lower results than a test from a computer or phone on
        your network.
      </p>
'''
if text.count(old) != 1:
    raise SystemExit("Speed test note patch: description anchor changed")
p.write_text(text.replace(old, new, 1))
