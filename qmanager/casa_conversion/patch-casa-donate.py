#!/usr/bin/env python3
"""Donate links: add a separate PayPal button for the Casa CFW-3212 port.

Upstream's three buttons (Wise, PayPal, GitHub Sponsors) stay unchanged and keep
going to Rus, who writes QManager. The Casa button sits on its own row under a
note saying it only supports the CFW-3212 port. `DonateLinks` is shared by the
Donate dialog and the /support band, so one edit covers both.
"""
import json
from pathlib import Path
import sys

CASA_PAYPAL = "https://paypal.me/Joetooley28"

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
    f'  // Casa: the CFW-3212 port only, not QManager itself.\n'
    f'  CASA_PAYPAL: "{CASA_PAYPAL}",\n'
    "} as const;",
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
        <Button asChild variant="outline" className={PILL_ACTION}>
          <a href={LINKS.CASA_PAYPAL} target="_blank" rel="noopener noreferrer">
            <PayPalIcon className={PILL_GLYPH} />
            {t(`${K}.casa.button`)}
            <span className="sr-only">{newTab}</span>
          </a>
        </Button>
      </div>
    </div>""",
)

# --- English strings (other locales fall back to English) ---
loc = target / "public/locales/en/common.json"
data = json.loads(loc.read_text())
data["donate"]["casa"] = {
    "note": "The buttons above support Rus, who writes QManager. The one below supports Joetooley, who only ported it to the Casa CFW-3212.",
    "button": "PayPal · Casa port",
}
loc.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
