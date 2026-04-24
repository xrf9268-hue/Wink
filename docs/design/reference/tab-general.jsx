// General tab — grouped settings, native System-Settings feel.

function GeneralTab({ theme = 'light' }) {
  const t = theme === 'dark' ? window.darkTheme : window.lightTheme;
  return (
    <div className={`wink-scroll${theme === 'dark' ? ' dark' : ''}`} style={{
      flex: 1, padding: '18px 22px 22px',
      overflow: 'auto',
      display: 'flex', flexDirection: 'column', gap: 16,
    }}>
      <div>
        <div style={{ fontSize: 20, fontWeight: 600, color: t.textPrimary, letterSpacing: -0.3 }}>General</div>
        <div style={{ fontSize: 12, color: t.textSecondary, marginTop: 2 }}>
          Startup, keyboard behavior, and updates.
        </div>
      </div>

      {/* Startup */}
      <Row t={t} title="Launch at Login"
        sub="Opens Wink in the menu bar when you sign in. Requires the app to live in /Applications."
        trailing={<window.Switch on={false} t={t} />}
      />

      {/* Keyboard section */}
      <window.Card t={t}>
        <Row t={t} flush
          title="Enable All Shortcuts"
          sub="Master switch for global shortcut routing."
          trailing={<window.Switch on={true} t={t} />}
        />
        <div style={{ borderTop: `0.5px solid ${t.hairline}` }} />
        <Row t={t} flush
          title="Hyper Key"
          sub={<span>Hold <window.Keycap t={t}>Caps Lock</window.Keycap> to act as <window.Keycap t={t}>⌃</window.Keycap><window.Keycap t={t}>⌥</window.Keycap><window.Keycap t={t}>⇧</window.Keycap><window.Keycap t={t}>⌘</window.Keycap>. Tap alone to keep its original behavior.</span>}
          trailing={<window.Switch on={true} t={t} />}
        />
        <div style={{ borderTop: `0.5px solid ${t.hairline}` }} />
        <Row t={t} flush
          title="Activation Behavior"
          sub="How Wink handles a shortcut when the target is already frontmost."
          trailing={<window.Segmented t={t} options={['Hide', 'Toggle', 'Re-activate']} value="Toggle" />}
        />
      </window.Card>

      {/* Permissions recap */}
      <window.Card t={t} title="Permissions">
        <PermRow t={t} ok label="Accessibility" detail="Routes global shortcuts." />
        <div style={{ borderTop: `0.5px solid ${t.hairline}` }} />
        <PermRow t={t} ok label="Input Monitoring" detail="Needed for Hyper-routed shortcuts." />
      </window.Card>

      {/* Updates */}
      <window.Card t={t}>
        <div style={{ padding: '12px 14px', display: 'flex', alignItems: 'center', gap: 12 }}>
          <div style={{
            width: 40, height: 40, borderRadius: 9,
            background: `linear-gradient(135deg, ${t.accent} 0%, ${t.violet} 100%)`,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            color: '#fff',
            boxShadow: '0 2px 6px rgba(0,0,0,0.15), inset 0 1px 0 rgba(255,255,255,0.25)',
          }}><window.Logo_WinkCrescent size={28} color="#fff" /></div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: t.textPrimary }}>Wink 0.3.0</div>
            <div style={{ fontSize: 11.5, color: t.textSecondary, marginTop: 1 }}>
              You're up to date. Last checked just now.
            </div>
          </div>
          <window.Button t={t}>Check for Updates…</window.Button>
        </div>
      </window.Card>

      <div style={{ flex: 1 }} />

      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
        fontSize: 11, color: t.textTertiary, paddingTop: 8,
      }}>
        <span>Wink</span>
        <span>·</span>
        <span>v0.3.0</span>
        <span>·</span>
        <span style={{ color: t.accent, cursor: 'pointer' }}>Release Notes</span>
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
        {sub && <div style={{ fontSize: 11.5, color: t.textSecondary, marginTop: 2, lineHeight: 1.45 }}>{sub}</div>}
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
      <div style={{
        fontSize: 11, color: c, fontWeight: 600,
      }}>{ok ? 'Granted' : 'Needed'}</div>
    </div>
  );
}

Object.assign(window, { GeneralTab });
