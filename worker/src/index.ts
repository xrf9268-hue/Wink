const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Wink Cheat Sheet</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap');

  /* ---------- Light (default, eye-friendly) ---------- */
  :root {
    --bg: #f5f2ea;              /* warm off-white, low blue light */
    --surface: #ffffff;
    --surface-alt: #faf8f3;
    --border: #e5e1d8;
    --border-strong: #d6d2c8;
    --text: #2c2c2e;            /* dark charcoal, not pure black */
    --text-secondary: #6e6e73;
    --text-muted: #9a968c;
    --shadow-sm: 0 1px 2px rgba(60, 50, 30, 0.04), 0 2px 6px rgba(60, 50, 30, 0.05);
    --shadow-md: 0 4px 12px rgba(60, 50, 30, 0.06), 0 12px 28px rgba(60, 50, 30, 0.08);

    --hyper-bg: linear-gradient(135deg, #f3efff, #e9e2ff);
    --hyper-border: #cfc3f5;
    --hyper-color: #6b4fc1;

    --letter-bg: linear-gradient(135deg, #edf7ee, #dff0e1);
    --letter-border: #b6d9ba;
    --letter-color: #2e7a3a;

    --key-shadow: 0 1.5px 0 rgba(0, 0, 0, 0.08);

    --core: #2e7a3a;
    --core-bg: #e5f0e5;
    --dev: #2f5ea8;
    --dev-bg: #e4eaf4;
    --comm: #9e3fb3;
    --comm-bg: #f2e5f5;
    --util: #b3751a;
    --util-bg: #f5ebd9;
  }

  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #1e1f22;             /* soft dark, not pure black */
      --surface: #25262a;
      --surface-alt: #2a2b30;
      --border: #34363d;
      --border-strong: #43454d;
      --text: #e8e6e0;
      --text-secondary: #a8a6a0;
      --text-muted: #75736d;
      --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.2);
      --shadow-md: 0 8px 24px rgba(0, 0, 0, 0.3);

      --hyper-bg: linear-gradient(135deg, #2f2a45, #373055);
      --hyper-border: #4a4070;
      --hyper-color: #b4a3f0;

      --letter-bg: linear-gradient(135deg, #253b28, #2d4732);
      --letter-border: #3e5f43;
      --letter-color: #8ad197;

      --key-shadow: 0 2px 0 rgba(0, 0, 0, 0.3);

      --core: #8ad197;
      --core-bg: #253b28;
      --dev: #8aa9e0;
      --dev-bg: #283350;
      --comm: #e0a3ed;
      --comm-bg: #3d2a43;
      --util: #e8b567;
      --util-bg: #3e3222;
    }
  }

  * { margin: 0; padding: 0; box-sizing: border-box; }

  body {
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    display: flex;
    justify-content: center;
    padding: 40px 20px;
    -webkit-font-smoothing: antialiased;
    -moz-osx-font-smoothing: grayscale;
  }

  .container {
    max-width: 960px;
    width: 100%;
  }

  /* Header */
  .header {
    text-align: center;
    margin-bottom: 44px;
  }

  .header h1 {
    font-size: 42px;
    font-weight: 800;
    background: linear-gradient(135deg, #2e7a3a, #2f5ea8, #9e3fb3);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    background-clip: text;
    letter-spacing: -1px;
    margin-bottom: 14px;
  }

  @media (prefers-color-scheme: dark) {
    .header h1 {
      background: linear-gradient(135deg, #8ad197, #8aa9e0, #e0a3ed);
      -webkit-background-clip: text;
      background-clip: text;
    }
  }

  .header .subtitle {
    font-size: 14px;
    color: var(--text-secondary);
    font-weight: 400;
  }

  .header .subtitle kbd {
    display: inline-block;
    background: var(--hyper-bg);
    border: 1px solid var(--hyper-border);
    border-radius: 5px;
    padding: 2px 8px;
    font-family: inherit;
    font-size: 12px;
    color: var(--hyper-color);
    box-shadow: var(--key-shadow);
    vertical-align: middle;
    font-weight: 600;
  }

  /* Section */
  .section {
    margin-bottom: 32px;
  }

  .section-title {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 14px;
    padding-left: 4px;
  }

  .section-icon {
    width: 28px;
    height: 28px;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 14px;
  }

  .section-title h2 {
    font-size: 15px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1.5px;
  }

  .section-title .count {
    font-size: 11px;
    color: var(--text-muted);
    font-weight: 500;
    background: var(--surface-alt);
    border: 1px solid var(--border);
    padding: 2px 8px;
    border-radius: 10px;
  }

  /* Grid */
  .grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 10px;
  }

  /* Card */
  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 14px 16px;
    display: flex;
    align-items: center;
    gap: 14px;
    transition: all 0.2s ease;
    cursor: default;
    box-shadow: var(--shadow-sm);
  }

  .card:hover {
    border-color: var(--border-strong);
    transform: translateY(-2px);
    box-shadow: var(--shadow-md);
  }

  .key-combo {
    display: flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
  }

  .key {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 32px;
    height: 32px;
    padding: 0 8px;
    border-radius: 8px;
    font-size: 13px;
    font-weight: 700;
    border: 1px solid;
    box-shadow: var(--key-shadow);
    letter-spacing: 0.5px;
  }

  .key-hyper {
    background: var(--hyper-bg);
    border-color: var(--hyper-border);
    color: var(--hyper-color);
    font-size: 11px;
    padding: 0 10px;
  }

  .key-letter {
    background: var(--letter-bg);
    border-color: var(--letter-border);
    color: var(--letter-color);
    font-size: 16px;
    font-weight: 800;
    min-width: 36px;
    height: 36px;
  }

  .key-plus {
    color: var(--text-muted);
    font-size: 14px;
    font-weight: 400;
  }

  .app-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .app-name {
    font-size: 14px;
    font-weight: 600;
    color: var(--text);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .app-hint {
    font-size: 11px;
    color: var(--text-muted);
    font-weight: 400;
  }

  /* Category colors */
  .cat-core .section-icon { background: var(--core-bg); color: var(--core); }
  .cat-core .section-title h2 { color: var(--core); }

  .cat-dev .section-icon { background: var(--dev-bg); color: var(--dev); }
  .cat-dev .section-title h2 { color: var(--dev); }

  .cat-comm .section-icon { background: var(--comm-bg); color: var(--comm); }
  .cat-comm .section-title h2 { color: var(--comm); }

  .cat-util .section-icon { background: var(--util-bg); color: var(--util); }
  .cat-util .section-title h2 { color: var(--util); }

  /* Category card accent */
  .cat-core .card { border-left: 3px solid var(--core); }
  .cat-dev .card { border-left: 3px solid var(--dev); }
  .cat-comm .card { border-left: 3px solid var(--comm); }
  .cat-util .card { border-left: 3px solid var(--util); }

  /* Footer */
  .footer {
    text-align: center;
    margin-top: 44px;
    padding-top: 24px;
    border-top: 1px solid var(--border);
  }

  .footer p {
    font-size: 12px;
    color: var(--text-secondary);
    line-height: 2;
  }

  .footer .repo-link {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    margin-top: 12px;
    padding: 6px 12px;
    font-size: 12px;
    color: var(--text-secondary);
    text-decoration: none;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 999px;
    box-shadow: var(--shadow-sm);
    transition: all 0.2s ease;
  }

  .footer .repo-link:hover {
    color: var(--text);
    border-color: var(--border-strong);
    transform: translateY(-1px);
    box-shadow: var(--shadow-md);
  }

  .footer .repo-link svg {
    width: 14px;
    height: 14px;
  }

  .footer kbd {
    display: inline-block;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 1px 6px;
    font-family: inherit;
    font-size: 11px;
    color: var(--text-secondary);
    box-shadow: var(--key-shadow);
  }

  /* Keyboard visual */
  .keyboard-row {
    display: flex;
    justify-content: center;
    gap: 5px;
    margin-bottom: 5px;
  }

  .kb-key {
    width: 44px;
    height: 44px;
    border-radius: 7px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 13px;
    font-weight: 600;
    border: 1px solid var(--border);
    background: var(--surface);
    color: var(--text-muted);
    position: relative;
    transition: all 0.2s;
    box-shadow: var(--key-shadow);
  }

  .kb-key.active {
    background: var(--letter-bg);
    border-color: var(--letter-border);
    color: var(--letter-color);
  }

  .kb-key.active .kb-app {
    position: absolute;
    bottom: 2px;
    font-size: 6px;
    color: var(--letter-color);
    opacity: 0.7;
    letter-spacing: 0;
    max-width: 40px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-weight: 500;
  }

  .kb-key.hyper-key {
    width: 72px;
    background: var(--hyper-bg);
    border-color: var(--hyper-border);
    color: var(--hyper-color);
    font-size: 10px;
  }

  .keyboard-visual {
    margin: 32px 0 40px;
    padding: 28px;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 18px;
    box-shadow: var(--shadow-sm);
  }

  .keyboard-visual h3 {
    text-align: center;
    font-size: 11px;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 2px;
    margin-bottom: 20px;
    font-weight: 600;
  }

  /* Print */
  @media print {
    body { background: #fff; color: #111; padding: 20px; }
    .card, .keyboard-visual { box-shadow: none; }
    .card:hover { transform: none; }
  }

  @media (max-width: 768px) {
    .grid { grid-template-columns: repeat(2, 1fr); }
  }

  @media (max-width: 480px) {
    .grid { grid-template-columns: 1fr; }
    .header h1 { font-size: 32px; }
  }
</style>
</head>
<body>
<div class="container">

  <div class="header">
    <h1>Wink Cheat Sheet</h1>
    <p class="subtitle"><kbd>Hyper</kbd> = <kbd>Caps Lock</kbd> = <kbd>^</kbd><kbd>&#x2325;</kbd><kbd>&#x21E7;</kbd><kbd>&#x2318;</kbd>&nbsp; &mdash; &nbsp;One key to rule them all</p>
  </div>

  <!-- Keyboard Visual -->
  <div class="keyboard-visual">
    <h3>Keyboard Map</h3>
    <div class="keyboard-row">
      <div class="kb-key">Q</div>
      <div class="kb-key active">W<span class="kb-app">WeChat</span></div>
      <div class="kb-key">E</div>
      <div class="kb-key active">R<span class="kb-app">Firefox</span></div>
      <div class="kb-key active">T<span class="kb-app">Telegram</span></div>
      <div class="kb-key">Y</div>
      <div class="kb-key">U</div>
      <div class="kb-key active">I<span class="kb-app">iTerm</span></div>
      <div class="kb-key active">O<span class="kb-app">Obsidian</span></div>
      <div class="kb-key active">P<span class="kb-app">PDF Exp</span></div>
    </div>
    <div class="keyboard-row">
      <div class="kb-key hyper-key">Hyper</div>
      <div class="kb-key active">A<span class="kb-app">Antigrav</span></div>
      <div class="kb-key active">S<span class="kb-app">Safari</span></div>
      <div class="kb-key active">D<span class="kb-app">DingTalk</span></div>
      <div class="kb-key active">F<span class="kb-app">Finder</span></div>
      <div class="kb-key active">G<span class="kb-app">Ghostty</span></div>
      <div class="kb-key active">H<span class="kb-app">ChatGPT</span></div>
      <div class="kb-key">J</div>
      <div class="kb-key active">K<span class="kb-app">Keynote</span></div>
      <div class="kb-key">L</div>
    </div>
    <div class="keyboard-row">
      <div class="kb-key active">Z<span class="kb-app">Zed</span></div>
      <div class="kb-key active">X<span class="kb-app">Codex</span></div>
      <div class="kb-key active">C<span class="kb-app">Claude</span></div>
      <div class="kb-key active">V<span class="kb-app">VS Code</span></div>
      <div class="kb-key active">B<span class="kb-app">Chrome</span></div>
      <div class="kb-key active">N<span class="kb-app">Notes</span></div>
      <div class="kb-key active">M<span class="kb-app">IINA</span></div>
    </div>
  </div>

  <!-- Core Apps -->
  <div class="section cat-core">
    <div class="section-title">
      <div class="section-icon">&#9733;</div>
      <h2>Core</h2>
      <span class="count">5 shortcuts</span>
    </div>
    <div class="grid">
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">S</span>
        </div>
        <div class="app-info">
          <span class="app-name">Safari</span>
          <span class="app-hint">S = Safari</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">B</span>
        </div>
        <div class="app-info">
          <span class="app-name">Chrome</span>
          <span class="app-hint">B = Browser</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">R</span>
        </div>
        <div class="app-info">
          <span class="app-name">Firefox</span>
          <span class="app-hint">R = fiRefox</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">F</span>
        </div>
        <div class="app-info">
          <span class="app-name">Finder</span>
          <span class="app-hint">F = Finder</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">O</span>
        </div>
        <div class="app-info">
          <span class="app-name">Obsidian</span>
          <span class="app-hint">O = Obsidian</span>
        </div>
      </div>
    </div>
  </div>

  <!-- Dev Tools -->
  <div class="section cat-dev">
    <div class="section-title">
      <div class="section-icon">&#x2699;</div>
      <h2>Dev Tools</h2>
      <span class="count">7 shortcuts</span>
    </div>
    <div class="grid">
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">A</span>
        </div>
        <div class="app-info">
          <span class="app-name">Antigravity</span>
          <span class="app-hint">A = Antigravity</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">Z</span>
        </div>
        <div class="app-info">
          <span class="app-name">Zed</span>
          <span class="app-hint">Z = Zed</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">V</span>
        </div>
        <div class="app-info">
          <span class="app-name">VS Code</span>
          <span class="app-hint">V = VS Code</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">G</span>
        </div>
        <div class="app-info">
          <span class="app-name">Ghostty</span>
          <span class="app-hint">G = Ghostty</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">I</span>
        </div>
        <div class="app-info">
          <span class="app-name">iTerm</span>
          <span class="app-hint">I = iTerm</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">C</span>
        </div>
        <div class="app-info">
          <span class="app-name">Claude</span>
          <span class="app-hint">C = Claude</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">X</span>
        </div>
        <div class="app-info">
          <span class="app-name">Codex</span>
          <span class="app-hint">X = codeX</span>
        </div>
      </div>
    </div>
  </div>

  <!-- Communication -->
  <div class="section cat-comm">
    <div class="section-title">
      <div class="section-icon">&#x2709;</div>
      <h2>Communication</h2>
      <span class="count">4 shortcuts</span>
    </div>
    <div class="grid">
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">W</span>
        </div>
        <div class="app-info">
          <span class="app-name">WeChat</span>
          <span class="app-hint">W = WeChat</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">D</span>
        </div>
        <div class="app-info">
          <span class="app-name">DingTalk</span>
          <span class="app-hint">D = DingTalk</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">T</span>
        </div>
        <div class="app-info">
          <span class="app-name">Telegram</span>
          <span class="app-hint">T = Telegram</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">H</span>
        </div>
        <div class="app-info">
          <span class="app-name">ChatGPT</span>
          <span class="app-hint">H = cHatGPT</span>
        </div>
      </div>
    </div>
  </div>

  <!-- Utilities -->
  <div class="section cat-util">
    <div class="section-title">
      <div class="section-icon">&#x2606;</div>
      <h2>Utilities</h2>
      <span class="count">4 shortcuts</span>
    </div>
    <div class="grid">
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">N</span>
        </div>
        <div class="app-info">
          <span class="app-name">Notes</span>
          <span class="app-hint">N = Notes</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">K</span>
        </div>
        <div class="app-info">
          <span class="app-name">Keynote</span>
          <span class="app-hint">K = Keynote</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">P</span>
        </div>
        <div class="app-info">
          <span class="app-name">PDF Expert</span>
          <span class="app-hint">P = PDF</span>
        </div>
      </div>
      <div class="card">
        <div class="key-combo">
          <span class="key key-hyper">Hyper</span>
          <span class="key-plus">+</span>
          <span class="key key-letter">M</span>
        </div>
        <div class="app-info">
          <span class="app-name">IINA</span>
          <span class="app-hint">M = Media</span>
        </div>
      </div>
    </div>
  </div>

  <div class="footer">
    <p>
      <kbd>Hyper</kbd> = Caps Lock remapped via <strong>Wink</strong> &nbsp;|&nbsp;
      Available: <kbd>E</kbd> <kbd>J</kbd> <kbd>L</kbd> <kbd>Q</kbd> <kbd>U</kbd> <kbd>Y</kbd>
    </p>
    <a class="repo-link" href="https://github.com/xrf9268-hue/Wink" target="_blank" rel="noopener noreferrer" aria-label="View on GitHub">
      <svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.012 8.012 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>
      <span>xrf9268-hue/Wink</span>
    </a>
  </div>

</div>
</body>
</html>`;

export default {
  async fetch(): Promise<Response> {
    return new Response(html, {
      headers: {
        "content-type": "text/html;charset=UTF-8",
        "cache-control": "public, max-age=3600",
      },
    });
  },
};
