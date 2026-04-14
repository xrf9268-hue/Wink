const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Quickey Cheat Sheet</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap');

  * { margin: 0; padding: 0; box-sizing: border-box; }

  body {
    font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
    background: #0a0a0a;
    color: #e0e0e0;
    min-height: 100vh;
    display: flex;
    justify-content: center;
    padding: 40px 20px;
  }

  .container {
    max-width: 960px;
    width: 100%;
  }

  /* Header */
  .header {
    text-align: center;
    margin-bottom: 48px;
  }

  .header h1 {
    font-size: 42px;
    font-weight: 800;
    background: linear-gradient(135deg, #34d399, #3b82f6, #a78bfa);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    letter-spacing: -1px;
    margin-bottom: 12px;
  }

  .header .subtitle {
    font-size: 15px;
    color: #666;
    font-weight: 400;
  }

  .header .subtitle kbd {
    display: inline-block;
    background: #1a1a2e;
    border: 1px solid #333;
    border-radius: 5px;
    padding: 2px 8px;
    font-family: inherit;
    font-size: 12px;
    color: #a78bfa;
    box-shadow: 0 2px 0 #222;
    vertical-align: middle;
  }

  /* Section */
  .section {
    margin-bottom: 36px;
  }

  .section-title {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 16px;
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
    font-size: 16px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1.5px;
  }

  .section-title .count {
    font-size: 11px;
    color: #555;
    font-weight: 500;
    background: #1a1a1a;
    padding: 2px 8px;
    border-radius: 10px;
  }

  /* Grid */
  .grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 12px;
  }

  /* Card */
  .card {
    background: #111;
    border: 1px solid #1e1e1e;
    border-radius: 14px;
    padding: 16px 18px;
    display: flex;
    align-items: center;
    gap: 14px;
    transition: all 0.2s ease;
    cursor: default;
  }

  .card:hover {
    background: #161622;
    border-color: #2a2a3e;
    transform: translateY(-2px);
    box-shadow: 0 8px 24px rgba(0,0,0,0.3);
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
    box-shadow: 0 2px 0 rgba(0,0,0,0.4);
    letter-spacing: 0.5px;
  }

  .key-hyper {
    background: linear-gradient(135deg, #1a1a2e, #16213e);
    border-color: #2a2a4e;
    color: #a78bfa;
    font-size: 11px;
    padding: 0 10px;
  }

  .key-letter {
    background: linear-gradient(135deg, #1a2e1a, #1e3a1e);
    border-color: #2e4a2e;
    color: #34d399;
    font-size: 16px;
    font-weight: 800;
    min-width: 36px;
    height: 36px;
  }

  .key-plus {
    color: #444;
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
    color: #e8e8e8;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .app-hint {
    font-size: 11px;
    color: #555;
    font-weight: 400;
  }

  /* Category colors */
  .cat-core .section-icon { background: #1a2e1a; color: #34d399; }
  .cat-core .section-title h2 { color: #34d399; }

  .cat-dev .section-icon { background: #1a1a2e; color: #3b82f6; }
  .cat-dev .section-title h2 { color: #3b82f6; }

  .cat-comm .section-icon { background: #2e1a2e; color: #e879f9; }
  .cat-comm .section-title h2 { color: #e879f9; }

  .cat-util .section-icon { background: #2e2a1a; color: #f59e0b; }
  .cat-util .section-title h2 { color: #f59e0b; }

  /* Category card accent */
  .cat-core .card { border-left: 3px solid #34d39933; }
  .cat-core .card:hover { border-left-color: #34d399; }

  .cat-dev .card { border-left: 3px solid #3b82f633; }
  .cat-dev .card:hover { border-left-color: #3b82f6; }

  .cat-comm .card { border-left: 3px solid #e879f933; }
  .cat-comm .card:hover { border-left-color: #e879f9; }

  .cat-util .card { border-left: 3px solid #f59e0b33; }
  .cat-util .card:hover { border-left-color: #f59e0b; }

  /* Footer */
  .footer {
    text-align: center;
    margin-top: 48px;
    padding-top: 24px;
    border-top: 1px solid #1a1a1a;
  }

  .footer p {
    font-size: 12px;
    color: #444;
    line-height: 2;
  }

  .footer kbd {
    display: inline-block;
    background: #141414;
    border: 1px solid #282828;
    border-radius: 4px;
    padding: 1px 6px;
    font-family: inherit;
    font-size: 11px;
    color: #666;
    box-shadow: 0 1px 0 #1a1a1a;
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
    border: 1px solid #222;
    background: #111;
    color: #333;
    position: relative;
    transition: all 0.2s;
  }

  .kb-key.active {
    background: linear-gradient(135deg, #0d1f0d, #132613);
    border-color: #2e4a2e;
    color: #34d399;
    box-shadow: 0 0 12px rgba(52, 211, 153, 0.15);
  }

  .kb-key.active .kb-app {
    position: absolute;
    bottom: 2px;
    font-size: 6px;
    color: #1e7a52;
    letter-spacing: 0;
    max-width: 40px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .kb-key.hyper-key {
    width: 72px;
    background: linear-gradient(135deg, #1a1a2e, #16213e);
    border-color: #2a2a4e;
    color: #a78bfa;
    font-size: 10px;
    box-shadow: 0 0 12px rgba(167, 139, 250, 0.1);
  }

  .keyboard-visual {
    margin: 40px 0;
    padding: 28px;
    background: #0d0d0d;
    border: 1px solid #1a1a1a;
    border-radius: 20px;
  }

  .keyboard-visual h3 {
    text-align: center;
    font-size: 12px;
    color: #444;
    text-transform: uppercase;
    letter-spacing: 2px;
    margin-bottom: 20px;
  }

  /* Print */
  @media print {
    body { background: #fff; color: #111; padding: 20px; }
    .card { background: #f9f9f9; border-color: #ddd; }
    .card:hover { transform: none; box-shadow: none; }
    .key-hyper { background: #f0f0ff; color: #6b21a8; }
    .key-letter { background: #f0fff0; color: #166534; }
    .app-name { color: #111; }
    .footer { border-top-color: #ddd; }
  }

  @media (max-width: 768px) {
    .grid { grid-template-columns: repeat(2, 1fr); }
  }

  @media (max-width: 480px) {
    .grid { grid-template-columns: 1fr; }
  }
</style>
</head>
<body>
<div class="container">

  <div class="header">
    <h1>Quickey Cheat Sheet</h1>
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
      <div class="kb-key">A</div>
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
      <span class="count">6 shortcuts</span>
    </div>
    <div class="grid">
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
          <span class="app-name">ChatGPT Atlas</span>
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
      <kbd>Hyper</kbd> = Caps Lock remapped via <strong>Quickey</strong> &nbsp;|&nbsp;
      Available: <kbd>A</kbd> <kbd>E</kbd> <kbd>J</kbd> <kbd>L</kbd> <kbd>Q</kbd> <kbd>U</kbd> <kbd>Y</kbd>
    </p>
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
