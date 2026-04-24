// Shortcuts tab — redesigned main window content.
// - Softer permission banner (info role, not alarming red wall)
// - New Shortcut composer with clearer record field + modifier preview
// - Grouped shortcut list w/ grip, rename, last-used meta, drill chevron

function ShortcutsTab({ theme = 'light', permissionGranted = false }) {
  const t = theme === 'dark' ? window.darkTheme : window.lightTheme;
  const shortcuts = [
    { app: 'zed',      name: 'Zed',      keys: '⌃⌥⇧⌘Z', hyper: true, on: true, count: 10, lastUsed: '2m ago' },
    { app: 'terminal', name: 'Terminal', keys: '⌘⌥T',   on: true, count: 32, lastUsed: '8m ago' },
    { app: 'safari',   name: 'Safari',   keys: '⌘⌥S',   on: true, count: 70, lastUsed: 'just now' },
    { app: 'notes',    name: 'Notes',    keys: '⌘⌥N',   on: true, count: 0,  lastUsed: '—' },
  ];

  return (
    <div className={`wink-scroll${theme === 'dark' ? ' dark' : ''}`} style={{
      flex: 1, padding: '18px 22px 22px',
      overflow: 'auto',
      display: 'flex', flexDirection: 'column', gap: 16,
    }}>
      {/* header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 20, fontWeight: 600, color: t.textPrimary, letterSpacing: -0.3 }}>Shortcuts</div>
          <div style={{ fontSize: 12, color: t.textSecondary, marginTop: 2 }}>
            Bind a keystroke to launch, toggle, or hide an app.
          </div>
        </div>
        <window.Button t={t}>
          {window.Icons.refresh(t.textSecondary)}
          <span style={{ marginLeft: 4 }}>Refresh</span>
        </window.Button>
      </div>

      {/* permission banner */}
      {permissionGranted ? (
        <window.Banner t={t} kind="success"
          title="Shortcut capture ready"
          body="Standard and Hyper shortcuts are active. If Hyper shortcuts work here, Wink has the permission it needs."
        />
      ) : (
        <window.Banner t={t} kind="warn"
          title="Accessibility permission needed"
          body="Wink needs Accessibility access to route global shortcuts."
          trailing={<window.Button t={t} variant="primary" size="sm">Open Settings</window.Button>}
        />
      )}

      {/* New shortcut composer */}
      <window.Card t={t} title="New Shortcut">
        <div style={{ padding: 14, display: 'flex', flexDirection: 'column', gap: 10 }}>
          <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 11, color: t.textSecondary, marginBottom: 5, fontWeight: 500 }}>Target app</div>
              <div style={{
                display: 'flex', alignItems: 'center', gap: 8,
                padding: '5px 8px 5px 6px',
                background: t.controlBg,
                border: `0.5px solid ${t.controlBorder}`,
                borderRadius: 6,
                boxShadow: t.controlShadow,
                minHeight: 26,
              }}>
                <div style={{
                  width: 18, height: 18, borderRadius: 3,
                  background: t === window.darkTheme ? '#5A5A5C' : '#D8D8D8',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                }}>
                  {window.Icons.plus('#FFF')}
                </div>
                <span style={{ fontSize: 12, color: t.textTertiary, flex: 1 }}>Choose an app…</span>
                <div style={{ color: t.textSecondary }}>{window.Icons.chevronRight(t.textSecondary)}</div>
              </div>
            </div>
            <div style={{ flex: 1.2 }}>
              <div style={{ fontSize: 11, color: t.textSecondary, marginBottom: 5, fontWeight: 500, display: 'flex', justifyContent: 'space-between' }}>
                <span>Shortcut</span>
                <span style={{ color: t.textTertiary }}>Press a key combination</span>
              </div>
              <div style={{
                display: 'flex', alignItems: 'center', gap: 6,
                padding: '5px 8px',
                background: t.fieldBg,
                border: `1px dashed ${t.accentBorderSoft}`,
                borderRadius: 6,
                minHeight: 28,
              }}>
                <div style={{ color: t.accent }}>{window.Icons.record(t.accent)}</div>
                <span style={{ fontSize: 12, color: t.accent, fontWeight: 500 }}>Recording…</span>
                <div style={{ flex: 1 }} />
                <window.Keycap t={t}>⌘</window.Keycap>
                <window.Keycap t={t}>⌥</window.Keycap>
                <window.Keycap t={t}>G</window.Keycap>
              </div>
            </div>
          </div>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 10,
            paddingTop: 6, borderTop: `0.5px solid ${t.hairline}`,
          }}>
            <div style={{ fontSize: 11, color: t.textTertiary, flex: 1 }}>
              Tip: hold <window.Keycap t={t}>Caps Lock</window.Keycap> with any key to record a Hyper shortcut.
            </div>
            <window.Button t={t}>Clear</window.Button>
            <window.Button t={t} variant="primary">Add Shortcut</window.Button>
          </div>
        </div>
      </window.Card>

      {/* Shortcut list */}
      <window.Card t={t} title={`Your Shortcuts · ${shortcuts.length}`}
        accessory={
          <div style={{ display: 'flex', gap: 6 }}>
            <window.Button t={t}>Export…</window.Button>
            <window.Button t={t}>Import…</window.Button>
          </div>
        }
      >
        {shortcuts.map((s, i) => (
          <div key={i} style={{
            display: 'flex', alignItems: 'center', gap: 10,
            padding: '10px 14px',
            borderTop: i === 0 ? 'none' : `0.5px solid ${t.hairline}`,
          }}>
            <div style={{ color: t.textTertiary, cursor: 'grab' }}>{window.Icons.grip(t.textTertiary)}</div>
            <window.AppIcon app={s.app} size={30} theme={theme} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <span style={{ fontSize: 13, color: t.textPrimary, fontWeight: 500 }}>{s.name}</span>
                <window.StatusDot color={t.green} size={6} />
              </div>
              <div style={{
                display: 'flex', alignItems: 'center', gap: 8,
                fontSize: 11, color: t.textTertiary, marginTop: 2,
                fontVariantNumeric: 'tabular-nums',
              }}>
                <span>{s.count}× past 7 days</span>
                <span style={{ opacity: 0.5 }}>·</span>
                <span>Last {s.lastUsed}</span>
              </div>
            </div>
            {s.hyper && <window.HyperBadge t={t} />}
            <div style={{
              padding: '3px 8px',
              background: t.controlBgRest,
              border: `0.5px solid ${t.controlBorder}`,
              borderRadius: 5,
              fontSize: 12, color: t.textPrimary,
              letterSpacing: 0.5,
              fontVariantNumeric: 'tabular-nums',
            }}>{s.keys}</div>
            <window.Switch on={s.on} t={t} />
            <div style={{
              width: 20, height: 20, borderRadius: 4,
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              color: t.textTertiary, cursor: 'pointer',
            }}>{window.Icons.close(t.textTertiary)}</div>
          </div>
        ))}
      </window.Card>
    </div>
  );
}

Object.assign(window, { ShortcutsTab });
