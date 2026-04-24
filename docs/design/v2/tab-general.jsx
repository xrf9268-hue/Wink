// General tab v2 — all settings inside grouped cards (System Settings style).
// Launch at Login now lives inside the Startup card, not orphaned.

function GeneralTab({ theme = 'light' }) {
  const t = theme === 'dark' ? window.darkTheme : window.lightTheme;
  return (
    <div className={`wink-scroll${theme === 'dark' ? ' dark' : ''}`} style={{
      flex: 1, padding: '18px 22px 22px',
      overflow: 'auto',
      display: 'flex', flexDirection: 'column', gap: 14,
    }}>
      <div>
        <div style={{ fontSize: 20, fontWeight: 600, color: t.textPrimary, letterSpacing: -0.3, lineHeight: 1.1 }}>General</div>
        <div style={{ fontSize: 12, color: t.textSecondary, marginTop: 4 }}>
          Startup, keyboard behavior, and updates.
        </div>
      </div>

      {/* Startup */}
      <window.Card t={t}>
        <Row t={t} flush
          title="Launch at Login"
          sub="Opens Wink in the menu bar when you sign in."
          trailing={<window.Switch on={true} t={t} />}
        />
        <div style={{ borderTop: `0.5px solid ${t.hairline}` }} />
        <Row t={t} flush
          title="Show Menu Bar Icon"
          sub="Hide the icon if you prefer a minimal menu bar."
          trailing={<window.Switch on={true} t={t} />}
        />
      </window.Card>

      {/* Keyboard */}
      <window.Card t={t}>
        <Row t={t} flush
          title="Enable All Shortcuts"
          sub="Master switch for global shortcut routing."
          trailing={<window.Switch on={true} t={t} />}
        />
        <div style={{ borderTop: `0.5px solid ${t.hairline}` }} />
        <Row t={t} flush
          title="Hyper Key"
          sub={<span>Hold <window.Keycap t={t} size="sm">Caps Lock</window.Keycap> to act as <window.Keycap t={t} size="sm">⌃⌥⇧⌘</window.Keycap>. Tap alone to keep its original behavior.</span>}
          trailing={<window.Switch on={true} t={t} />}
        />
        <div style={{ borderTop: `0.5px solid ${t.hairline}` }} />
        <Row t={t} flush
          title="When target is frontmost"
          sub="How Wink reacts when the target app is already active."
          trailing={<window.Segmented t={t} options={['Hide', 'Toggle', 'Focus']} value="Toggle" />}
        />
      </window.Card>

      {/* Permissions */}
      <window.Card t={t} title="Permissions"
        accessory={<div style={{ fontSize: 11, color: t.textTertiary }}>Required for global shortcuts</div>}
      >
        <PermRow t={t} ok label="Accessibility" detail="Routes global shortcuts." />
        <div style={{ borderTop: `0.5px solid ${t.hairline}` }} />
        <PermRow t={t} ok label="Input Monitoring" detail="Needed for Hyper-routed shortcuts." />
      </window.Card>

      {/* Updates */}
      <window.Card t={t}>
        <div style={{ padding: '12px 14px', display: 'flex', alignItems: 'center', gap: 12 }}>
          <window.WinkAppIcon size={40} radius={9} theme={theme} />
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: t.textPrimary, display: 'flex', alignItems: 'center', gap: 8 }}>
              <window.Wordmark size={13} color={t.textPrimary} />
              <span style={{ color: t.textSecondary, fontWeight: 500 }}>0.3.0</span>
            </div>
            <div style={{ fontSize: 11, color: t.textSecondary, marginTop: 2 }}>
              You're up to date. Last checked just now.
            </div>
          </div>
          <window.Button t={t}>Check for Updates…</window.Button>
        </div>
        <div style={{ borderTop: `0.5px solid ${t.hairline}` }} />
        <Row t={t} flush
          title="Automatic Updates"
          sub="Download and install new versions in the background."
          trailing={<window.Switch on={true} t={t} />}
        />
      </window.Card>

      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
        fontSize: 11, color: t.textTertiary, paddingTop: 4,
      }}>
        <span style={{ cursor: 'pointer' }}>Release Notes</span>
        <span style={{ opacity: 0.5 }}>·</span>
        <span style={{ cursor: 'pointer' }}>Privacy</span>
        <span style={{ opacity: 0.5 }}>·</span>
        <span style={{ cursor: 'pointer' }}>Support</span>
      </div>
    </div>
  );
}

function Row({ t, title, sub, trailing, flush }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 16,
      padding: '12px 14px',
      background: flush ? 'transparent' : t.cardBg,
      border: flush ? 'none' : `0.5px solid ${t.cardBorder}`,
      borderRadius: flush ? 0 : 10,
      boxShadow: flush ? 'none' : t.cardShadow,
    }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, fontWeight: 500, color: t.textPrimary }}>{title}</div>
        {sub && <div style={{ fontSize: 11, color: t.textSecondary, marginTop: 2, lineHeight: 1.45 }}>{sub}</div>}
      </div>
      {trailing}
    </div>
  );
}

function PermRow({ t, label, detail, ok }) {
  const c = ok ? t.green : t.amber;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '10px 14px' }}>
      <div style={{
        width: 22, height: 22, borderRadius: 5,
        background: ok ? t.greenSoft : t.amberBgSoft,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: c,
      }}>{ok ? window.Icons.check(c) : window.Icons.warn(c)}</div>
      <div style={{ flex: 1 }}>
        <div style={{ fontSize: 13, color: t.textPrimary, fontWeight: 500 }}>{label}</div>
        <div style={{ fontSize: 11, color: t.textSecondary, marginTop: 1 }}>{detail}</div>
      </div>
      <div style={{ fontSize: 11, color: c, fontWeight: 600 }}>{ok ? 'Granted' : 'Needed'}</div>
    </div>
  );
}

Object.assign(window, { GeneralTab });
