#!/usr/bin/env python3
"""Regenerate worker/src/index.ts from the canonical HTML in docs/design/landing/.

The worker inlines each page as a template literal. Editing the literals by
hand invites escaping mistakes, so: edit the HTML sources, then run this.

Usage: scripts/generate-worker-site.py
"""

from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LANDING = REPO / "docs" / "design" / "landing" / "index.html"
GUIDE = REPO / "docs" / "design" / "landing" / "guide.html"
OUT = REPO / "worker" / "src" / "index.ts"

HEADER = """\
// Wink site — GENERATED from docs/design/landing/*.html by scripts/generate-worker-site.py.
// Do not edit the HTML literals by hand: edit the source files and regenerate.
"""

FETCH = """\
export default {
  async fetch(request: Request): Promise<Response> {
    const { pathname } = new URL(request.url);
    const html = pathname === "/guide" || pathname === "/guide/" ? guideHtml : landingHtml;
    return new Response(html, {
      headers: {
        "content-type": "text/html;charset=UTF-8",
        "cache-control": "public, max-age=3600",
      },
    });
  },
};
"""


def escape(html: str) -> str:
    return html.replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${")


def literal(name: str, path: Path) -> str:
    return f"const {name} = `{escape(path.read_text())}`;\n"


def main() -> None:
    OUT.write_text(
        HEADER
        + "\n"
        + literal("landingHtml", LANDING)
        + "\n"
        + literal("guideHtml", GUIDE)
        + "\n"
        + FETCH
    )
    print(f"wrote {OUT.relative_to(REPO)} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
