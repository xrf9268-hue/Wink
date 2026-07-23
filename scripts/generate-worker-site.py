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
GUIDE_ZH = REPO / "docs" / "design" / "landing" / "guide-zh.html"
OUT = REPO / "worker" / "src" / "index.ts"

HEADER = """\
// Wink site — GENERATED from docs/design/landing/*.html by scripts/generate-worker-site.py.
// Do not edit the HTML literals by hand: edit the source files and regenerate.
"""

RUNTIME = """\
type Env = { MEDIA: R2Bucket };

const HTML_HEADERS = {
  "content-type": "text/html;charset=UTF-8",
  "cache-control": "public, max-age=3600",
};

// Guide media (demo videos, settings screenshots) lives in the release bucket
// under wink/guide/. Single-range support is required: Safari probes with
// `Range: bytes=0-1` and refuses <video> playback if the server ignores it.
async function serveMedia(request: Request, env: Env, pathname: string): Promise<Response> {
  const name = pathname.slice("/media/".length);
  if (!/^[a-z0-9-]+\\.(mp4|png)$/.test(name)) {
    return new Response("not found", { status: 404 });
  }
  const key = `wink/guide/${name}`;
  const headers: Record<string, string> = {
    "content-type": name.endsWith(".mp4") ? "video/mp4" : "image/png",
    "cache-control": "public, max-age=86400",
    "accept-ranges": "bytes",
  };

  const match = /^bytes=(\\d*)-(\\d*)$/.exec(request.headers.get("range") ?? "");
  if (match && (match[1] !== "" || match[2] !== "")) {
    const head = await env.MEDIA.head(key);
    if (!head) return new Response("not found", { status: 404 });
    const size = head.size;
    let start: number;
    let end: number;
    if (match[1] === "") {
      const suffix = Number(match[2]);
      if (suffix === 0) {
        return new Response(null, { status: 416, headers: { "content-range": `bytes */${size}` } });
      }
      start = Math.max(0, size - suffix);
      end = size - 1;
    } else {
      start = Number(match[1]);
      end = match[2] === "" ? size - 1 : Math.min(Number(match[2]), size - 1);
    }
    if (start > end || start >= size) {
      return new Response(null, { status: 416, headers: { "content-range": `bytes */${size}` } });
    }
    const object = await env.MEDIA.get(key, { range: { offset: start, length: end - start + 1 } });
    if (!object) return new Response("not found", { status: 404 });
    return new Response(object.body, {
      status: 206,
      headers: {
        ...headers,
        "content-range": `bytes ${start}-${end}/${size}`,
        "content-length": String(end - start + 1),
      },
    });
  }

  const object = await env.MEDIA.get(key);
  if (!object) return new Response("not found", { status: 404 });
  return new Response(object.body, {
    headers: { ...headers, "content-length": String(object.size) },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname.startsWith("/media/")) {
      return serveMedia(request, env, pathname);
    }
    if (pathname === "/guide/zh" || pathname === "/guide/zh/") {
      return new Response(guideZhHtml, { headers: HTML_HEADERS });
    }
    if (pathname === "/guide" || pathname === "/guide/") {
      return new Response(guideHtml, { headers: HTML_HEADERS });
    }
    return new Response(landingHtml, { headers: HTML_HEADERS });
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
        + literal("guideZhHtml", GUIDE_ZH)
        + "\n"
        + RUNTIME
    )
    print(f"wrote {OUT.relative_to(REPO)} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
