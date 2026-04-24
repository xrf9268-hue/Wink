// Shortcuts tab v2.
// - Composer collapsed into an inline "+ Add Shortcut…" row at the top
//   of the list card, expanding in place (System Settings pattern).
// - Shortcut keys rendered as native menu-style glyphs (no bordered pill).
// - Refresh removed (no meaningful semantics for a local DB).
// - Font sizes normalized to integers.

function ShortcutsTab({ theme = 'light', permissionGranted = false }) {
  const t = theme === 'dark' ? window.darkTheme : window.lightTheme;
  const [composing, setComposing] = React.useState(false);
  const shortcuts = [
    { app: 'zed',      name: 'Zed',      keys: '⌃⌥⇧⌘Z', hyper: true, on: true, count: 10, lastUsed: '2m ago' },
    { app: 'terminal', name: 'Terminal', keys: '⌘⌥T',   on: true, count: 32, lastUsed: '8m ago' },
    { app: 'safari',   name: 'Safari',   keys: '⌘⌥S',   on: true, count: 70, lastUsed: 'just now' },
    { app: 'notes',    name: 'Notes',    keys: '⌘⌥N',   on: false, count: 0, lastUsed: '—' },
  ];

  return (
    <div className={`wink-scroll${theme === 'dark' ? ' dark' : ''}`} style={{
      flex: 1, padding: '18px 22px 22px',
      overflow: 'auto',
      display: 'flex', flexDirection: 'column', gap: 14,
    }}>
      {/* header */}
      <div>
        <div style={{ fontSize: 20, fontWeight: 600, color: t.textPrimary, letterSpacing: -0.3, lineHeight: 1.1 }}>Shortcuts</div>
        <div style={{ fontSize: 12, color: t.textSecondary, marginTop: 4 }}>
          Bind a keystroke to launch, toggle, or hide an app.
        </div>
      </div>

      {/* permission banner */}
      {permissionGranted ? (
        <window.Banner t={t} kind="success"
          title="Shortcut capture ready"
          body="Standard and Hyper shortcuts are active."
        />
      ) : (
        <window.Banner t={t} kind="warn"
          title="Accessibility permission needed"
          body="Wink needs Accessibility access to route global shortcuts."
          trailing={<window.Button t={t} variant="primary" size="sm">Open Settings</window.Button>}
        />
      )}

      {/* Shortcut list */}
      <window.Card t={t} title={`Your Shortcuts · ${shortcuts.length}`}
        accessory={
          <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
            <window.TextField t={t}
              placeholder="Filter…"
              leftIcon={window.Icons.search(t.textTertiary)}
              style={{ width: 140, padding: '3px 7px', minHeight: 22 }}
              inputStyle={{ fontSize: 12 }}
            />
            <window.Button t={t}>Import…</window.Button>
          </div>
        }
      >
        {/* Inline composer — collapsed by default, expands in place */}
        {composing ? (
          <InlineComposer t={t} theme={theme} onCancel={() => setComposing(false)} />
        ) : (
          <div onClick={() => setComposing(true)} style={{
            display: 'flex', alignItems: 'center', gap: 10,
            padding: '10px 14px',
            color: t.textSecondary,
            cursor: 'pointer',
            fontSize: 13,
          }}>
            <div style={{
              width: 22, height: 22, borderRadius: 5,
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              color: t.accent,
            }}>{window.Icons.plus(t.accent)}</div>
            <span style={{ color: t.accent, fontWeight: 500 }}>Add Shortcut</span>
          </div>
        )}

        {shortcuts.map((s, i) => (
          <div key={i} style={{
            display: 'flex', alignItems: 'center', gap: 10,
            padding: '10px 14px',
            borderTop: `0.5px solid ${t.hairline}`,
            opacity: s.on ? 1 : 0.62,
          }}>
            <div style={{ color: t.textTertiary, cursor: 'grab', display: 'flex' }}>{window.Icons.grip(t.textTertiary)}</div>
            <window.AppIcon app={s.app} size={30} theme={theme} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span style={{ fontSize: 13, color: t.textPrimary, fontWeight: 500 }}>{s.name}</span>
                {s.on && s.count > 0 && <window.StatusDot color={t.green} size={6} />}
              </div>
              <div style={{
                display: 'flex', alignItems: 'center', gap: 8,
                fontSize: 11, color: t.textTertiary, marginTop: 2,
                fontVariantNumeric: 'tabular-nums',
              }}>
                {s.count > 0 ? (
                  <>
                    <span>{s.count}× past 7 days</span>
                    <span style={{ opacity: 0.5 }}>·</span>
                    <span>Last used {s.lastUsed}</span>
                  </>
                ) : (
                  <span>Not used yet</span>
                )}
              </div>
            </div>
            {s.hyper && <window.HyperBadge t={t} />}
            <span style={{
              fontSize: 13,
              color: s.on ? t.textPrimary : t.textSecondary,
              letterSpacing: 0.5,
              fontFamily: window.SF,
              fontVariantNumeric: 'tabular-nums',
              minWidth: 62, textAlign: 'right',
            }}>{s.keys}</span>
            <window.Switch on={s.on} t={t} />
            <div style={{
              width: 22, height: 22, borderRadius: 5,
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              color: t.textTertiary, cursor: 'pointer',
            }}>{window.Icons.more(t.textTertiary)}</div>
          </div>
        ))}
      </window.Card>
    </div>
  );
}

function InlineComposer({ t, theme, onCancel }) {
  return (
    <div style={{
      padding: 14,
      background: theme === 'dark' ? 'rgba(255,255,255,0.02)' : 'rgba(0,0,0,0.015)',
    }}>
      <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 8,
            padding: '5px 8px 5px 6px',
            background: t.controlBg,
            border: `0.5px solid ${t.controlBorder}`,
            borderRadius: 6,
            boxShadow: t.controlShadow,
            height: 28, boxSizing: 'border-box',
          }}>
            <div style={{
              width: 20, height: 20, borderRadius: 4,
              background: t === window.darkTheme ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.06)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              color: t.textTertiary,
            }}>{window.Icons.app(t.textTertiary)}</div>
            <span style={{ fontSize: 12, color: t.textTertiary, flex: 1 }}>Choose an app…</span>
            <div style={{ color: t.textSecondary }}>{window.Icons.chevronDown(t.textSecondary)}</div>
          </div>
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 6,
            padding: '5px 8px',
            background: t.fieldBg,
            border: `1px dashed ${t === window.darkTheme ? 'rgba(255,255,255,0.14)' : 'rgba(0,0,0,0.14)'}`,
            borderRadius: 6,
            height: 28, boxSizing: 'border-box',
            cursor: 'text',
          }}>
            <div style={{ color: t.textTertiary }}>{window.Icons.record(t.textTertiary)}</div>
            <span style={{ fontSize: 12, color: t.textTertiary, flex: 1 }}>Press a key combination…</span>
          </div>
        </div>
        <window.Button t={t} onClick={onCancel}>Cancel</window.Button>
        <window.Button t={t} variant="primary">Add</window.Button>
      </div>
      <div style={{ fontSize: 11, color: t.textTertiary, marginTop: 8, display: 'inline-flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
        <span>Tip: hold</span>
        <window.Keycap t={t} size="sm">Caps Lock</window.Keycap>
        <span>for a Hyper shortcut.</span>
      </div>
    </div>
  );
}

Object.assign(window, { ShortcutsTab });
