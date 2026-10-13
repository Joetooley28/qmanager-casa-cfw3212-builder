#!/usr/bin/env python3
"""Donate links: add a separate row of buttons for the Casa CFW-3212 port.

Upstream's three buttons (Wise, PayPal, GitHub Sponsors) stay unchanged and keep
going to Rus, who writes QManager. The Casa buttons (PayPal, Venmo, Cash App)
sit on their own row under a note saying they only support the CFW-3212 port.
`DonateLinks` is shared by the Donate dialog and the /support band, so one edit
covers both.
"""
import json
from pathlib import Path
import sys

CASA_PAYPAL = "https://paypal.me/Joetooley28"
CASA_VENMO = "https://venmo.com/u/Joetooley28"
CASA_CASHAPP = "https://cash.app/$jtooley8921"

# Cash App mark from simple-icons 13.21.0 (CC0). Venmo's mark is a wordmark
# that is unreadable at glyph size, so its button is text only.
CASHAPP_PATH = "M23.59 3.475a5.1 5.1 0 00-3.05-3.05c-1.31-.42-2.5-.42-4.92-.42H8.36c-2.4 0-3.61 0-4.9.4a5.1 5.1 0 00-3.05 3.06C0 4.765 0 5.965 0 8.365v7.27c0 2.41 0 3.6.4 4.9a5.1 5.1 0 003.05 3.05c1.3.41 2.5.41 4.9.41h7.28c2.41 0 3.61 0 4.9-.4a5.1 5.1 0 003.06-3.06c.41-1.3.41-2.5.41-4.9v-7.25c0-2.41 0-3.61-.41-4.91zm-6.17 4.63l-.93.93a.5.5 0 01-.67.01 5 5 0 00-3.22-1.18c-.97 0-1.94.32-1.94 1.21 0 .9 1.04 1.2 2.24 1.65 2.1.7 3.84 1.58 3.84 3.64 0 2.24-1.74 3.78-4.58 3.95l-.26 1.2a.49.49 0 01-.48.39H9.63l-.09-.01a.5.5 0 01-.38-.59l.28-1.27a6.54 6.54 0 01-2.88-1.57v-.01a.48.48 0 010-.68l1-.97a.49.49 0 01.67 0c.91.86 2.13 1.34 3.39 1.32 1.3 0 2.17-.55 2.17-1.42 0-.87-.88-1.1-2.54-1.72-1.76-.63-3.43-1.52-3.43-3.6 0-2.42 2.01-3.6 4.39-3.71l.25-1.23a.48.48 0 01.48-.38h1.78l.1.01c.26.06.43.31.37.57l-.27 1.37c.9.3 1.75.77 2.48 1.39l.02.02c.19.2.19.5 0 .68z"

target = Path(sys.argv[1])


def edit(rel, old, new):
    p = target / rel
    text = p.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"Donate patch anchor changed: {rel}: {old[:90]!r}")
    p.write_text(text.replace(old, new, 1))


links = "components/support/donate-links.tsx"

edit(
    links,
    '  SPONSORS: "https://github.com/sponsors/dr-dolomite",\n} as const;',
    '  SPONSORS: "https://github.com/sponsors/dr-dolomite",\n'
    "  // Casa: the CFW-3212 port only, not QManager itself.\n"
    f'  CASA_PAYPAL: "{CASA_PAYPAL}",\n'
    f'  CASA_VENMO: "{CASA_VENMO}",\n'
    f'  CASA_CASHAPP: "{CASA_CASHAPP}",\n'
    "} as const;",
)

edit(
    links,
    "/**\n * The three donation channels,",
    """function CashAppIcon({ className }: { className?: string }): React.JSX.Element {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="currentColor"
      className={className}
      aria-hidden="true"
    >
      <path d="%s" />
    </svg>
  );
}

/**
 * The three donation channels,""" % CASHAPP_PATH,
)

edit(
    links,
    """          GitHub Sponsors
          <span className="sr-only">{newTab}</span>
        </a>
      </Button>
    </div>""",
    """          GitHub Sponsors
          <span className="sr-only">{newTab}</span>
        </a>
      </Button>

      <div className="flex basis-full flex-col items-start gap-2 pt-1">
        <p className="text-xs text-muted-foreground">
          {t(`${K}.casa.note`)}
        </p>
        <div className="flex flex-wrap items-center gap-2.5">
          <Button asChild variant="outline" className={PILL_ACTION}>
            <a href={LINKS.CASA_PAYPAL} target="_blank" rel="noopener noreferrer">
              <PayPalIcon className={PILL_GLYPH} />
              PayPal
              <span className="sr-only">{t(`${K}.casa.sr_suffix`)} {newTab}</span>
            </a>
          </Button>
          <Button asChild variant="outline" className={PILL_ACTION}>
            <a href={LINKS.CASA_VENMO} target="_blank" rel="noopener noreferrer">
              Venmo
              <span className="sr-only">{t(`${K}.casa.sr_suffix`)} {newTab}</span>
            </a>
          </Button>
          <Button asChild variant="outline" className={PILL_ACTION}>
            <a href={LINKS.CASA_CASHAPP} target="_blank" rel="noopener noreferrer">
              <CashAppIcon className={PILL_GLYPH} />
              Cash App
              <span className="sr-only">{t(`${K}.casa.sr_suffix`)} {newTab}</span>
            </a>
          </Button>
        </div>
      </div>
    </div>""",
)

# v0.1.17 dropped PILL_ACTION for Button size="action"; follow it.
text = (target / links).read_text()
if "  PILL_ACTION,\n" not in text:
    text = text.replace('variant="outline" className={PILL_ACTION}', 'variant="outline" size="action"')
    if "PILL_ACTION" in text:
        raise SystemExit("Donate patch: PILL_ACTION left on a v0.1.17 donate-links.tsx")
    (target / links).write_text(text)

# --- English strings (other locales fall back to English) ---
loc = target / "public/locales/en/common.json"
data = json.loads(loc.read_text())
data["donate"]["casa"] = {
    "note": "The buttons above support Rus, who writes QManager. The buttons below support Joetooley, who only ported it to the Casa CFW-3212.",
    "sr_suffix": "for the Casa port,",
}
loc.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
