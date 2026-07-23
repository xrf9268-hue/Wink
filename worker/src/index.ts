// Wink site — GENERATED from docs/design/landing/*.html by scripts/generate-worker-site.py.
// Do not edit the HTML literals by hand: edit the source files and regenerate.

const landingHtml = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="Wink gives every app on your Mac its own keystroke. Turn Caps Lock into a Hyper key — press once to summon, again to dismiss. Free, open source, macOS 15+.">
<meta name="color-scheme" content="light dark">
<title>Wink — One chord, one destination</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Cmask id='m'%3E%3Crect width='32' height='32' fill='white'/%3E%3Ccircle cx='15' cy='9' r='11' fill='black'/%3E%3C/mask%3E%3Ccircle cx='16' cy='16' r='11' fill='%23FFB454' mask='url(%23m)'/%3E%3C/svg%3E">
</head>
<body>
<style>
  /* ---------- tokens ---------- */
  :root {
    --bg: #F3F5F9;
    --bg-glow: rgba(224, 138, 0, 0.06);
    --surface: #FFFFFF;
    --surface-2: #E9EDF4;
    --text: #171C26;
    --muted: #5A6478;
    --hairline: rgba(23, 28, 38, 0.12);
    --accent: #E08A00;
    --accent-ink: #96590A;
    --accent-soft: rgba(224, 138, 0, 0.14);
    --cta-bg: #171C26;
    --cta-text: #F6F8FC;
    --cta-hover: #232A38;
    --key-bg: #FFFFFF;
    --key-edge: #D4DAE4;
    --key-legend: #171C26;
    --win-shadow: 0 18px 44px rgba(23, 28, 38, 0.16);
    --panel-inner: #EDF0F6;
    --dot: rgba(23, 28, 38, 0.10);
    --term-bg: #10141E;
    --term-text: #C9D2E4;
    --ok: #4CAF6E;
    --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
    --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", "Segoe UI", sans-serif;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0A0D14;
      --bg-glow: rgba(255, 180, 84, 0.05);
      --surface: #131826;
      --surface-2: #1A2132;
      --text: #E9EDF6;
      --muted: #98A3BD;
      --hairline: rgba(152, 163, 189, 0.16);
      --accent: #FFB454;
      --accent-ink: #FFB454;
      --accent-soft: rgba(255, 180, 84, 0.13);
      --cta-bg: #FFB454;
      --cta-text: #1A1206;
      --cta-hover: #FFC377;
      --key-bg: #1A2132;
      --key-edge: #0A0D14;
      --key-legend: #E9EDF6;
      --win-shadow: 0 18px 44px rgba(0, 0, 0, 0.5);
      --panel-inner: #0D1120;
      --dot: rgba(152, 163, 189, 0.10);
    }
  }
  :root[data-theme="light"] {
    --bg: #F3F5F9;
    --bg-glow: rgba(224, 138, 0, 0.06);
    --surface: #FFFFFF;
    --surface-2: #E9EDF4;
    --text: #171C26;
    --muted: #5A6478;
    --hairline: rgba(23, 28, 38, 0.12);
    --accent: #E08A00;
    --accent-ink: #96590A;
    --accent-soft: rgba(224, 138, 0, 0.14);
    --cta-bg: #171C26;
    --cta-text: #F6F8FC;
    --cta-hover: #232A38;
    --key-bg: #FFFFFF;
    --key-edge: #D4DAE4;
    --key-legend: #171C26;
    --win-shadow: 0 18px 44px rgba(23, 28, 38, 0.16);
    --panel-inner: #EDF0F6;
    --dot: rgba(23, 28, 38, 0.10);
  }
  :root[data-theme="dark"] {
    --bg: #0A0D14;
    --bg-glow: rgba(255, 180, 84, 0.05);
    --surface: #131826;
    --surface-2: #1A2132;
    --text: #E9EDF6;
    --muted: #98A3BD;
    --hairline: rgba(152, 163, 189, 0.16);
    --accent: #FFB454;
    --accent-ink: #FFB454;
    --accent-soft: rgba(255, 180, 84, 0.13);
    --cta-bg: #FFB454;
    --cta-text: #1A1206;
    --cta-hover: #FFC377;
    --key-bg: #1A2132;
    --key-edge: #0A0D14;
    --key-legend: #E9EDF6;
    --win-shadow: 0 18px 44px rgba(0, 0, 0, 0.5);
    --panel-inner: #0D1120;
    --dot: rgba(152, 163, 189, 0.10);
  }

  /* ---------- base ---------- */
  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body {
    margin: 0;
    background: var(--bg);
    background-image: radial-gradient(1100px 460px at 50% -120px, var(--bg-glow), transparent 70%);
    background-repeat: no-repeat;
    color: var(--text);
    font-family: var(--sans);
    font-size: 16px;
    line-height: 1.65;
    -webkit-font-smoothing: antialiased;
  }
  a { color: var(--accent-ink); text-decoration: none; }
  a:hover { text-decoration: underline; text-underline-offset: 3px; }
  :focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; border-radius: 4px; }
  .wrap { max-width: 1080px; margin: 0 auto; padding: 0 24px; }
  h1, h2, h3 { text-wrap: balance; margin: 0; }
  p { margin: 0; }

  .eyebrow {
    font-family: var(--mono);
    font-size: 12px;
    font-weight: 500;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--accent-ink);
  }

  /* ---------- nav ---------- */
  .nav {
    position: sticky; top: 0; z-index: 50;
    background: color-mix(in srgb, var(--bg) 84%, transparent);
    -webkit-backdrop-filter: blur(14px);
    backdrop-filter: blur(14px);
    border-bottom: 1px solid var(--hairline);
  }
  .nav-inner { display: flex; align-items: center; gap: 28px; height: 60px; }
  .brand { display: flex; align-items: center; gap: 10px; color: var(--text); font-family: var(--mono); font-weight: 700; font-size: 17px; letter-spacing: -0.02em; }
  .brand:hover { text-decoration: none; }
  .nav-links { display: flex; gap: 24px; margin-left: auto; align-items: center; }
  .nav-links a:not(.btn) { color: var(--muted); font-size: 14px; font-weight: 500; }
  .nav-links a:not(.btn):hover { color: var(--text); text-decoration: none; }
  .nav .btn { height: 34px; padding: 0 14px; font-size: 13px; }
  @media (max-width: 720px) { .nav-links a:not(.btn) { display: none; } }

  /* logo mark */
  .mark .eye-open { transform-origin: 46px 16px; animation: blink 5.6s infinite; }
  @keyframes blink {
    0%, 91%, 100% { transform: scaleY(1); }
    94%, 96% { transform: scaleY(0.1); }
  }

  /* ---------- buttons ---------- */
  .btn {
    display: inline-flex; align-items: center; justify-content: center; gap: 8px;
    height: 46px; padding: 0 22px; border-radius: 10px;
    font-family: var(--sans); font-size: 15px; font-weight: 600;
    border: 1px solid transparent; cursor: pointer; white-space: nowrap;
  }
  .btn:hover { text-decoration: none; }
  .btn-primary, .btn-primary:hover, .btn-primary:visited { color: var(--cta-text); }
  .btn-primary { background: var(--cta-bg); }
  .btn-primary:hover { background: var(--cta-hover); }
  .btn-ghost { border-color: var(--hairline); color: var(--text); background: transparent; }
  .btn-ghost:hover { border-color: var(--muted); }

  /* ---------- hero ---------- */
  .hero { padding: 88px 0 0; text-align: center; }
  .hero-copy { display: flex; flex-direction: column; align-items: center; gap: 22px; }
  .dict { font-family: var(--mono); font-size: 13px; color: var(--muted); }
  .dict .word { color: var(--text); font-weight: 700; }
  .dict .ipa { color: var(--accent-ink); }
  .btn-2l { height: 58px; flex-direction: column; gap: 2px; padding: 0 24px; }
  .btn-sub { font-family: var(--mono); font-size: 10.5px; font-weight: 500; letter-spacing: 0.05em; opacity: 0.8; }
  .hstats { display: flex; gap: 44px; justify-content: center; flex-wrap: wrap; margin-top: 10px; }
  .hstat { display: flex; flex-direction: column; align-items: center; gap: 2px; max-width: 190px; }
  .hstat b { font-family: var(--mono); font-size: 30px; font-weight: 700; letter-spacing: -0.03em; color: var(--text); font-variant-numeric: tabular-nums; }
  .hstat span { font-family: var(--mono); font-size: 11px; color: var(--muted); letter-spacing: 0.03em; line-height: 1.5; }
  .hero h1 {
    font-family: var(--mono);
    font-size: clamp(42px, 7vw, 80px);
    font-weight: 700;
    letter-spacing: -0.05em;
    line-height: 1.02;
  }
  .hero h1 .dest { color: var(--accent-ink); }
  .hero .sub { color: var(--muted); font-size: 18px; max-width: 54ch; }
  .hero .sub strong { color: var(--text); font-weight: 600; }
  .hero-ctas { display: flex; gap: 12px; flex-wrap: wrap; justify-content: center; }
  .hero-meta { font-family: var(--mono); font-size: 12.5px; color: var(--muted); letter-spacing: 0.02em; }

  /* ---------- scene (interactive desktop) ---------- */
  .scene-region { margin-top: 56px; }
  .scene {
    border: 1px solid var(--hairline);
    border-radius: 16px;
    overflow: hidden;
    background: var(--surface);
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.10);
    text-align: left;
  }
  .scene-menubar {
    height: 32px; display: flex; align-items: center; gap: 10px;
    padding: 0 14px;
    background: color-mix(in srgb, var(--surface) 70%, var(--bg));
    border-bottom: 1px solid var(--hairline);
    font-family: var(--mono); font-size: 12px; color: var(--muted);
  }
  .scene-menubar .app-name { color: var(--text); font-weight: 600; }
  .scene-menubar .mb-right { margin-left: auto; display: flex; gap: 14px; align-items: center; }
  .scene-menubar .mb-right .ready { color: var(--accent-ink); }
  .scene-desk {
    position: relative; height: 336px;
    background-color: var(--panel-inner);
    background-image: radial-gradient(var(--dot) 1px, transparent 1px);
    background-size: 18px 18px;
    overflow: hidden;
  }
  .win {
    position: absolute; width: 56%; min-width: 250px;
    background: var(--surface);
    border: 1px solid var(--hairline);
    border-radius: 10px;
    overflow: hidden;
    box-shadow: 0 8px 22px rgba(0, 0, 0, 0.12);
    transition: transform 0.24s cubic-bezier(0.2, 0.8, 0.25, 1.15), opacity 0.18s ease, box-shadow 0.24s ease, filter 0.24s ease;
  }
  .win.is-front { box-shadow: var(--win-shadow); }
  .win:not(.is-front) { filter: brightness(0.95) saturate(0.9); }
  .win.is-hidden { transform: translateY(24px) scale(0.97) !important; opacity: 0; pointer-events: none; }
  .win-1 { left: 5%; top: 7%; }
  .win-2 { left: 22%; top: 18%; }
  .win-3 { left: 40%; top: 30%; }
  .win-bar { display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--hairline); }
  .dots { display: flex; gap: 5px; }
  .dots i { width: 9px; height: 9px; border-radius: 50%; }
  .dots i:nth-child(1) { background: #E0655F; }
  .dots i:nth-child(2) { background: #E0A33E; }
  .dots i:nth-child(3) { background: #62B554; }
  .win-title { font-size: 12.5px; font-weight: 600; color: var(--text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .url-pill {
    flex: 1; max-width: 210px; margin: 0 auto;
    font-family: var(--mono); font-size: 10.5px; color: var(--muted);
    background: var(--surface-2); border-radius: 6px;
    padding: 2px 10px; text-align: center;
    white-space: nowrap; overflow: hidden;
  }
  .win-body { padding: 13px 14px 16px; display: flex; flex-direction: column; gap: 8px; }
  .skl { height: 8px; border-radius: 4px; background: var(--surface-2); }
  .skl.hd { height: 12px; width: 52%; background: color-mix(in srgb, var(--text) 22%, var(--surface-2)); }
  .skl.w60 { width: 60%; } .skl.w85 { width: 85%; } .skl.w45 { width: 45%; } .skl.w75 { width: 75%; } .skl.w90 { width: 90%; }
  .term-body {
    background: var(--term-bg); color: var(--term-text);
    font-family: var(--mono); font-size: 11.5px; line-height: 1.9;
    padding: 12px 14px 16px;
  }
  .term-body .ps { color: #FFB454; }
  .term-body .ok { color: var(--ok); }
  .term-body .dim { opacity: 0.55; }
  .win-t .win-bar { background: color-mix(in srgb, var(--term-bg) 88%, #fff); border-bottom-color: rgba(255,255,255,0.06); }
  .win-t .win-title { color: #C9D2E4; }
  .win-t { border-color: rgba(255,255,255,0.08); }

  .scene-hud {
    position: absolute; left: 50%; bottom: 16px; transform: translateX(-50%);
    display: inline-flex; align-items: center; gap: 10px;
    font-family: var(--mono); font-size: 13px; color: var(--text);
    font-variant-numeric: tabular-nums;
    background: color-mix(in srgb, var(--surface) 92%, transparent);
    border: 1px solid var(--hairline);
    box-shadow: 0 10px 28px rgba(0, 0, 0, 0.18);
    padding: 8px 16px; border-radius: 99px;
    white-space: nowrap;
  }
  .scene-hud .act {
    padding: 1px 8px; border-radius: 99px;
    background: var(--accent-soft); color: var(--accent-ink);
    font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase;
  }
  .scene-hud.pop { animation: hudpop 0.22s ease; }
  @keyframes hudpop { 0% { transform: translateX(-50%) scale(0.94); } 100% { transform: translateX(-50%) scale(1); } }

  .scene-keys { display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; margin-top: 26px; }
  .keycol { display: flex; flex-direction: column; align-items: center; gap: 7px; }
  .keycap {
    appearance: none; border: 1px solid var(--hairline); margin: 0;
    min-width: 56px; height: 56px; padding: 0 16px;
    border-radius: 12px;
    background: var(--key-bg);
    box-shadow: 0 3px 0 var(--key-edge);
    color: var(--key-legend);
    font-family: var(--mono); font-size: 19px; font-weight: 600;
    cursor: pointer;
    transition: transform 0.09s ease, box-shadow 0.09s ease, border-color 0.09s ease;
    display: inline-flex; align-items: center; justify-content: center; gap: 8px;
  }
  .keycap:hover { border-color: var(--muted); }
  .keycap.is-pressed, .keycap:active {
    transform: translateY(3px);
    box-shadow: 0 0 0 var(--key-edge), 0 0 0 4px var(--accent-soft);
    border-color: var(--accent);
  }
  .keycap-hyper { padding: 0 20px; font-size: 15px; letter-spacing: 0.08em; }
  .keycap-hyper .caps { font-size: 20px; }
  .keycap-hyper.is-held { border-color: var(--accent); box-shadow: 0 3px 0 var(--key-edge), 0 0 0 4px var(--accent-soft); color: var(--accent-ink); }
  .key-label { font-family: var(--mono); font-size: 10.5px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); }
  .plus { align-self: center; margin-top: -22px; color: var(--muted); font-family: var(--mono); font-size: 15px; }
  .scene-hint { text-align: center; font-size: 12.5px; color: var(--muted); font-family: var(--mono); margin-top: 16px; }
  @media (max-width: 640px) { .scene-hint .desktop-only { display: none; } }

  /* ---------- interlude ---------- */
  .interlude { padding: 130px 0 26px; }
  .interlude .eyebrow { display: block; margin-bottom: 22px; }
  .interlude p {
    font-family: var(--mono);
    font-size: clamp(22px, 3.4vw, 38px);
    font-weight: 600;
    letter-spacing: -0.035em;
    line-height: 1.3;
    max-width: 26ch;
    text-wrap: balance;
  }
  .interlude .quiet { color: var(--muted); }
  .interlude mark {
    background: var(--accent-soft);
    color: var(--accent-ink);
    padding: 0 0.18em;
    border-radius: 6px;
  }

  /* ---------- sections ---------- */
  .section { padding: 104px 0 0; }
  .section-head { max-width: 660px; display: flex; flex-direction: column; gap: 14px; margin-bottom: 44px; }
  .section-head h2 {
    font-family: var(--mono);
    font-size: clamp(26px, 3.6vw, 40px);
    font-weight: 700;
    letter-spacing: -0.03em;
    line-height: 1.15;
  }
  .section-head .lede { color: var(--muted); font-size: 17px; max-width: 58ch; }

  /* ---------- keyboard map ---------- */
  .kbwrap { overflow-x: auto; padding-bottom: 8px; }
  .kb {
    display: flex; flex-direction: column; gap: 8px;
    width: max-content; margin: 0 auto;
    padding: 26px;
    background-color: var(--panel-inner);
    background-image: radial-gradient(var(--dot) 1px, transparent 1px);
    background-size: 18px 18px;
    border: 1px solid var(--hairline);
    border-radius: 18px;
  }
  .kb-row { display: flex; gap: 8px; }
  .kb-row.r2 { padding-left: 0; }
  .kb-row.r3 { padding-left: 66px; }
  .kb-row.r4 { justify-content: center; }
  .kcap {
    width: 52px; height: 52px; flex: none;
    border: 1px solid var(--hairline);
    border-radius: 10px;
    background: var(--key-bg);
    box-shadow: 0 2px 0 var(--key-edge);
    color: var(--muted);
    font-family: var(--mono); font-size: 14px; font-weight: 600;
    display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 2px;
    transition: transform 0.12s ease, box-shadow 0.12s ease, border-color 0.12s ease;
  }
  .kcap .lbl { font-size: 7.5px; font-weight: 500; letter-spacing: 0.04em; text-transform: uppercase; line-height: 1; }
  .kcap.bound { border-color: color-mix(in srgb, var(--accent) 55%, var(--hairline)); background: var(--accent-soft); color: var(--accent-ink); }
  .kcap.bound .lbl { color: var(--accent-ink); }
  .kcap:hover, .kcap.pulse { transform: translateY(-3px); box-shadow: 0 5px 0 var(--key-edge); }
  .kcap.bound:hover, .kcap.bound.pulse { border-color: var(--accent); box-shadow: 0 5px 0 var(--key-edge), 0 0 0 4px var(--accent-soft); }
  .kcap.wide { width: 110px; }
  .kcap.hyper { border-color: var(--accent); background: var(--accent-soft); color: var(--accent-ink); font-size: 12px; letter-spacing: 0.06em; }
  .kcap.space { width: 300px; }
  .kb-caption { text-align: center; font-family: var(--mono); font-size: 12px; color: var(--muted); margin-top: 18px; }
  body.caps-held .kcap.bound { transform: translateY(-3px); border-color: var(--accent); box-shadow: 0 5px 0 var(--key-edge), 0 0 0 4px var(--accent-soft); }
  body.caps-held .kcap.hyper, body.caps-held .keycap-hyper { border-color: var(--accent); box-shadow: 0 3px 0 var(--key-edge), 0 0 0 4px var(--accent-soft); color: var(--accent-ink); }

  /* ---------- showcases ---------- */
  .show {
    display: grid; grid-template-columns: 5fr 7fr; gap: 56px;
    align-items: center;
    padding: 84px 0 0;
  }
  .show.rev { grid-template-columns: 7fr 5fr; }
  .show.rev .show-copy { order: 2; }
  .show.rev .show-mock { order: 1; }
  @media (max-width: 880px) {
    .show, .show.rev { grid-template-columns: 1fr; gap: 34px; padding-top: 72px; }
    .show.rev .show-copy { order: 1; }
    .show.rev .show-mock { order: 2; }
  }
  .show-copy { display: flex; flex-direction: column; gap: 14px; align-items: flex-start; }
  .show-copy h3 {
    font-family: var(--mono);
    font-size: clamp(22px, 2.8vw, 30px);
    font-weight: 700;
    letter-spacing: -0.03em;
    line-height: 1.2;
  }
  .show-copy p { color: var(--muted); font-size: 16px; max-width: 44ch; }
  .show-copy p strong { color: var(--text); font-weight: 600; }
  .show-mock {
    min-height: 280px;
    background-color: var(--panel-inner);
    background-image: radial-gradient(var(--dot) 1px, transparent 1px);
    background-size: 18px 18px;
    border: 1px solid var(--hairline);
    border-radius: 16px;
    display: flex; align-items: center; justify-content: center;
    padding: 34px 26px;
    overflow: hidden;
  }
  kbd {
    font-family: var(--mono); font-size: 0.86em;
    background: var(--surface-2); border: 1px solid var(--hairline);
    border-radius: 5px; padding: 1px 6px;
  }

  /* palette mock */
  .pal {
    width: min(380px, 100%);
    background: var(--surface);
    border: 1px solid var(--hairline);
    border-radius: 12px;
    box-shadow: var(--win-shadow);
    overflow: hidden;
  }
  .pal-q {
    display: flex; align-items: center; gap: 9px;
    padding: 12px 15px;
    font-family: var(--mono); font-size: 15px;
    border-bottom: 1px solid var(--hairline);
  }
  .pal-q .pal-glass { flex: none; color: var(--muted); }
  .pal-q .caret { width: 8px; height: 18px; background: var(--accent); animation: caret 1.1s steps(1) infinite; }
  @keyframes caret { 50% { opacity: 0; } }
  .pal-r { display: flex; justify-content: space-between; align-items: center; padding: 10px 15px; font-size: 14px; }
  .pal-r .ret { font-family: var(--mono); font-size: 11.5px; color: var(--muted); }
  .pal-r.sel { background: var(--accent-soft); }
  .pal-r.sel .ret { color: var(--accent-ink); }
  .pal-r .app { display: flex; align-items: center; gap: 9px; }
  .app-dot { width: 18px; height: 18px; border-radius: 5px; flex: none; display: inline-flex; align-items: center; justify-content: center; font-family: var(--mono); font-size: 10px; font-weight: 700; color: #fff; }

  /* cycle mock */
  .cyc { width: min(400px, 100%); display: flex; flex-direction: column; align-items: center; gap: 20px; }
  .cyc-stack { position: relative; width: 100%; height: 190px; }
  .cyc-win {
    position: absolute; left: 50%; top: 0; width: 86%;
    background: var(--term-bg);
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 10px;
    overflow: hidden;
    transition: transform 0.3s cubic-bezier(0.2, 0.8, 0.25, 1.1), opacity 0.3s ease, filter 0.3s ease;
  }
  .cyc-win .win-bar { background: color-mix(in srgb, var(--term-bg) 88%, #fff); border-bottom-color: rgba(255,255,255,0.06); }
  .cyc-win .win-title { color: #C9D2E4; }
  .cyc-win .term-body { padding: 10px 13px 14px; font-size: 11px; }
  .cyc-win.p0 { transform: translateX(-50%) translateY(26px); z-index: 3; }
  .cyc-win.p1 { transform: translateX(-50%) translateY(13px) scale(0.94); z-index: 2; opacity: 0.75; filter: brightness(0.8); }
  .cyc-win.p2 { transform: translateX(-50%) translateY(0) scale(0.88); z-index: 1; opacity: 0.5; filter: brightness(0.65); }
  .cyc-hud {
    font-family: var(--mono); font-size: 13.5px;
    font-variant-numeric: tabular-nums;
    background: color-mix(in srgb, var(--surface) 92%, transparent);
    border: 1px solid var(--hairline);
    box-shadow: 0 10px 26px rgba(0, 0, 0, 0.16);
    padding: 8px 18px; border-radius: 99px;
    white-space: nowrap;
  }
  .cyc-hud b { color: var(--accent-ink); font-weight: 600; }

  /* picker mock */
  .pick { width: min(360px, 100%); display: flex; flex-direction: column; gap: 7px; }
  .pick-row {
    display: flex; align-items: center; gap: 10px;
    background: var(--surface);
    border: 1px solid var(--hairline);
    border-radius: 10px;
    padding: 10px 14px;
    font-size: 13.5px;
    transition: border-color 0.2s ease, background 0.2s ease;
  }
  .pick-row .ret { margin-left: auto; font-family: var(--mono); font-size: 11px; color: var(--muted); opacity: 0; }
  .pick-row.sel { border-color: var(--accent); background: var(--accent-soft); }
  .pick-row.sel .ret { opacity: 1; color: var(--accent-ink); }
  .pick-cap { font-family: var(--mono); font-size: 11.5px; color: var(--muted); text-align: center; margin-top: 10px; }

  /* insights mock */
  .ins { width: min(420px, 100%); display: flex; flex-direction: column; gap: 18px; }
  .ins-panel {
    background: var(--surface);
    border: 1px solid var(--hairline);
    border-radius: 14px;
    padding: 22px;
    display: flex; flex-direction: column; gap: 18px;
  }
  .stat-row { display: flex; gap: 26px; flex-wrap: wrap; }
  .stat b { display: block; font-family: var(--mono); font-size: 24px; font-weight: 700; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; }
  .stat span { font-size: 11.5px; color: var(--muted); font-family: var(--mono); letter-spacing: 0.05em; text-transform: uppercase; }
  .heatmap-grid { display: grid; grid-template-columns: repeat(14, 1fr); gap: 4px; }
  .heatmap-grid i { aspect-ratio: 1; border-radius: 3px; background: var(--accent); display: block; }
  .heatmap-foot { display: flex; justify-content: space-between; font-family: var(--mono); font-size: 10px; color: var(--muted); letter-spacing: 0.06em; margin-top: 6px; }
  .toast {
    display: flex; align-items: center; gap: 12px;
    background: var(--surface);
    border: 1px solid var(--hairline);
    border-radius: 12px;
    box-shadow: 0 12px 30px rgba(0, 0, 0, 0.14);
    padding: 13px 16px;
    font-size: 13.5px;
  }
  .toast .msg b { font-weight: 600; }
  .toast .msg span { display: block; color: var(--muted); font-size: 12px; }
  .toast .acts { margin-left: auto; display: flex; gap: 7px; }
  .mini-btn {
    font-family: var(--mono); font-size: 11.5px; font-weight: 600;
    padding: 5px 11px; border-radius: 7px;
    border: 1px solid var(--hairline); color: var(--muted);
  }
  .mini-btn.pri { background: var(--cta-bg); color: var(--cta-text); border-color: transparent; }

  /* quiet mock */
  .quiet-stack { width: min(420px, 100%); display: flex; flex-direction: column; gap: 12px; }
  .sec-banner {
    display: flex; align-items: center; gap: 11px;
    background: var(--accent-soft);
    border: 1px solid color-mix(in srgb, var(--accent) 40%, transparent);
    border-radius: 11px;
    padding: 12px 15px;
    font-family: var(--mono); font-size: 12.5px; color: var(--text);
  }
  .sec-banner .sig {
    width: 20px; height: 20px; border-radius: 50%; flex: none;
    background: var(--accent); color: var(--cta-text);
    display: inline-flex; align-items: center; justify-content: center;
    font-weight: 700; font-size: 13px; font-family: var(--mono);
  }
  .rule-row {
    display: flex; align-items: center; gap: 11px;
    background: var(--surface);
    border: 1px solid var(--hairline);
    border-radius: 11px;
    padding: 12px 15px;
    font-size: 13.5px;
  }
  .rule-row .chip-state { margin-left: auto; font-family: var(--mono); font-size: 11px; color: var(--accent-ink); background: var(--accent-soft); padding: 3px 10px; border-radius: 99px; letter-spacing: 0.05em; }
  .cli {
    background: var(--term-bg); color: var(--term-text);
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 11px;
    font-family: var(--mono); font-size: 12.5px; line-height: 2.1;
    padding: 14px 17px;
    overflow-x: auto;
  }
  .cli .ps { color: #FFB454; }
  .cli .dim { opacity: 0.55; }

  /* ---------- also in the box ---------- */
  .list { border-top: 1px solid var(--hairline); }
  .list-row {
    display: grid; grid-template-columns: 220px 1fr; gap: 24px;
    padding: 20px 0;
    border-bottom: 1px solid var(--hairline);
  }
  @media (max-width: 640px) { .list-row { grid-template-columns: 1fr; gap: 6px; } }
  .list-row .term { font-family: var(--mono); font-size: 14px; font-weight: 600; color: var(--accent-ink); }
  .list-row .desc { color: var(--muted); font-size: 15px; }
  .list-row .desc kbd { font-size: 0.82em; }
  .chips { display: inline-flex; gap: 6px; flex-wrap: wrap; vertical-align: middle; }
  .chip { font-family: var(--mono); font-size: 11.5px; padding: 2px 9px; border-radius: 6px; border: 1px solid var(--hairline); color: var(--muted); }
  .chip.is-on { border-color: var(--accent); color: var(--accent-ink); background: var(--accent-soft); }

  /* ---------- principles ---------- */
  .principles { display: grid; grid-template-columns: repeat(3, 1fr); border-block: 1px solid var(--hairline); margin-top: 118px; }
  .principle { padding: 42px 28px; }
  .principle + .principle { border-left: 1px solid var(--hairline); }
  @media (max-width: 820px) {
    .principles { grid-template-columns: 1fr; }
    .principle + .principle { border-left: none; border-top: 1px solid var(--hairline); }
  }
  .principle h3 { font-family: var(--mono); font-size: 19px; font-weight: 700; letter-spacing: -0.02em; margin-bottom: 8px; }
  .principle p { font-size: 14px; color: var(--muted); }

  /* ---------- download ---------- */
  .download { padding: 108px 0 96px; text-align: center; }
  .download-inner { display: flex; flex-direction: column; align-items: center; gap: 20px; }
  .download h2 { font-family: var(--mono); font-size: clamp(28px, 4.4vw, 50px); font-weight: 700; letter-spacing: -0.04em; }
  .download .ctas { display: flex; gap: 12px; flex-wrap: wrap; justify-content: center; }
  .download .meta { font-family: var(--mono); font-size: 13px; color: var(--muted); }
  .download .fine { font-size: 12.5px; color: var(--muted); max-width: 56ch; }

  /* ---------- footer ---------- */
  .footer { border-top: 1px solid var(--hairline); padding: 30px 0 44px; }
  .footer-inner { display: flex; align-items: center; gap: 22px; flex-wrap: wrap; }
  .footer .brand { font-size: 15px; }
  .footer nav { display: flex; gap: 20px; margin-left: auto; }
  .footer a { color: var(--muted); font-size: 13.5px; }
  .footer .tagline { width: 100%; font-family: var(--mono); font-size: 12px; color: var(--muted); }

  @media (prefers-reduced-motion: reduce) {
    html { scroll-behavior: auto; }
    .win, .keycap, .kcap, .cyc-win, .pick-row { transition: none; }
    .mark .eye-open, .pal-q .caret, .scene-hud.pop { animation: none; }
  }
</style>

<header class="nav">
  <div class="wrap nav-inner">
    <a class="brand" href="#top" aria-label="Wink home">
      <svg class="mark" width="34" height="17" viewBox="0 0 64 32" fill="none" aria-hidden="true">
        <mask id="wm1"><rect width="64" height="32" fill="#fff"/><circle cx="13" cy="9" r="11" fill="#000"/></mask>
        <circle cx="14" cy="16" r="11" fill="currentColor" mask="url(#wm1)"/>
        <circle class="eye-open" cx="46" cy="16" r="9" fill="currentColor"/>
      </svg>
      Wink
    </a>
    <nav class="nav-links" aria-label="Main">
      <a href="#map">The map</a>
      <a href="#features">Features</a>
      <a href="#insights">Insights</a>
      <a href="/guide">Guide</a>
      <a href="https://github.com/xrf9268-hue/Wink" rel="noopener">GitHub</a>
      <a class="btn btn-primary" href="https://github.com/xrf9268-hue/Wink/releases/latest" rel="noopener">Download</a>
    </nav>
  </div>
</header>

<main id="top">

  <!-- ================= hero ================= -->
  <section class="hero">
    <div class="wrap">
      <div class="hero-copy">
        <p class="dict"><span class="word">wink</span> <span class="ipa">/wɪŋk/</span> · <em>verb</em> — a quick close of one eye, as a signal</p>
        <h1>One chord.<br><span class="dest">One destination.</span></h1>
        <p class="sub">Wink gives every app on your Mac its own keystroke. <strong>Caps&nbsp;Lock becomes a Hyper key</strong>, and 26 letters become 26 destinations. Press to summon. Press again to dismiss.</p>
        <div class="hero-ctas">
          <a class="btn btn-primary btn-2l" href="https://github.com/xrf9268-hue/Wink/releases/latest" rel="noopener"><span>Download for macOS</span><span class="btn-sub">free · open source · direct DMG</span></a>
          <a class="btn btn-ghost btn-2l" href="https://github.com/xrf9268-hue/Wink" rel="noopener"><span>View on GitHub</span><span class="btn-sub">open source · Swift 6</span></a>
        </div>
        <div class="hstats">
          <div class="hstat"><b>26</b><span>letters — plus F-keys, arrows &amp; Space</span></div>
          <div class="hstat"><b>0</b><span>thumbnails — Screen Recording never asked</span></div>
          <div class="hstat"><b>1</b><span>key remapped — Caps&nbsp;Lock, reborn</span></div>
        </div>
      </div>

      <div class="scene-region">
        <div class="scene" aria-label="Interactive demo: press S, T or N to switch apps">
          <div class="scene-menubar">
            <svg class="mark" width="26" height="13" viewBox="0 0 64 32" fill="none" aria-hidden="true">
              <mask id="wm2"><rect width="64" height="32" fill="#fff"/><circle cx="13" cy="9" r="11" fill="#000"/></mask>
              <circle cx="14" cy="16" r="11" fill="currentColor" mask="url(#wm2)"/>
              <circle class="eye-open" cx="46" cy="16" r="9" fill="currentColor"/>
            </svg>
            <span class="app-name">Wink</span>
            <span class="mb-right"><span class="ready">⇪ ready</span><span>Mon 9:41</span></span>
          </div>
          <div class="scene-desk">
            <div class="win win-1" data-win="s">
              <div class="win-bar">
                <span class="dots"><i></i><i></i><i></i></span>
                <span class="url-pill">swift.org/documentation</span>
              </div>
              <div class="win-body"><span class="skl hd"></span><span class="skl w85"></span><span class="skl w90"></span><span class="skl w60"></span><span class="skl w75"></span></div>
            </div>
            <div class="win win-t win-2" data-win="t">
              <div class="win-bar">
                <span class="dots"><i></i><i></i><i></i></span>
                <span class="win-title">Terminal — zsh</span>
              </div>
              <div class="term-body">
                <div><span class="ps">$</span> swift build</div>
                <div class="dim">Compiling Wink (214 files)</div>
                <div><span class="ok">Build complete!</span> (2.14s)</div>
                <div><span class="ps">$</span> <span class="dim">▌</span></div>
              </div>
            </div>
            <div class="win win-3" data-win="n">
              <div class="win-bar">
                <span class="dots"><i></i><i></i><i></i></span>
                <span class="win-title">Notes — Ideas</span>
              </div>
              <div class="win-body"><span class="skl hd"></span><span class="skl w75"></span><span class="skl w45"></span><span class="skl w85"></span><span class="skl w60"></span></div>
            </div>
            <div class="scene-hud" id="scene-hud" aria-live="polite"></div>
          </div>
        </div>

        <div class="scene-keys">
          <div class="keycol">
            <button class="keycap keycap-hyper" id="key-hyper" type="button" aria-label="Hyper key (Caps Lock)"><span class="caps">⇪</span> hyper</button>
            <span class="key-label">caps lock</span>
          </div>
          <span class="plus">+</span>
          <div class="keycol"><button class="keycap" type="button" data-key="s">S</button><span class="key-label">Safari</span></div>
          <div class="keycol"><button class="keycap" type="button" data-key="t">T</button><span class="key-label">Terminal</span></div>
          <div class="keycol"><button class="keycap" type="button" data-key="n">N</button><span class="key-label">Notes</span></div>
        </div>
        <p class="scene-hint">click a key<span class="desktop-only"> — or just type <b>S</b>, <b>T</b>, <b>N</b></span></p>
      </div>
    </div>
  </section>

  <!-- ================= interlude ================= -->
  <section class="interlude">
    <div class="wrap">
      <span class="eyebrow">Why Wink</span>
      <p><span class="quiet">A switcher shows you every window, then asks you to choose.</span><br>Wink skips the question — <mark>you already knew where you were going.</mark></p>
    </div>
  </section>

  <!-- ================= keyboard map ================= -->
  <section class="section" id="map">
    <div class="wrap">
      <div class="section-head">
        <p class="eyebrow">The map</p>
        <h2>Hold ⇪ and the whole map appears.</h2>
        <p class="lede">Forget a binding? Hold the Hyper key: every shortcut you've taught Wink overlays your keyboard, and vanishes when you let go. Muscle memory, with training wheels that disappear.</p>
      </div>
      <div class="kbwrap">
        <div class="kb" id="kb" aria-label="Keyboard map of app shortcuts"></div>
      </div>
      <p class="kb-caption">this map is an example — yours will look like you · psst: your real ⇪ works on this page</p>
    </div>
  </section>

  <!-- ================= showcases ================= -->
  <section class="section" id="features" style="padding-top: 40px;">
    <div class="wrap">

      <div class="section-head">
        <p class="eyebrow">The system</p>
        <h2>One idea, five depths.</h2>
        <p class="lede">Summon and dismiss is day one. The rest reveals itself as you need it — numbered here in the order it'll find you.</p>
      </div>

      <div class="show" style="padding-top: 24px;">
        <div class="show-copy">
          <p class="eyebrow">01 · cycle</p>
          <h3>Press again.<br>Walk the windows.</h3>
          <p>Repeat the chord and Wink steps through that app's windows — <strong>minimized ones included</strong>, which <kbd>⌘\`</kbd> never manages. A HUD keeps count so you're never lost. And one chord can cycle whatever app you're in, wherever you are.</p>
        </div>
        <div class="show-mock">
          <div class="cyc" aria-hidden="true">
            <div class="cyc-stack">
              <div class="cyc-win" data-cyc="0">
                <div class="win-bar"><span class="dots"><i></i><i></i><i></i></span><span class="win-title">api — zsh</span></div>
                <div class="term-body"><div><span class="ps">$</span> npm run dev</div><div class="dim">listening on :3000</div></div>
              </div>
              <div class="cyc-win" data-cyc="1">
                <div class="win-bar"><span class="dots"><i></i><i></i><i></i></span><span class="win-title">build — watch</span></div>
                <div class="term-body"><div><span class="ps">$</span> swift build --watch</div><div class="dim">watching sources…</div></div>
              </div>
              <div class="cyc-win" data-cyc="2">
                <div class="win-bar"><span class="dots"><i></i><i></i><i></i></span><span class="win-title">ssh — deploy</span></div>
                <div class="term-body"><div><span class="ps">$</span> ssh prod</div><div class="dim">connected</div></div>
              </div>
            </div>
            <div class="cyc-hud" id="cyc-hud"><b>1 / 3</b> · api — zsh</div>
          </div>
        </div>
      </div>

      <div class="show rev">
        <div class="show-copy">
          <p class="eyebrow">02 · the picker</p>
          <h3>Hold, and choose for yourself.</h3>
          <p>Keep the chord held and that app's windows appear as a list — <strong>icons and titles, never thumbnails.</strong> That restraint is deliberate: it's why Wink works without Screen Recording, and always will.</p>
        </div>
        <div class="show-mock">
          <div class="pick" aria-hidden="true">
            <div class="pick-row" data-pick="0"><span class="app-dot" style="background:#3D7FC4">S</span>Docs — Swift.org<span class="ret">⏎</span></div>
            <div class="pick-row" data-pick="1"><span class="app-dot" style="background:#3D7FC4">S</span>Pull Requests — GitHub<span class="ret">⏎</span></div>
            <div class="pick-row" data-pick="2"><span class="app-dot" style="background:#3D7FC4">S</span>Release notes<span class="ret">⏎</span></div>
            <p class="pick-cap">holding ⇪S — ↑↓ choose · ⏎ switches</p>
          </div>
        </div>
      </div>

      <div class="show">
        <div class="show-copy">
          <p class="eyebrow">03 · search to switch</p>
          <h3>Two letters for everything else.</h3>
          <p>Some apps don't earn a key of their own. Summon the palette, type two letters, hit <kbd>⏎</kbd> — Wink takes you there. <strong>Every app is reachable, even the ones you never bound.</strong></p>
        </div>
        <div class="show-mock">
          <div class="pal" aria-hidden="true">
            <div class="pal-q"><svg class="pal-glass" width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true"><circle cx="7" cy="7" r="4.6" stroke="currentColor" stroke-width="1.6"/><path d="M10.4 10.4 L14 14" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg><span id="pal-q"></span><span class="caret"></span></div>
            <div id="pal-rs"></div>
          </div>
        </div>
      </div>

      <div class="show rev" id="insights">
        <div class="show-copy">
          <p class="eyebrow">04 · insights — local only</p>
          <h3>It keeps score. Locally.</h3>
          <p>Activations, streaks, time saved, your peak hours — kept in a SQLite file on your Mac and never uploaded anywhere. When an unbound app starts earning a key, <strong>Wink notices and suggests the binding.</strong></p>
        </div>
        <div class="show-mock">
          <div class="ins" aria-hidden="true">
            <div class="ins-panel">
              <div class="stat-row">
                <div class="stat"><b>1,284</b><span>activations</span></div>
                <div class="stat"><b>3.6 h</b><span>saved</span></div>
                <div class="stat"><b>16 d</b><span>streak</span></div>
              </div>
              <div>
                <div class="heatmap-grid" id="heatmap"></div>
                <div class="heatmap-foot"><span>8:00</span><span>your week, hour by hour</span><span>22:00</span></div>
              </div>
            </div>
            <div class="toast">
              <span class="app-dot" style="background:#8A63D2">F</span>
              <span class="msg"><b>Figma — 47 switches this week</b><span>No shortcut yet — give it a key?</span></span>
              <span class="acts"><span class="mini-btn pri">Suggested</span></span>
            </div>
          </div>
        </div>
      </div>

      <div class="show">
        <div class="show-copy">
          <p class="eyebrow">05 · quiet by design</p>
          <h3>It knows when to stay quiet.</h3>
          <p>A password field grabs Secure Input? The menu bar says so, and your ordinary modifier chords keep firing — the Caps&nbsp;Lock layer and Fn-row keys wait it out. Working inside a VM or remote desktop? Per-app rules pause your chords automatically. And scripts can drive everything through the <kbd>wink://</kbd> scheme.</p>
        </div>
        <div class="show-mock">
          <div class="quiet-stack" aria-hidden="true">
            <div class="sec-banner"><span class="sig">!</span>Limited · Secure&nbsp;Input — Hyper resumes when it ends</div>
            <div class="rule-row"><span class="app-dot" style="background:#C24B4B">P</span>Parallels Desktop<span class="chip-state">auto-pause · on</span></div>
            <div class="cli"><div><span class="ps">$</span> open -g "wink://toggle?bundle=com.figma.Desktop"</div><div class="dim">wink://pause · wink://resume — same idea</div></div>
          </div>
        </div>
      </div>

    </div>
  </section>

  <!-- ================= also in the box ================= -->
  <section class="section">
    <div class="wrap">
      <div class="section-head">
        <p class="eyebrow">Also in the box</p>
        <h2>The rest of it, briefly.</h2>
      </div>
      <div class="list">
        <div class="list-row">
          <span class="term">frontmost behaviors</span>
          <span class="desc"><span class="chips"><span class="chip">Hide</span><span class="chip">Toggle</span><span class="chip">Focus</span><span class="chip is-on">Cycle</span></span>&nbsp; — what a repeat press does. A global default, overridable per shortcut.</span>
        </div>
        <div class="list-row">
          <span class="term">.winkrecipe</span>
          <span class="desc">Your whole setup as one file. Version it, share it with your team, import it on a new Mac.</span>
        </div>
        <div class="list-row">
          <span class="term">简体中文</span>
          <span class="desc">Wink speaks English and Simplified Chinese, with more languages on the way.</span>
        </div>
        <div class="list-row">
          <span class="term">hyper, standard, or both</span>
          <span class="desc">Bind on the Hyper layer under Caps&nbsp;Lock, or on ordinary modifier combos — letters, F-keys, arrows and Space.</span>
        </div>
        <div class="list-row">
          <span class="term">set &amp; forget</span>
          <span class="desc">Launch at Login, signed updates that install from inside the app, and pause-all one click away in the menu bar.</span>
        </div>
      </div>
    </div>
  </section>

  <!-- ================= principles ================= -->
  <div class="wrap">
    <div class="principles">
      <div class="principle">
        <h3>No Screen Recording. Ever.</h3>
        <p>Window pickers and cycling are built on the Accessibility API — titles and icons, never thumbnails. That permission will never be requested.</p>
      </div>
      <div class="principle">
        <h3>Local-first.</h3>
        <p>No account, no cloud, no telemetry. Your usage data lives in a SQLite file you can delete any time; the only network calls are update checks.</p>
      </div>
      <div class="principle">
        <h3>Open source.</h3>
        <p>Swift 6, SwiftUI, built in the open on GitHub. Read every line before you trust it with your keyboard.</p>
      </div>
    </div>
  </div>

  <!-- ================= download ================= -->
  <section class="download" id="download">
    <div class="wrap download-inner">
      <svg class="mark" width="64" height="32" viewBox="0 0 64 32" fill="none" aria-hidden="true" style="color:var(--accent-ink)">
        <mask id="wm3"><rect width="64" height="32" fill="#fff"/><circle cx="13" cy="9" r="11" fill="#000"/></mask>
        <circle cx="14" cy="16" r="11" fill="currentColor" mask="url(#wm3)"/>
        <circle class="eye-open" cx="46" cy="16" r="9" fill="currentColor"/>
      </svg>
      <h2>Your Mac, one keystroke away.</h2>
      <div class="ctas">
        <a class="btn btn-primary btn-2l" href="https://github.com/xrf9268-hue/Wink/releases/latest" rel="noopener"><span>Download for macOS</span><span class="btn-sub">free · macOS 15 (Sequoia) or later</span></a>
        <a class="btn btn-ghost btn-2l" href="https://github.com/xrf9268-hue/Wink/blob/main/CHANGELOG.md" rel="noopener"><span>Changelog</span><span class="btn-sub">what's new</span></a>
      </div>
      <p class="meta">keeps itself updated · signed update feed · delete one file and it never existed</p>
      <p class="fine">Needs Accessibility to route shortcuts. Input Monitoring is requested only if you turn on the Hyper layer or Fn-row bindings. First launch: right-click the app → Open — notarization is on the way.</p>
    </div>
  </section>

</main>

<footer class="footer">
  <div class="wrap footer-inner">
    <a class="brand" href="#top">
      <svg class="mark" width="30" height="15" viewBox="0 0 64 32" fill="none" aria-hidden="true">
        <mask id="wm4"><rect width="64" height="32" fill="#fff"/><circle cx="13" cy="9" r="11" fill="#000"/></mask>
        <circle cx="14" cy="16" r="11" fill="currentColor" mask="url(#wm4)"/>
        <circle class="eye-open" cx="46" cy="16" r="9" fill="currentColor"/>
      </svg>
      Wink
    </a>
    <nav aria-label="Footer">
      <a href="/guide">Guide</a>
      <a href="https://github.com/xrf9268-hue/Wink" rel="noopener">GitHub</a>
      <a href="https://github.com/xrf9268-hue/Wink/blob/main/CHANGELOG.md" rel="noopener">Changelog</a>
      <a href="https://github.com/xrf9268-hue/Wink/blob/main/docs/privacy.md" rel="noopener">Privacy</a>
    </nav>
    <p class="tagline">made for people who'd rather not reach for the mouse</p>
  </div>
</footer>

<script>
  (function () {
    "use strict";

    var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    function loopWhenVisible(el, fn, ms) {
      if (reduceMotion || !el) return;
      var visible = true;
      if ("IntersectionObserver" in window) {
        visible = false;
        new IntersectionObserver(function (entries) {
          visible = entries[0].isIntersecting;
        }, { threshold: 0.25 }).observe(el);
      }
      setInterval(function () {
        if (!document.hidden && visible) fn();
      }, ms);
    }

    /* ----- hero scene ----- */
    var APPS = { s: "Safari", t: "Terminal", n: "Notes" };
    var wins = {};
    document.querySelectorAll("[data-win]").forEach(function (el) { wins[el.getAttribute("data-win")] = el; });
    var caps = document.querySelectorAll(".keycap[data-key]");
    var hyperKey = document.getElementById("key-hyper");
    var hud = document.getElementById("scene-hud");

    var order = ["s", "t", "n"];
    var hidden = {};

    function frontmost() {
      for (var i = order.length - 1; i >= 0; i--) {
        if (!hidden[order[i]]) return order[i];
      }
      return null;
    }

    function render() {
      order.forEach(function (k, i) {
        var el = wins[k];
        el.style.zIndex = String(i + 1);
        el.classList.toggle("is-front", k === frontmost());
        el.classList.toggle("is-hidden", !!hidden[k]);
      });
    }

    function setHud(key, name, action) {
      hud.innerHTML = "";
      var text = document.createElement("span");
      text.textContent = "⇪" + key.toUpperCase() + " · " + name;
      var act = document.createElement("span");
      act.className = "act";
      act.textContent = action;
      hud.appendChild(text);
      hud.appendChild(act);
      hud.classList.remove("pop");
      void hud.offsetWidth;
      hud.classList.add("pop");
    }

    function flashKey(k) {
      hyperKey.classList.add("is-held");
      setTimeout(function () { hyperKey.classList.remove("is-held"); }, 420);
      caps.forEach(function (btn) {
        if (btn.getAttribute("data-key") === k) {
          btn.classList.add("is-pressed");
          setTimeout(function () { btn.classList.remove("is-pressed"); }, 180);
        }
      });
    }

    function press(k) {
      if (!APPS[k]) return;
      flashKey(k);
      if (hidden[k]) {
        delete hidden[k];
        order.splice(order.indexOf(k), 1); order.push(k);
        setHud(k, APPS[k], "summoned");
      } else if (frontmost() === k) {
        hidden[k] = true;
        setHud(k, APPS[k], "dismissed");
      } else {
        order.splice(order.indexOf(k), 1); order.push(k);
        setHud(k, APPS[k], "summoned");
      }
      render();
    }

    render();
    setHud("n", "Notes", "summoned");

    var SEQ = ["t", "s", "s", "n", "t", "t", "s", "n", "n", "t"];
    var seqIdx = 0;
    var pauseUntil = 0;
    loopWhenVisible(document.querySelector(".scene"), function () {
      if (Date.now() < pauseUntil) return;
      press(SEQ[seqIdx]);
      seqIdx = (seqIdx + 1) % SEQ.length;
    }, 2100);

    function userPress(k) { pauseUntil = Date.now() + 8000; press(k); }
    caps.forEach(function (btn) {
      btn.addEventListener("click", function () { userPress(btn.getAttribute("data-key")); });
    });
    function syncCaps(e) {
      if (!e.getModifierState) return;
      document.body.classList.toggle("caps-held", e.getModifierState("CapsLock"));
    }
    document.addEventListener("keydown", function (e) {
      syncCaps(e);
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      var t = e.target;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
      var k = e.key.toLowerCase();
      if (APPS[k]) userPress(k);
    });
    document.addEventListener("keyup", syncCaps);

    /* ----- keyboard map ----- */
    var BINDINGS = {
      S: "Safari", T: "Terminal", N: "Notes", F: "Figma",
      Z: "Zed", M: "Mail", C: "Calendar", G: "Ghostty"
    };
    var ROWS = [
      ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"],
      ["CAPS", "A", "S", "D", "F", "G", "H", "J", "K", "L"],
      ["Z", "X", "C", "V", "B", "N", "M"],
      ["SPACE"]
    ];
    var kb = document.getElementById("kb");
    var boundEls = [];
    if (kb) {
      ROWS.forEach(function (row, ri) {
        var rowEl = document.createElement("div");
        rowEl.className = "kb-row r" + (ri + 1);
        row.forEach(function (key) {
          var cap = document.createElement("div");
          if (key === "CAPS") {
            cap.className = "kcap wide hyper";
            cap.textContent = "⇪ hyper";
          } else if (key === "SPACE") {
            cap.className = "kcap space";
            var lbl = document.createElement("span");
            lbl.className = "lbl";
            lbl.textContent = "also bindable";
            cap.appendChild(lbl);
          } else {
            cap.className = "kcap";
            cap.appendChild(document.createTextNode(key));
            if (BINDINGS[key]) {
              cap.classList.add("bound");
              var l = document.createElement("span");
              l.className = "lbl";
              l.textContent = BINDINGS[key];
              cap.appendChild(l);
              boundEls.push(cap);
            }
          }
          rowEl.appendChild(cap);
        });
        kb.appendChild(rowEl);
      });
    }
    var pulseIdx = 0;
    loopWhenVisible(kb, function () {
      if (!boundEls.length) return;
      var el = boundEls[pulseIdx % boundEls.length];
      el.classList.add("pulse");
      setTimeout(function () { el.classList.remove("pulse"); }, 650);
      pulseIdx++;
    }, 2600);

    /* ----- palette mock ----- */
    var QUERIES = [
      { q: "fi", hits: [["Figma", "#8A63D2", "F"], ["Firefox", "#D96B2B", "F"]] },
      { q: "te", hits: [["Terminal", "#2E3440", ">_"], ["TextEdit", "#7A8494", "T"]] },
      { q: "no", hits: [["Notes", "#D9A833", "N"], ["Notion", "#3A3F4A", "N"]] }
    ];
    var palQ = document.getElementById("pal-q");
    var palRs = document.getElementById("pal-rs");
    var palState = { qi: 0, ci: 0 };
    function renderPalRows(hits, showSel) {
      palRs.innerHTML = "";
      hits.forEach(function (h, i) {
        var row = document.createElement("div");
        row.className = "pal-r" + (showSel && i === 0 ? " sel" : "");
        var app = document.createElement("span");
        app.className = "app";
        var dot = document.createElement("span");
        dot.className = "app-dot";
        dot.style.background = h[1];
        dot.textContent = h[2];
        app.appendChild(dot);
        app.appendChild(document.createTextNode(h[0]));
        row.appendChild(app);
        var ret = document.createElement("span");
        ret.className = "ret";
        ret.textContent = showSel && i === 0 ? "⏎ switch" : "";
        row.appendChild(ret);
        palRs.appendChild(row);
      });
    }
    if (palQ && palRs) {
      renderPalRows(QUERIES[0].hits, true);
      palQ.textContent = QUERIES[0].q;
      palState.ci = QUERIES[0].q.length;
      loopWhenVisible(document.querySelector(".pal"), function () {
        var cur = QUERIES[palState.qi];
        if (palState.ci < cur.q.length) {
          palState.ci++;
          palQ.textContent = cur.q.slice(0, palState.ci);
          renderPalRows(cur.hits, palState.ci === cur.q.length);
        } else {
          palState.qi = (palState.qi + 1) % QUERIES.length;
          palState.ci = 0;
          palQ.textContent = "";
          renderPalRows(QUERIES[palState.qi].hits, false);
        }
      }, 900);
    }

    /* ----- cycle mock ----- */
    var cycWins = Array.prototype.slice.call(document.querySelectorAll("[data-cyc]"));
    var cycHud = document.getElementById("cyc-hud");
    var CYC_TITLES = ["api — zsh", "build — watch", "ssh — deploy"];
    var cycFront = 0;
    function renderCyc() {
      cycWins.forEach(function (el) {
        var idx = Number(el.getAttribute("data-cyc"));
        var pos = (idx - cycFront + 3) % 3;
        el.className = "cyc-win p" + pos;
      });
      cycHud.innerHTML = "";
      var b = document.createElement("b");
      b.textContent = (cycFront + 1) + " / 3";
      cycHud.appendChild(b);
      cycHud.appendChild(document.createTextNode(" · " + CYC_TITLES[cycFront]));
    }
    if (cycWins.length) {
      renderCyc();
      loopWhenVisible(document.querySelector(".cyc"), function () {
        cycFront = (cycFront + 1) % 3;
        renderCyc();
      }, 1700);
    }

    /* ----- picker mock ----- */
    var pickRows = Array.prototype.slice.call(document.querySelectorAll("[data-pick]"));
    var pickSel = 0;
    function renderPick() {
      pickRows.forEach(function (el, i) { el.classList.toggle("sel", i === pickSel); });
    }
    if (pickRows.length) {
      renderPick();
      loopWhenVisible(document.querySelector(".pick"), function () {
        pickSel = (pickSel + 1) % pickRows.length;
        renderPick();
      }, 1300);
    }

    /* ----- heatmap ----- */
    var LEVELS = [
      "01233210001221",
      "12344321012332",
      "23455432123443",
      "12344321123332",
      "01233210012221",
      "00122100001110",
      "00011000000100"
    ];
    var OPACITY = [0.07, 0.16, 0.3, 0.48, 0.68, 0.9];
    var grid = document.getElementById("heatmap");
    if (grid) {
      LEVELS.forEach(function (rowStr) {
        rowStr.split("").forEach(function (ch) {
          var cell = document.createElement("i");
          cell.style.opacity = String(OPACITY[Number(ch)]);
          grid.appendChild(cell);
        });
      });
    }
  })();
</script>
</body>
</html>
`;

const guideHtml = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="Every setting, permission, and keyboard quirk in Wink, explained plainly — from first launch to scripting it with wink://.">
<meta name="color-scheme" content="light dark">
<title>Wink — The manual</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Cmask id='m'%3E%3Crect width='32' height='32' fill='white'/%3E%3Ccircle cx='15' cy='9' r='11' fill='black'/%3E%3C/mask%3E%3Ccircle cx='16' cy='16' r='11' fill='%23FFB454' mask='url(%23m)'/%3E%3C/svg%3E">
</head>
<body>
<style>
  /* ---------- tokens (verbatim from index.html) ---------- */
  :root {
    --bg: #F3F5F9;
    --bg-glow: rgba(224, 138, 0, 0.06);
    --surface: #FFFFFF;
    --surface-2: #E9EDF4;
    --text: #171C26;
    --muted: #5A6478;
    --hairline: rgba(23, 28, 38, 0.12);
    --accent: #E08A00;
    --accent-ink: #96590A;
    --accent-soft: rgba(224, 138, 0, 0.14);
    --cta-bg: #171C26;
    --cta-text: #F6F8FC;
    --cta-hover: #232A38;
    --key-bg: #FFFFFF;
    --key-edge: #D4DAE4;
    --key-legend: #171C26;
    --win-shadow: 0 18px 44px rgba(23, 28, 38, 0.16);
    --panel-inner: #EDF0F6;
    --dot: rgba(23, 28, 38, 0.10);
    --term-bg: #10141E;
    --term-text: #C9D2E4;
    --ok: #4CAF6E;
    --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
    --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", "Segoe UI", sans-serif;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0A0D14;
      --bg-glow: rgba(255, 180, 84, 0.05);
      --surface: #131826;
      --surface-2: #1A2132;
      --text: #E9EDF6;
      --muted: #98A3BD;
      --hairline: rgba(152, 163, 189, 0.16);
      --accent: #FFB454;
      --accent-ink: #FFB454;
      --accent-soft: rgba(255, 180, 84, 0.13);
      --cta-bg: #FFB454;
      --cta-text: #1A1206;
      --cta-hover: #FFC377;
      --key-bg: #1A2132;
      --key-edge: #0A0D14;
      --key-legend: #E9EDF6;
      --win-shadow: 0 18px 44px rgba(0, 0, 0, 0.5);
      --panel-inner: #0D1120;
      --dot: rgba(152, 163, 189, 0.10);
    }
  }
  :root[data-theme="light"] {
    --bg: #F3F5F9;
    --bg-glow: rgba(224, 138, 0, 0.06);
    --surface: #FFFFFF;
    --surface-2: #E9EDF4;
    --text: #171C26;
    --muted: #5A6478;
    --hairline: rgba(23, 28, 38, 0.12);
    --accent: #E08A00;
    --accent-ink: #96590A;
    --accent-soft: rgba(224, 138, 0, 0.14);
    --cta-bg: #171C26;
    --cta-text: #F6F8FC;
    --cta-hover: #232A38;
    --key-bg: #FFFFFF;
    --key-edge: #D4DAE4;
    --key-legend: #171C26;
    --win-shadow: 0 18px 44px rgba(23, 28, 38, 0.16);
    --panel-inner: #EDF0F6;
    --dot: rgba(23, 28, 38, 0.10);
  }
  :root[data-theme="dark"] {
    --bg: #0A0D14;
    --bg-glow: rgba(255, 180, 84, 0.05);
    --surface: #131826;
    --surface-2: #1A2132;
    --text: #E9EDF6;
    --muted: #98A3BD;
    --hairline: rgba(152, 163, 189, 0.16);
    --accent: #FFB454;
    --accent-ink: #FFB454;
    --accent-soft: rgba(255, 180, 84, 0.13);
    --cta-bg: #FFB454;
    --cta-text: #1A1206;
    --cta-hover: #FFC377;
    --key-bg: #1A2132;
    --key-edge: #0A0D14;
    --key-legend: #E9EDF6;
    --win-shadow: 0 18px 44px rgba(0, 0, 0, 0.5);
    --panel-inner: #0D1120;
    --dot: rgba(152, 163, 189, 0.10);
  }

  /* ---------- base (verbatim from index.html) ---------- */
  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body {
    margin: 0;
    background: var(--bg);
    background-image: radial-gradient(1100px 460px at 50% -120px, var(--bg-glow), transparent 70%);
    background-repeat: no-repeat;
    color: var(--text);
    font-family: var(--sans);
    font-size: 16px;
    line-height: 1.65;
    -webkit-font-smoothing: antialiased;
  }
  a { color: var(--accent-ink); text-decoration: none; }
  a:hover { text-decoration: underline; text-underline-offset: 3px; }
  :focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; border-radius: 4px; }
  .wrap { max-width: 1080px; margin: 0 auto; padding: 0 24px; }
  h1, h2, h3 { text-wrap: balance; margin: 0; }
  p { margin: 0; }

  .eyebrow {
    font-family: var(--mono);
    font-size: 12px;
    font-weight: 500;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--accent-ink);
  }

  /* ---------- nav (verbatim from index.html) ---------- */
  .nav {
    position: sticky; top: 0; z-index: 50;
    background: color-mix(in srgb, var(--bg) 84%, transparent);
    -webkit-backdrop-filter: blur(14px);
    backdrop-filter: blur(14px);
    border-bottom: 1px solid var(--hairline);
  }
  .nav-inner { display: flex; align-items: center; gap: 28px; height: 60px; }
  .brand { display: flex; align-items: center; gap: 10px; color: var(--text); font-family: var(--mono); font-weight: 700; font-size: 17px; letter-spacing: -0.02em; }
  .brand:hover { text-decoration: none; }
  .nav-links { display: flex; gap: 24px; margin-left: auto; align-items: center; }
  .nav-links a:not(.btn) { color: var(--muted); font-size: 14px; font-weight: 500; }
  .nav-links a:not(.btn):hover { color: var(--text); text-decoration: none; }
  .nav .btn { height: 34px; padding: 0 14px; font-size: 13px; }
  @media (max-width: 720px) { .nav-links a:not(.btn) { display: none; } }

  /* logo mark (verbatim) */
  .mark .eye-open { transform-origin: 46px 16px; animation: blink 5.6s infinite; }
  @keyframes blink {
    0%, 91%, 100% { transform: scaleY(1); }
    94%, 96% { transform: scaleY(0.1); }
  }

  /* ---------- buttons (verbatim) ---------- */
  .btn {
    display: inline-flex; align-items: center; justify-content: center; gap: 8px;
    height: 46px; padding: 0 22px; border-radius: 10px;
    font-family: var(--sans); font-size: 15px; font-weight: 600;
    border: 1px solid transparent; cursor: pointer; white-space: nowrap;
  }
  .btn:hover { text-decoration: none; }
  .btn-primary, .btn-primary:hover, .btn-primary:visited { color: var(--cta-text); }
  .btn-primary { background: var(--cta-bg); }
  .btn-primary:hover { background: var(--cta-hover); }
  .btn-ghost { border-color: var(--hairline); color: var(--text); background: transparent; }
  .btn-ghost:hover { border-color: var(--muted); }
  .btn-2l { height: 58px; flex-direction: column; gap: 2px; padding: 0 24px; }
  .btn-sub { font-family: var(--mono); font-size: 10.5px; font-weight: 500; letter-spacing: 0.05em; opacity: 0.8; }

  /* dictionary-entry eyebrow (verbatim) */
  .dict { font-family: var(--mono); font-size: 13px; color: var(--muted); }
  .dict .word { color: var(--text); font-weight: 700; }
  .dict .ipa { color: var(--accent-ink); }

  kbd {
    font-family: var(--mono); font-size: 0.86em;
    background: var(--surface-2); border: 1px solid var(--hairline);
    border-radius: 5px; padding: 1px 6px;
  }

  /* terminal block (verbatim) */
  .cli {
    background: var(--term-bg); color: var(--term-text);
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 11px;
    font-family: var(--mono); font-size: 12.5px; line-height: 2.1;
    padding: 14px 17px;
    overflow-x: auto;
  }
  .cli .ps { color: #FFB454; }
  .cli .dim { opacity: 0.55; }

  /* chips (verbatim) */
  .chips { display: inline-flex; gap: 6px; flex-wrap: wrap; vertical-align: middle; }
  .chip { font-family: var(--mono); font-size: 11.5px; padding: 2px 9px; border-radius: 6px; border: 1px solid var(--hairline); color: var(--muted); }
  .chip.is-on { border-color: var(--accent); color: var(--accent-ink); background: var(--accent-soft); }

  /* list rows (verbatim) */
  .list { border-top: 1px solid var(--hairline); }
  .list-row {
    display: grid; grid-template-columns: 220px 1fr; gap: 24px;
    padding: 20px 0;
    border-bottom: 1px solid var(--hairline);
  }
  @media (max-width: 640px) { .list-row { grid-template-columns: 1fr; gap: 6px; } }
  .list-row .term { font-family: var(--mono); font-size: 14px; font-weight: 600; color: var(--accent-ink); }
  .list-row .desc { color: var(--muted); font-size: 15px; }
  .list-row .desc kbd { font-size: 0.82em; }

  /* dotted panel background (verbatim pattern) */
  .dotted-panel {
    background-color: var(--panel-inner);
    background-image: radial-gradient(var(--dot) 1px, transparent 1px);
    background-size: 18px 18px;
    border: 1px solid var(--hairline);
    border-radius: 16px;
  }

  /* ---------- footer (verbatim) ---------- */
  .footer { border-top: 1px solid var(--hairline); padding: 30px 0 44px; }
  .footer-inner { display: flex; align-items: center; gap: 22px; flex-wrap: wrap; }
  .footer .brand { font-size: 15px; }
  .footer nav { display: flex; gap: 20px; margin-left: auto; }
  .footer a { color: var(--muted); font-size: 13.5px; }
  .footer .tagline { width: 100%; font-family: var(--mono); font-size: 12px; color: var(--muted); }

  @media (prefers-reduced-motion: reduce) {
    html { scroll-behavior: auto; }
    .mark .eye-open { animation: none; }
  }

  /* =====================================================================
     Guide-specific CSS — same tokens, same idiom as index.html
     ===================================================================== */

  /* ---------- header block ---------- */
  .guide-hero { padding: 56px 0 28px; }
  .guide-hero-copy { display: flex; flex-direction: column; gap: 16px; max-width: 60ch; }
  .guide-hero h1 {
    font-family: var(--mono);
    font-size: clamp(36px, 6vw, 60px);
    font-weight: 700;
    letter-spacing: -0.045em;
    line-height: 1.04;
  }
  .guide-hero .sub { color: var(--muted); font-size: 17px; max-width: 56ch; }

  /* quick facts strip */
  .qf-row {
    display: flex; gap: 0;
    margin-top: 34px;
    padding: 4px 0;
  }
  .qf {
    flex: 1;
    display: flex; flex-direction: column; gap: 2px;
    padding: 14px 22px;
    border-left: 1px solid var(--hairline);
  }
  .qf:first-child { border-left: none; padding-left: 0; }
  .qf b { font-family: var(--mono); font-size: 26px; font-weight: 700; letter-spacing: -0.03em; color: var(--text); font-variant-numeric: tabular-nums; }
  .qf span { font-family: var(--mono); font-size: 11.5px; color: var(--muted); letter-spacing: 0.02em; line-height: 1.5; }
  @media (max-width: 640px) {
    .qf-row { flex-wrap: wrap; }
    .qf { flex: 1 1 45%; border-left: none; padding: 10px 0; }
  }

  /* ---------- two-column body ---------- */
  .guide-body { padding: 40px 0 0; }
  .guide-grid {
    display: grid;
    grid-template-columns: 176px minmax(0, 1fr);
    gap: 56px;
    align-items: start;
  }

  /* left rail TOC */
  .toc {
    position: sticky;
    top: 84px;
    display: flex;
    flex-direction: column;
    gap: 1px;
    font-family: var(--mono);
    font-size: 12.5px;
    padding-bottom: 24px;
  }
  .toc a {
    color: var(--muted);
    padding: 7px 0 7px 13px;
    border-left: 2px solid transparent;
    letter-spacing: 0.01em;
  }
  .toc a:hover { color: var(--accent-ink); text-decoration: none; border-left-color: color-mix(in srgb, var(--accent) 45%, transparent); }
  .toc a.is-current { color: var(--accent-ink); border-left-color: var(--accent); font-weight: 600; }
  .toc a.toc-extra { margin-top: 8px; padding-top: 10px; border-top: 1px solid var(--hairline); color: var(--muted); }

  @media (max-width: 880px) {
    .guide-grid { grid-template-columns: 1fr; gap: 8px; }
    .toc {
      position: static;
      flex-direction: row;
      flex-wrap: wrap;
      gap: 4px 4px;
      padding: 0 0 20px;
      margin-bottom: 24px;
      border-bottom: 1px solid var(--hairline);
    }
    .toc a {
      padding: 4px 9px;
      border-left: none;
      border-radius: 99px;
      border: 1px solid transparent;
    }
    .toc a:hover { border-color: color-mix(in srgb, var(--accent) 45%, transparent); }
    .toc a.is-current { border-color: var(--accent); background: var(--accent-soft); }
    .toc a.toc-extra { margin-top: 0; padding-top: 4px; border-top: none; }
  }

  /* content column — min-width: 0 so .cli scrollers can't widen the grid track */
  .content { max-width: 70ch; min-width: 0; }

  .chapter { padding: 52px 0; border-top: 1px solid var(--hairline); }
  .chapter:first-of-type { padding-top: 0; border-top: none; }
  .chapter .eyebrow { display: block; margin-bottom: 16px; }
  .chapter h2 {
    font-family: var(--mono);
    font-size: clamp(21px, 2.6vw, 28px);
    font-weight: 700;
    letter-spacing: -0.03em;
    line-height: 1.2;
    margin-bottom: 18px;
  }
  .chapter p { font-size: 16px; color: var(--text); margin-bottom: 15px; }
  .chapter p:last-child { margin-bottom: 0; }
  .chapter p.lead-chips { margin-bottom: 10px; color: var(--muted); }
  .chapter .chips { margin-bottom: 16px; }
  .chapter strong { font-weight: 600; }
  .chapter .cli { margin: 4px 0 16px; }

  /* closing "also, briefly" section */
  .closing { padding: 52px 0; border-top: 1px solid var(--hairline); }
  .closing .eyebrow { display: block; margin-bottom: 14px; }
  .closing h2 {
    font-family: var(--mono);
    font-size: clamp(21px, 2.6vw, 28px);
    font-weight: 700;
    letter-spacing: -0.03em;
    margin-bottom: 22px;
  }

  /* final cross-link */
  .guide-cta {
    padding: 52px 0 0;
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 16px;
  }
  .guide-cta h2 {
    font-family: var(--mono);
    font-size: clamp(24px, 3.2vw, 34px);
    font-weight: 700;
    letter-spacing: -0.035em;
  }
  .guide-cta .sub { color: var(--muted); font-size: 15px; }
</style>

<header class="nav">
  <div class="wrap nav-inner">
    <a class="brand" href="/" aria-label="Wink home">
      <svg class="mark" width="34" height="17" viewBox="0 0 64 32" fill="none" aria-hidden="true">
        <mask id="wm1"><rect width="64" height="32" fill="#fff"/><circle cx="13" cy="9" r="11" fill="#000"/></mask>
        <circle cx="14" cy="16" r="11" fill="currentColor" mask="url(#wm1)"/>
        <circle class="eye-open" cx="46" cy="16" r="9" fill="currentColor"/>
      </svg>
      Wink
    </a>
    <nav class="nav-links" aria-label="Main">
      <a href="/">Home</a>
      <a href="https://github.com/xrf9268-hue/Wink" rel="noopener">GitHub</a>
      <a class="btn btn-primary" href="https://github.com/xrf9268-hue/Wink/releases/latest" rel="noopener">Download</a>
    </nav>
  </div>
</header>

<main id="top">

  <!-- ================= header ================= -->
  <section class="guide-hero">
    <div class="wrap">
      <div class="guide-hero-copy">
        <p class="dict"><span class="word">manual</span> <span class="ipa">/ˈmanjuəl/</span> · <em>noun</em> — the book you keep next to the thing</p>
        <h1>The manual.</h1>
        <p class="sub">Setup, permissions, every frontmost behavior, the Hyper layer, and the <kbd>wink://</kbd> scheme — the whole thing, in the order you'll actually meet it.</p>
      </div>
      <div class="qf-row">
        <div class="qf"><b>10</b><span>chapters, start to finish</span></div>
        <div class="qf"><b>2</b><span>permissions — one of them conditional</span></div>
        <div class="qf"><b>0</b><span>thumbnails — Screen Recording never asked</span></div>
      </div>
    </div>
  </section>

  <!-- ================= two-column body ================= -->
  <section class="guide-body">
    <div class="wrap guide-grid">

      <nav class="toc" aria-label="Chapters">
        <a href="#install">00 · install</a>
        <a href="#permissions">01 · permissions</a>
        <a href="#first-chord">02 · first chord</a>
        <a href="#frontmost">03 · frontmost</a>
        <a href="#hyper">04 · hyper layer</a>
        <a href="#windows">05 · windows</a>
        <a href="#search">06 · search</a>
        <a href="#insights">07 · insights</a>
        <a href="#quiet">08 · quiet</a>
        <a href="#sharing">09 · sharing</a>
        <a href="#extras" class="toc-extra">also, briefly</a>
      </nav>

      <div class="content">

        <!-- 00 -->
        <article class="chapter" id="install">
          <p class="eyebrow">00 · install</p>
          <h2>Drag it in. Open it once.</h2>
          <p>Grab the DMG from <a href="https://github.com/xrf9268-hue/Wink/releases/latest" rel="noopener">GitHub Releases</a> and drag Wink into Applications. On first launch, macOS will balk at the unfamiliar signature — notarization is on the way. Right-click the app, choose <strong>Open</strong>, and macOS remembers that choice from then on.</p>
          <p>If this is a clean install with nothing configured yet, Wink opens Settings for you the moment it launches. You're never left staring at a bare menu bar icon wondering what to do next.</p>
          <p>Needs macOS 15 (Sequoia) or later. Nothing older is supported, and nothing more is required.</p>
        </article>

        <!-- 01 -->
        <article class="chapter" id="permissions">
          <p class="eyebrow">01 · permissions</p>
          <h2>Two permissions. Never three.</h2>
          <p class="lead-chips">One line of principle before the details:</p>
          <p class="chips">
            <span class="chip is-on">Accessibility · required</span>
            <span class="chip">Input Monitoring · conditional</span>
            <span class="chip">Screen Recording · never</span>
          </p>
          <p><strong>Accessibility</strong> is required — it's the API Wink uses to route every shortcut you record, standard chord or Hyper. Grant it in <strong>System Settings → Privacy &amp; Security → Accessibility</strong>, or work through the banner Wink shows at the top of <strong>Settings → Shortcuts</strong> until it clears.</p>
          <p><strong>Input Monitoring</strong> only gets asked for once your configuration actually needs it — turn on the Hyper Key, or bind something to the Fn row, and Wink requests it; leave both alone and it never appears. The Permissions card in <strong>Settings → General</strong> marks each one Granted, Needed, or Optional against what you've actually configured, not a fixed checklist.</p>
          <p><strong>Screen Recording</strong> isn't on that list, and it's not an oversight. Window pickers and window cycling read titles and icons through the Accessibility API alone — Wink has no use for a pixel of your screen, and it never will.</p>
        </article>

        <!-- 02 -->
        <article class="chapter" id="first-chord">
          <p class="eyebrow">02 · your first chord</p>
          <h2>Pick an app. Press a chord.</h2>
          <p>Open <strong>Settings → Shortcuts</strong>. The <strong>New Shortcut</strong> card asks for two things: a target app — search by name, pull from <strong>Recently Used</strong> or <strong>All Apps</strong>, or <strong>Browse…</strong> for anything living outside the usual folders — and a chord. Click into the Shortcut field and press your combination; it needs at least one modifier (⌘⌥⌃⇧), or you can skip that requirement entirely by binding it on the Hyper layer instead (chapter 04).</p>
          <p>Click <strong>Add Shortcut</strong>, and the chord is live everywhere, immediately. Press it once from any app and Wink brings your target forward, launching it first if it wasn't already running. Press it again, and what happens next depends on the frontmost behavior in effect — chapter 03.</p>
          <p>One entry in the picker is worth knowing about early: <strong>Current App</strong>, pinned at the top. Bind a chord to it, and that single chord always acts on whatever app happens to be frontmost right now — no per-app binding required.</p>
        </article>

        <!-- 03 -->
        <article class="chapter" id="frontmost">
          <p class="eyebrow">03 · frontmost behaviors</p>
          <h2>What the second press does.</h2>
          <p class="lead-chips">Four answers to the same question — what happens when you press a chord for an app that's already frontmost:</p>
          <p class="chips">
            <span class="chip">Hide</span>
            <span class="chip is-on">Toggle</span>
            <span class="chip">Focus</span>
            <span class="chip">Cycle</span>
          </p>
          <p><strong>Hide</strong> is the blunt one: if the app is frontmost, it hides. No questions asked, even if Wink wasn't what brought it forward.</p>
          <p><strong>Toggle</strong>, the default, is summon-then-dismiss with judgement — it hides the app once its activation has actually settled, so a fast double-press can't yank away a window that's still arriving.</p>
          <p><strong>Focus</strong> never hides anything: it un-hides and un-minimizes every one of that app's windows and keeps it in front, for an app you never want to lose track of.</p>
          <p><strong>Cycle</strong> steps through that app's windows instead of hiding anything — with one caveat for single-window apps, covered in chapter 05.</p>
          <p>Set the default in <strong>Settings → General</strong> under <strong>“When target is frontmost”</strong>, or override it for one shortcut from that row's ⋯ menu.</p>
        </article>

        <!-- 04 -->
        <article class="chapter" id="hyper">
          <p class="eyebrow">04 · the hyper layer</p>
          <h2>Caps Lock, promoted.</h2>
          <p>Turn on <strong>Hyper Key</strong> in <strong>Settings → General</strong>, and Caps Lock becomes a fifth modifier: hold it down and it behaves like <kbd>⌃⌥⇧⌘</kbd> together, so a bare letter can carry a whole chord. Hold it, tap a letter, done.</p>
          <p>While Hyper is on, the key is remapped away from Caps Lock entirely — a tap on its own does nothing: no shortcut, no capitals, no LED. Turn Hyper Key off and the key is its old self again. Quick fingers are fine, too: flick Caps Lock and let the letter land a breath late, and Wink still reads it as one chord — a release under about 80 milliseconds counts as part of the hold, not the end of it.</p>
          <p>Forgotten a binding? Hold Caps Lock for just over half a second without touching anything else, and every enabled shortcut — Hyper-bound or not — fades in as an overlay; let go, and it's gone. It needs Hyper Key on and at least one enabled Hyper shortcut before it has anything to show; Settings says as much, right under the toggle.</p>
        </article>

        <!-- 05 -->
        <article class="chapter" id="windows">
          <p class="eyebrow">05 · windows</p>
          <h2>Repeat the chord. Walk the windows.</h2>
          <p>Set a shortcut's frontmost behavior to <strong>Cycle</strong> (chapter 03), then repeat the chord while its app is frontmost: each press steps to the next window, minimized ones included. A small HUD tracks your place — <kbd>2/5</kbd> · window title — on whichever display that window actually lives on.</p>
          <p>One window (or none) is nothing to walk, so Cycle degrades on purpose: a concrete shortcut falls back to Toggle — press again and the app steps aside — while a Current App chord treats the press as a no-op, because "cycle whatever I'm in" must never hide the app under your hands.</p>
          <p>Prefer to choose instead of step through? Opt a shortcut into <strong>Hold Action → Window Picker</strong> from its row's ⋯ menu, then hold the chord instead of tapping it: a list of that app's windows appears, minimized ones marked, navigate with ↑↓ and commit with ⏎. Icons and titles only, never thumbnails — that restraint is what lets Wink run without Screen Recording, and it always will.</p>
        </article>

        <!-- 06 -->
        <article class="chapter" id="search">
          <p class="eyebrow">06 · search to switch</p>
          <h2>Type two letters. Land anywhere.</h2>
          <p>Give the palette its own trigger: <strong>Settings → General → Search Palette</strong>, recorded the same way as any other chord. Press it, type a few letters of any app's name — localized names match too — and hit <kbd>⏎</kbd>. Wink switches to it, launching it first if it wasn't already running.</p>
          <p>Recent switches float to the top of the empty-query list, so the app you just left is usually one keystroke away. Background agents and helper processes never show up — the palette only ever offers apps you could plausibly want to switch to.</p>
        </article>

        <!-- 07 -->
        <article class="chapter" id="insights">
          <p class="eyebrow">07 · insights</p>
          <h2>It keeps score. Quietly.</h2>
          <p><strong>Settings → Insights</strong> totals your activations, an estimated time saved (three seconds per switch, added up), your current streak of consecutive active days, and an hour-by-hour heatmap of when you actually reach for Wink. Flip between <strong>today</strong>, <strong>7 days</strong>, and <strong>30 days</strong> with the control at the top.</p>
          <p>All of it lives in a local SQLite file and is never uploaded — the Privacy page says so in plain terms, not fine print.</p>
          <p>Turn on <strong>“Suggest shortcuts from app usage”</strong> in Settings → General, and Wink starts counting foreground activations locally. An app you keep switching to but never bound shows up in the <strong>Suggested shortcuts</strong> card with its count for the period, and a note to add one in Shortcuts — a nudge, not an automatic bind. Turn the toggle back off, and Wink deletes the counts it collected, not just stops collecting them.</p>
        </article>

        <!-- 08 -->
        <article class="chapter" id="quiet">
          <p class="eyebrow">08 · quiet by design</p>
          <h2>It knows when to go quiet.</h2>
          <p class="lead-chips">The menu bar pill states the truth plainly:</p>
          <p class="chips">
            <span class="chip is-on">Ready</span>
            <span class="chip">Limited · Secure Input</span>
            <span class="chip">Paused</span>
            <span class="chip">Paused · &lt;App&gt;</span>
          </p>
          <p>A password field or secure prompt grabs macOS Secure Input, and the pill switches to <strong>Limited · Secure Input</strong>. The Hyper layer and Fn-row shortcuts wait it out — they ride the same event tap Secure Input blocks — while ordinary modifier-key shortcuts keep firing straight through it. It resumes on its own the moment Secure Input ends.</p>
          <p>Add an app under <strong>“Pause in exception apps”</strong> in Settings → General — a VM or remote-desktop client is the obvious case — and Wink pauses itself the instant that app is frontmost, the pill naming it directly (<strong>Paused · Parallels Desktop</strong>), and Caps Lock reverts fully to its native behavior for as long as that app stays in front.</p>
          <p>And there's a master switch for all of it: <strong>“Pause all shortcuts”</strong>, one toggle away in the menu bar.</p>
        </article>

        <!-- 09 -->
        <article class="chapter" id="sharing">
          <p class="eyebrow">09 · sharing &amp; scripting</p>
          <h2>Export it. Script it. Repeat it.</h2>
          <p>Your whole shortcut set is one file. <strong>Export…</strong> in <strong>Settings → Shortcuts</strong> writes a <kbd>.winkrecipe</kbd>; <strong>Import…</strong> reads one back. Importing previews a plan first — what's <strong>Ready</strong>, what <strong>Conflicts</strong>, what's <strong>Unresolved</strong> — before you commit to <strong>Skip Conflicts</strong> or <strong>Replace Existing</strong>.</p>
          <p>Everything is also reachable from outside the app, on the <kbd>wink://</kbd> scheme:</p>
          <div class="cli">
            <div><span class="ps">$</span> open -g "wink://toggle?bundle=com.google.Chrome"</div>
            <div class="dim">wink://pause · wink://resume — same idea</div>
          </div>
          <p>Always call it with <kbd>open -g</kbd>. A plain <kbd>open</kbd> activates Wink to deliver the URL, which makes your actual target read as “not frontmost” and turns every toggle into a plain activate; <kbd>-g</kbd> keeps Wink in the background so the toggle sees the real frontmost state. Automation presses respect the same per-bundle cooldown as a real keypress, but they never count toward Insights.</p>
        </article>

        <!-- closing -->
        <section class="closing" id="extras">
          <p class="eyebrow">Also, briefly</p>
          <h2>A few more things.</h2>
          <div class="list">
            <div class="list-row">
              <span class="term">updates</span>
              <span class="desc">The in-app Sparkle panel handles checking, downloading, and installing without leaving Wink. <strong>Check for Updates…</strong> lives in the menu bar; <strong>Automatic Updates</strong> in Settings → General turns background checks and downloads on or off.</span>
            </div>
            <div class="list-row">
              <span class="term">launch &amp; menu bar</span>
              <span class="desc"><strong>Launch at Login</strong> and <strong>Show Menu Bar Icon</strong> are both toggles in Settings → General.</span>
            </div>
            <div class="list-row">
              <span class="term">languages</span>
              <span class="desc">English and 简体中文 today, set from System Settings → General → Language &amp; Region — more are on the way.</span>
            </div>
            <div class="list-row">
              <span class="term">help</span>
              <span class="desc">Wink is open source. Read the code, file something, or just watch it get built — on GitHub.</span>
            </div>
          </div>
        </section>

        <!-- final cross-link -->
        <div class="guide-cta">
          <p class="eyebrow">Get Wink</p>
          <h2>End of the manual.</h2>
          <p class="sub">The rest is muscle memory. Free, open source, macOS 15 or later.</p>
          <a class="btn btn-primary btn-2l" href="/#download"><span>Download for macOS</span><span class="btn-sub">free · open source · direct DMG</span></a>
        </div>

      </div>
    </div>
  </section>

</main>

<footer class="footer">
  <div class="wrap footer-inner">
    <a class="brand" href="/">
      <svg class="mark" width="30" height="15" viewBox="0 0 64 32" fill="none" aria-hidden="true">
        <mask id="wm4"><rect width="64" height="32" fill="#fff"/><circle cx="13" cy="9" r="11" fill="#000"/></mask>
        <circle cx="14" cy="16" r="11" fill="currentColor" mask="url(#wm4)"/>
        <circle class="eye-open" cx="46" cy="16" r="9" fill="currentColor"/>
      </svg>
      Wink
    </a>
    <nav aria-label="Footer">
      <a href="https://github.com/xrf9268-hue/Wink" rel="noopener">GitHub</a>
      <a href="https://github.com/xrf9268-hue/Wink/blob/main/CHANGELOG.md" rel="noopener">Changelog</a>
      <a href="https://github.com/xrf9268-hue/Wink/blob/main/docs/privacy.md" rel="noopener">Privacy</a>
    </nav>
    <p class="tagline">made for people who'd rather not reach for the mouse</p>
  </div>
</footer>

<script>
  (function () {
    "use strict";
    var links = Array.prototype.slice.call(document.querySelectorAll(".toc a[href^='#']"));
    if (!links.length || !("IntersectionObserver" in window)) return;

    var map = {};
    links.forEach(function (a) { map[a.getAttribute("href").slice(1)] = a; });

    var sections = Object.keys(map)
      .map(function (id) { return document.getElementById(id); })
      .filter(Boolean);

    var current = links[0];
    current.classList.add("is-current");
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        var next = map[entry.target.id];
        if (!next || next === current) return;
        if (current) current.classList.remove("is-current");
        current = next;
        current.classList.add("is-current");
      });
    }, { rootMargin: "-15% 0px -70% 0px", threshold: 0 });

    sections.forEach(function (s) { observer.observe(s); });
  })();
</script>
</body>
</html>
`;

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
